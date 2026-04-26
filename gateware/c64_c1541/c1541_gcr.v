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
module c1541_gcr (
  input  wire        clk,
  input  wire        reset,
  input  wire        ce,

  output reg   [7:0] dout,    // data from ram to 1541 wire
  input  wire  [7:0] din,     // data from 1541 wire to ram
  input  wire        mode,    // read/write
  input  wire        mtr,     // stepper motor on/off
  input  wire  [1:0] freq,    // motor (gcr_bit) frequency
  input  wire        wps_n,   // write protect sense
  output reg         sync_n,  // reading SYNC bytes
  output wire        byte_n,  // byte ready
  input  wire        busy,    // drive busy

  input  wire        img_mounted,
  input  wire [15:0] disk_id,
  input  wire  [6:0] track,

  output reg  [12:0] buff_addr,
  input  wire  [7:0] buff_dout,
  output reg   [7:0] buff_din,
  output reg         buff_we,
  output reg         buff_en
);

reg [7:0] id1, id2;

reg [8:0] byte_cnt;
reg [7:0] data_cks;
reg       nibble;
reg [4:0] gcr_lut [0:15];
reg       header_done;
reg [4:0] sector;

wire [5:0] track_adj = track[6:1] + 1;

wire [7:0] hdr_cks = {2'b0, track_adj} ^ {3'b0, sector} ^ id1 ^ id2;

wire [4:0] sector_max = (track_adj < 18) ? 20 :
                        (track_adj < 25) ? 18 :
                        (track_adj < 31) ? 17 : 16;

wire [8:0] byte_cnt_max = (!mode)                ? 256      :
                          (sector == sector_max) ? 259 + 94 : // 118 -> 94
                          (track_adj < 18)       ? 259 + 5  : // 7   -> 5
                          (track_adj < 25)       ? 259 + 13 : // 17  -> 13
                          (track_adj < 30)       ? 259 + 12 : // 12  -> 9
                                                   259 + 6  ; // 8   -> 6

