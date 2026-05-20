//-------------------------------------------------------------------------------
//
// Commodore 1541 gcr floppy (read/write) by Dar (darfpga@aol.fr) 23-May-2017
// http://darfpga.blogspot.fr
//
// produces GCR data, byte(ready) and sync signal to feed c1541_wire from current
// track buffer ram which contains D64 data
//
// gets GCR data from c1541_wire, while producing byte(ready) signal. Data feed
// track buffer ram after conversion
//
// Reworked and adapted to MiSTer by Alexey Melnikov
//
//-------------------------------------------------------------------------------

// Heavily reworked by m1nl for Icepi Zero C64 project
// SPDX-License-Identifier: GPL-3.0-or-later

`default_nettype none
`timescale 1 ns / 1 ps

module c1541_gcr #(
  parameter LFSR_SIMPLE = 1
) (
  input  wire        clk,
  input  wire        reset,
  input  wire        ce,

  output wire  [7:0] dout,    // data from ram to 1541 wire
  input  wire  [7:0] din,     // data from 1541 wire to ram
  input  wire        mode,    // read/write
  input  wire        mtr,     // motor on / off
  input  wire  [1:0] freq,    // motor (gcr_bit) frequency
  input  wire        wps_n,   // write protect sense
  output wire        sync_n,  // reading SYNC bytes
  output wire        byte_n,  // byte ready
  input  wire        busy,    // drive busy

  input  wire        img_mounted,
  input  wire [15:0] img_id,
  input  wire  [6:0] track,

  output reg  [12:0] buff_addr,
  input  wire  [7:0] buff_dout,
  output reg   [7:0] buff_din,
  output reg         buff_we,
  output reg         buff_en
);


// --- Disk ID (loaded from image or updated from track 18 BAM) ---
reg [7:0] id1, id2;

// --- Track geometry ---
wire [5:0] track_num  = track[6:1] + 1;  // 1-based track number (1..35)
wire       half_track = track[0];

wire [4:0] sector_max = (track_num < 18) ? 20 :
                        (track_num < 25) ? 18 :
                        (track_num < 31) ? 17 : 16;

wire  [5:0] gcr_header_sync_length = 41;
wire [12:0] gcr_header_data_size   = 80;
wire [12:0] gcr_header_total_size  = 151;

wire  [5:0] gcr_sector_data_sync_length = 41;
wire [12:0] gcr_sector_data_size        = 2600;
wire [12:0] gcr_sector_total_size       = (sector != sector_max) ? gcr_sector_data_size +   63 :
                                                (track_num < 18) ? gcr_sector_data_size +  783 :
                                                (track_num < 25) ? gcr_sector_data_size + 2175 :
                                                (track_num < 31) ? gcr_sector_data_size + 1263 :
                                                                   gcr_sector_data_size +  831 ;

// --- Sector state ---
reg  [4:0] sector;

wire [4:0] next_sector = (sector >= sector_max) ? 0 : (sector + 1);

// --- Byte counter and running data checksum ---
reg  [8:0] byte_cnt;
reg  [7:0] data_chksum;

// --- Sector header and data block byte encoding ---
wire [7:0] hdr_chksum  = {2'b0, track_num} ^ {3'b0, sector} ^ id1 ^ id2;

wire [7:0] data_header = (byte_cnt == 0) ? 8'h08             :
                         (byte_cnt == 1) ? hdr_chksum        :
                         (byte_cnt == 2) ? {3'b0, sector}    :
                         (byte_cnt == 3) ? {2'b0, track_num} :
                         (byte_cnt == 4) ? id2               :
                         (byte_cnt == 5) ? id1               : 8'h0F;

wire [7:0] data_body   = (byte_cnt == 0)   ? 8'h07       :
                         (byte_cnt == 257) ? data_chksum :
                         (byte_cnt == 258) ? 8'h00       :
                         (byte_cnt == 259) ? 8'h00       :
                         (byte_cnt >= 260) ? 8'h0F       : buff_dout;

reg [7:0] data;

// --- GCR encode LUT ---
reg [4:0] gcr_lut [0:15];

initial begin
  $readmemh("mem/gcr_lut.mem", gcr_lut);
end

reg   [5:0] sync_bits;     // consecutive sync bits sent so far (up to gcr_sector_data_sync_length)
reg  [12:0] gcr_idx;       // index in the GCR bitstream for the current sector data or header
reg   [3:0] gcr_bit_idx;   // current bit index within 10-bit GCR word (0..9)
reg   [9:0] gcr_word_out;  // GCR-encoded 10-bit word for the current data byte to 1541

// --- LFSR for random flux gap fill ---
wire [31:0] lfsr;

generate
  if (LFSR_SIMPLE) begin
    reg [7:0] lfsr_q;

    always @(posedge clk) begin
      if (reset)
        lfsr_q <= 8'hcd;
      else
        lfsr_q <= {lfsr_q[6:0], lfsr_q[7] ^ lfsr_q[5] ^ lfsr_q[4] ^ lfsr_q[3]};
    end

    assign lfsr = {24'b0, lfsr_q};

  end else begin
    reg [31:0] lfsr_q;

    always @(posedge clk) begin
      if (reset)
        lfsr_q <= 32'h1234abcd;
      else
        lfsr_q <=  ((lfsr_q ^ (lfsr_q << 13)) ^ ((lfsr_q ^ (lfsr_q << 13)) >> 17)) ^
                  (((lfsr_q ^ (lfsr_q << 13)) ^ ((lfsr_q ^ (lfsr_q << 13)) >> 17)) << 5);
    end

    assign lfsr = lfsr_q;
  end
endgenerate

// --- Flux generation ---
reg        flux_rev;   // flux reversal pulse this cycle
reg  [9:0] flux_gap;   // cycles until next random flux reversal (prevents DC drift)

// --- GCR bit clock: serializes gcr_word_out bits into flux_rev (transmit side) ---
reg  [5:0] rot_cnt;
wire       rot_en   = mode ? &(rot_cnt) : (pll_en && pll_phase[1:0] == 2'b01);
wire       rot_ce   = rot_en && ce;

// --- PLL / clock recovery: reconstructs bit clock from flux_rev into tx_shreg (receive side) ---
reg  [3:0] pll_cnt;
reg  [3:0] pll_phase;
wire       pll_en = &pll_cnt;

// --- recieve shift register and bit counter ---
reg  [9:0] rx_shreg;
reg  [7:0] rx_data;
reg  [2:0] rx_bit_cnt;

// --- send shift register and bit counter ---
reg  [9:0] tx_shreg;
reg  [2:0] tx_bit_cnt;

// --- Track/mode change detection ---
reg  [6:0] track_prev;
reg        mode_prev = 1;

// --- GCR finite state machine
localparam ST_SYNC  = 0;
localparam ST_READ  = 1;
localparam ST_WRITE = 2;

reg [1:0] state;
reg       header_done;

// --- Stall when track is changing, mode is changing, drive is busy, or on a half-track ---
wire stall = (track_prev != track) || (mode_prev != mode) || busy || half_track;

// --- Same timing as in c1541_direct_gcr.sv
assign sync_n = ~&tx_shreg || !mode;
assign byte_n = ~&tx_bit_cnt || &tx_shreg || pll_phase[1];
assign dout   = tx_shreg[7:0];

// --- Flux generation and clock recovery ---
always @(posedge clk) begin
  if (reset || !mtr) begin
    tx_shreg   <= 10'h3FF;
    rx_shreg   <= 10'h3FF;
    tx_bit_cnt <= 0;
    rx_bit_cnt <= 0;

    pll_cnt <= {2'b0, freq};
    rot_cnt <= {2'b0, freq, 2'b0};

    pll_phase <= 0;

    flux_rev <= 1'b0;
    flux_gap <= 10'd256;

  end else if (ce) begin
    if (!mode)
      flux_rev <= 0;
    else if (flux_gap == 0)
      flux_rev <= 1;
    else if (half_track)
      flux_rev <= 0;
    else if (rot_en)
      flux_rev <= gcr_word_out[4'd9 - gcr_bit_idx];
    else
      flux_rev <= 0;

    if (flux_gap == 0)
      flux_gap <= {3'b0, lfsr[6:0]} + 10'd40;
    else if (gcr_word_out[4'd9 - gcr_bit_idx])
      flux_gap <= {4'b0, lfsr[5:0]} + 10'd256;
    else
      flux_gap <= flux_gap - 1'b1;

    if (rot_en)
      rot_cnt <= {2'b00, freq, 2'b00};
    else
      rot_cnt <= rot_cnt + 1;

    if (flux_rev) begin
      pll_cnt   <= {2'b0, freq};
      pll_phase <= 0;
    end else if (pll_en) begin
      pll_cnt   <= {2'b0, freq};
      pll_phase <= pll_phase + 1;
    end else
      pll_cnt <= pll_cnt + 1;

    if (pll_en) begin
      if (pll_phase[1:0] == 2'b01) begin
        tx_shreg   <= {tx_shreg[8:0], ~|pll_phase[3:2]};
        tx_bit_cnt <= tx_bit_cnt + 1;
        rx_bit_cnt <= rx_bit_cnt + 1;

      end else if (pll_phase[1:0] == 2'b10 && (&(tx_bit_cnt))) begin
        rx_data      <= din;
        rx_bit_cnt   <= 0;

      end else if (pll_phase[1:0] == 2'b11) begin
        rx_shreg <= {rx_shreg[8:0], rx_data[~rx_bit_cnt]};
      end
    end

    if (!sync_n)
      tx_bit_cnt <= 0;
  end
end

always @(*) begin
  gcr_word_out = {gcr_lut[data[7:4]], gcr_lut[data[3:0]]};

  if (state == ST_SYNC || state == ST_WRITE)
    gcr_word_out = 10'h3FF;
  else if (!header_done && gcr_idx >= gcr_header_data_size - 1)
    gcr_word_out = 10'h155;
  else if (header_done && gcr_idx >= gcr_sector_data_size - 1)
    gcr_word_out = 10'h155;
end

always @(*) begin
  data = 8'hFF;

  if (state == ST_READ)
    data = header_done ? data_body : data_header;
end

wire [3:0] nibble_out;

gcr_decoder gcr_decoder_0 (
  .in(rx_shreg[4:0]),
  .out(nibble_out)
);

// --- Sector state machine ---
always @(posedge clk) begin
  buff_we <= 0;
  buff_en <= 0;

  if (img_mounted)
    {id2, id1} <= img_id;
  else if (track_num == 18 && buff_en && buff_we) begin
    if (buff_addr == 13'h00A2) id1 <= buff_din;
    if (buff_addr == 13'h00A3) id2 <= buff_din;
  end

  if (reset || !mtr) begin
    track_prev <= 0;
    mode_prev  <= 1;

    header_done <= 0;

    state       <= ST_SYNC;
    sync_bits   <= 0;
    byte_cnt    <= 0;
    gcr_bit_idx <= 0;
    gcr_idx     <= 0;

    sector      <= 0;
    data_chksum <= 0;

  end else if (stall) begin
    track_prev <= track;
    mode_prev  <= mode;

    if (rot_ce) begin
      gcr_bit_idx <= gcr_bit_idx + 1;
      gcr_idx     <= gcr_idx + 1;

      if (gcr_bit_idx == 9) begin
          gcr_bit_idx <= 0;

          if (!(&byte_cnt))
            byte_cnt <= byte_cnt + 1;
      end
    end

    if (sector > sector_max)
      sector <= 0;

    if (state != ST_SYNC)
      state <= mode ? ST_READ : ST_WRITE;

  end else if (rot_ce) begin
    case (state)
      ST_SYNC: begin
        gcr_bit_idx <= 0;
        gcr_idx     <= 0;
        byte_cnt    <= 0;

        sync_bits <= sync_bits + 1;

        if (mode) begin
          if (!header_done && sync_bits >= gcr_header_sync_length - 1)
            state <= ST_READ;

          if (header_done && sync_bits >= gcr_sector_data_sync_length - 1)
            state <= ST_READ;

        end else if (!(&rx_shreg)) begin
          state <= ST_WRITE;

          // one bit has already been shifted into rx_shreg
          gcr_bit_idx <= 1;
          gcr_idx     <= 1;
        end
      end
      ST_READ: begin
        gcr_bit_idx <= gcr_bit_idx + 1;
        gcr_idx     <= gcr_idx + 1;

        if (gcr_bit_idx == 9) begin
          gcr_bit_idx <= 0;

          if (!(&byte_cnt))
            byte_cnt <= byte_cnt + 1;

          if (header_done) begin
            data_chksum <= (byte_cnt == 0) ? 0 : (data_chksum ^ data);
            buff_we     <= 0;
            buff_en     <= 1;
            buff_addr   <= {sector, byte_cnt[7:0]};
          end
        end

        if (header_done) begin
          if (gcr_idx >= gcr_sector_total_size - 1) begin
            state       <= ST_SYNC;
            sync_bits   <= 0;
            header_done <= 0;
            sector      <= next_sector;
          end

        end else begin
          if (gcr_idx >= gcr_header_total_size - 1) begin
            state       <= ST_SYNC;
            sync_bits   <= 0;
            header_done <= 1;
          end
        end
      end
      ST_WRITE: begin
        gcr_bit_idx <= gcr_bit_idx + 1;

        if (!(&gcr_idx))
          gcr_idx <= gcr_idx + 1;

        if (gcr_bit_idx == 9) begin
          gcr_bit_idx <= 0;

          if (!(&byte_cnt))
            byte_cnt <= byte_cnt + 1;

          buff_din[3:0] <= nibble_out;
          buff_we       <= !byte_cnt[8] && header_done && wps_n;
          buff_en       <= 1;
          buff_addr     <= {sector, byte_cnt[7:0]};

          // writing sector mark
          if ({buff_din[7:4], nibble_out} == 8'h07 && !header_done) begin
            header_done <= 1;
            byte_cnt    <= 0;
          end

        end else if (gcr_bit_idx == 4) begin
          buff_din[7:4] <= nibble_out;
        end

        if (&rx_shreg) begin
          state       <= ST_SYNC;
          sync_bits   <= 0;
          header_done <= 0;

          if (header_done)
            sector <= next_sector;
        end
      end
    endcase
  end
end

endmodule

module gcr_decoder(
  input  wire [4:0] in,
  output reg  [3:0] out
);

always @(*) begin
  case (in)
    5'b01010: out = 4'h0;
    5'b01011: out = 4'h1;
    5'b10010: out = 4'h2;
    5'b10011: out = 4'h3;
    5'b01110: out = 4'h4;
    5'b01111: out = 4'h5;
    5'b10110: out = 4'h6;
    5'b10111: out = 4'h7;
    5'b01001: out = 4'h8;
    5'b11001: out = 4'h9;
    5'b11010: out = 4'hA;
    5'b11011: out = 4'hB;
    5'b01101: out = 4'hC;
    5'b11101: out = 4'hD;
    5'b11110: out = 4'hE;
    default:  out = 4'hF;
  endcase
end

endmodule
`default_nettype wire
// vim:ts=2 sw=2 tw=120 et