wire [7:0] data_header = (byte_cnt == 0) ? 8'h08             :
                         (byte_cnt == 1) ? hdr_cks           :
                         (byte_cnt == 2) ? {3'b0, sector}    :
                         (byte_cnt == 3) ? {2'b0, track_adj} :
                         (byte_cnt == 4) ? id2               :
                         (byte_cnt == 5) ? id1               : 8'h0F;

wire [7:0] data_body = (byte_cnt == 0)   ? 8'h07    :
                       (byte_cnt == 257) ? data_cks :
                       (byte_cnt == 258) ? 8'h00    :
                       (byte_cnt == 259) ? 8'h00    :
                       (byte_cnt >= 260) ? 8'h0F    : buff_dout;

wire [7:0] data       = header_done ? data_body : data_header;
wire [4:0] gcr_nibble = gcr_lut[nibble ? data[3:0] : data[7:4]];

initial begin
  $readmemh("mem/gcr_lut.mem", gcr_lut);
end

reg [3:0] nibble_out;
reg [4:0] gcr_nibble_out;

always @(*) begin
  case (gcr_nibble_out)
    5'b01010: nibble_out = 4'h0;
    5'b01011: nibble_out = 4'h1;
    5'b10010: nibble_out = 4'h2;
    5'b10011: nibble_out = 4'h3;
    5'b01110: nibble_out = 4'h4;
    5'b01111: nibble_out = 4'h5;
    5'b10110: nibble_out = 4'h6;
    5'b10111: nibble_out = 4'h7;
    5'b01001: nibble_out = 4'h8;
    5'b11001: nibble_out = 4'h9;
    5'b11010: nibble_out = 4'hA;
    5'b11011: nibble_out = 4'hB;
    5'b01101: nibble_out = 4'hC;
    5'b11101: nibble_out = 4'hD;
    5'b11110: nibble_out = 4'hE;
    default:  nibble_out = 4'hF;
  endcase
end

reg [5:0] bit_clk_cnt;
reg       bit_clk_en;

reg [6:0] track_r;

reg mode_r;

reg byte_ready;
reg byte_ready_r;

reg [1:0] byte_n_cnt;

assign byte_n = (byte_n_cnt == 0) || !sync_n;

always @(posedge clk) begin
  bit_clk_en <= 0;  // ensure strobe

  if (reset || !mtr) begin
    bit_clk_cnt  <= {2'b0, freq, 2'b0};
    byte_n_cnt   <= 0;
    byte_ready_r <= 0;

  end else if (ce) begin
    if (&(bit_clk_cnt)) begin
      bit_clk_en  <= 1;
      bit_clk_cnt <= {2'b0, freq, 2'b0};

      if (byte_n_cnt != 0)
        byte_n_cnt <= byte_n_cnt - 1;

    end else
      bit_clk_cnt <= bit_clk_cnt + 1;

    if ((byte_ready != byte_ready_r) && (bit_clk_cnt[5:4] == 2'b01)) begin
      byte_n_cnt   <= 2;
      byte_ready_r <= byte_ready;
    end
  end
end

wire stall;
wire half_track;

reg [5:0] sync_cnt;
reg [2:0] bit_cnt;
reg [2:0] gcr_bit_cnt;

reg [7:0] gcr_byte;
reg [7:0] gcr_byte_out;

reg [4:0] sector_next;

reg authorize_write;
reg sector_done;

assign stall = (track_r != track) || busy;

assign half_track = track[0];

always @(*)
  sector_next = (sector >= sector_max) ? 0 : (sector + 1);

always @(posedge clk) begin
  buff_we <= 0;
  buff_en <= 0;

  if (img_mounted)
    {id2, id1} <= disk_id;
  else if (track_adj == 18 && buff_en && buff_we) begin
    if (buff_addr == 13'h00A2) id1 <= buff_din;
    if (buff_addr == 13'h00A3) id2 <= buff_din;
  end

  if (reset || !mtr) begin  // reset
    authorize_write <= 0;
    header_done     <= 0;
    sector_done     <= 0;

    sector <= 0;

    sync_n   <= 1;
    sync_cnt <= 0;

    dout <= 8'h55;

    byte_ready <= 0;
    bit_cnt    <= 0;

    gcr_bit_cnt <= 0;

    byte_cnt <= 0;
    nibble   <= 0;
    data_cks <= 0;

  end else if (stall || half_track) begin  // stalled
    track_r         <= track;
    authorize_write <= 0;
    header_done     <= 0;
    sector_done     <= 0;

    if (track_r != track)
      sector <= {1'b0, sector[4:1]};  // does not really matter

    sync_n   <= 1;
    sync_cnt <= 0;

    dout <= 8'h55;

    if (bit_clk_en) begin
      if (bit_cnt == 7)
        byte_ready <= !byte_ready;

      bit_cnt     <= bit_cnt + 1;
      gcr_bit_cnt <= gcr_bit_cnt + 1;

      if (gcr_bit_cnt == 4)
        gcr_bit_cnt <= 0;
    end

    byte_cnt <= 0;
    nibble   <= 0;

  end else if (mode_r != mode) begin  // mode change
    mode_r          <= mode;
    authorize_write <= 0;
    header_done     <= 0;
    sector_done     <= 0;

    if (sector_done)
      sector <= sector_next;

    sync_n   <= 1;
    sync_cnt <= 0;

    byte_cnt <= 0;

  end else if (bit_clk_en) begin
    if (mode && sync_cnt != 40) begin  // sync sequence (only when reading)
      bit_cnt     <= 0;
      sector_done <= 0;

      if (sync_cnt == 4)
        dout <= 8'hFF;
      else if (sync_cnt == 9)
        sync_n <= 0;
      else if (sync_cnt == 39)
        sync_n <= 1;

      sync_cnt <= sync_cnt + 1;

      gcr_bit_cnt <= 0;

      byte_cnt <= 0;
      nibble   <= 0;

    end else begin  // sector header or data
      sync_n <= 1;

      bit_cnt     <= bit_cnt + 1;
      gcr_bit_cnt <= gcr_bit_cnt + 1;

      if (gcr_bit_cnt == 4) begin
        gcr_bit_cnt <= 0;
        nibble      <= !nibble;

        if (nibble) begin
          byte_cnt <= byte_cnt + 1;

          if (byte_cnt >= byte_cnt_max) begin
            sector_done <= 1;
          end else
            buff_en <= header_done;

          buff_addr <= {sector, byte_cnt[7:0]};
          data_cks  <= (byte_cnt == 0) ? 0 : (data_cks ^ data);
        end else begin
          if (wps_n && !mode && !authorize_write) begin
            if (buff_din == 8'h07) begin
              authorize_write <= 1;
              byte_cnt        <= 0;
            end
          end
        end
      end else if (gcr_bit_cnt == 0) begin
        if (nibble) begin
          buff_din[7:4] <= nibble_out;
        end else begin
          buff_din[3:0] <= nibble_out;

          buff_we <= authorize_write && !sector_done;
          buff_en <= authorize_write && !sector_done;
        end
      end

      // demux byte from floppy (ram)
      gcr_byte <= {gcr_byte[6:0], gcr_nibble[gcr_bit_cnt]};

      // serialize / convert byte to floppy (ram)
      gcr_nibble_out <= {gcr_nibble_out[3:0], gcr_byte_out[~bit_cnt]};

      if (bit_cnt == 7) begin
        dout         <= {gcr_byte[6:0], gcr_nibble[gcr_bit_cnt]};
        gcr_byte_out <= din;
        byte_ready   <= !byte_ready;

        if (mode) begin
          if (!header_done && byte_cnt == 15) begin
            header_done    <= 1;
            sync_cnt <= 0;
          end else if (header_done && sector_done) begin
            header_done <= 0;
            sector_done <= 0;
            sync_cnt    <= 0;
            sector      <= sector_next;
          end
        end else begin
          if (din == 8'hFF && sector_done) begin
            authorize_write <= 0;
            sector_done     <= 0;
            byte_cnt        <= 0;
            sector          <= sector_next;
          end
        end
      end
    end
  end
end

endmodule
`default_nettype wire
// vim:ts=2 sw=2 tw=120 et
