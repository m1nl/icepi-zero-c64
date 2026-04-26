// Copyright (c) 2023 Adam Gastineau
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

// Modified by m1nl to support variable read / write burst and two ports;
// P0 has priority over P1; there is no pipelining for reads, and each word
// is read sequentially - this is a potential room for improvement

`define CEIL(x) $rtoi($ceil(x))
`define MAX(x,y) (x > y) ? (x) : (y)

module tiny_sdram #(
  parameter CLOCK_SPEED   = 100000000,  // Clock speed in Hz
  parameter CAS_LATENCY   = 2,          // 1, 2, or 3 cycle delays
  parameter ALLOW_STANDBY = 1,          // 1 to enable standby

  // Port config
  parameter P0_BURST_LENGTH = 1,  // 1, 2, 4, 8 words per read
  parameter P1_BURST_LENGTH = 2
) (
  input wire clk,
  input wire reset,           // Used to trigger start of FSM
  output wire init_complete,  // SDRAM is done initializing

  // Port 0
  input wire [23 - $clog2(P0_BURST_LENGTH):0] p0_cmd_addr,

  input wire        p0_cmd_we,
  input wire        p0_cmd_valid,
  output wire       p0_cmd_ready,

  input wire [P0_BURST_LENGTH * 16 - 1:0] p0_wdata,
  input wire  [P0_BURST_LENGTH * 2 - 1:0] p0_wdata_we,
  output reg                              p0_wdata_ready,

  output reg [P0_BURST_LENGTH * 16 - 1:0] p0_rdata,
  output reg                              p0_rdata_valid,

  // Port 1
  input wire [23 - $clog2(P1_BURST_LENGTH):0] p1_cmd_addr,

  input wire        p1_cmd_we,
  input wire        p1_cmd_valid,
  output wire       p1_cmd_ready,

  input wire [P1_BURST_LENGTH * 16 - 1:0] p1_wdata,
  input wire  [P1_BURST_LENGTH * 2 - 1:0] p1_wdata_we,
  output reg                              p1_wdata_ready,

  output reg [P1_BURST_LENGTH * 16 - 1:0] p1_rdata,
  output reg                              p1_rdata_valid,

  inout  wire [15:0] SDRAM_DQ,    // Bidirectional data bus
  output reg  [12:0] SDRAM_A,     // Address bus
  output reg  [ 1:0] SDRAM_DQM,   // High/low byte mask
  output reg  [ 1:0] SDRAM_BA,    // Bank select (single bits)
  output wire        SDRAM_nCS,   // Chip select, neg triggered
  output wire        SDRAM_nWE,   // Write enable, neg triggered
  output wire        SDRAM_nRAS,  // Select row address, neg triggered
  output wire        SDRAM_nCAS,  // Select column address, neg triggered
  output reg         SDRAM_CKE    // Clock enable
);
  localparam real CLOCK_PERIOD_NANO_SEC = 1.0e9 / $itor(CLOCK_SPEED);

  // Config values
  // NOTE: These are configured by default for the Pocket's SDRAM
  localparam real SETTING_INHIBIT_DELAY_MICRO_SEC = 100;

  // tCK - Min clock cycle time
  localparam real SETTING_T_CK_MIN_CLOCK_CYCLE_TIME_NANO_SEC = 7.5;

  // tRAS - Min row active time
  localparam real SETTING_T_RAS_MIN_ROW_ACTIVE_TIME_NANO_SEC = 42;

  // tRC - Min row cycle time
  localparam real SETTING_T_RC_MIN_ROW_CYCLE_TIME_NANO_SEC = 60;

  // tRP - Min precharge command period
  localparam real SETTING_T_RP_MIN_PRECHARGE_CMD_PERIOD_NANO_SEC = 15;

  // tRFC - Min autorefresh period
  localparam real SETTING_T_RFC_MIN_AUTOREFRESH_PERIOD_NANO_SEC = 60;

  // tRC - Min active to active command period for the same bank
  localparam real SETTING_T_RC_MIN_ACTIVE_TO_ACTIVE_PERIOD_NANO_SEC = 60;

  // tRCD - Min read/write delay
  localparam real SETTING_T_RCD_MIN_READ_WRITE_DELAY_NANO_SEC = 15;

  // tWR - Min write auto precharge recovery time
  localparam real SETTING_T_WR_MIN_WRITE_AUTO_PRECHARGE_RECOVERY_NANO_SEC = 2 * CLOCK_PERIOD_NANO_SEC;

  // tMRD - Min number of clock cycles between mode set and normal usage
  localparam SETTING_T_MRD_MIN_LOAD_MODE_CLOCK_CYCLES = 2;

  // 8,192 refresh commands every 64ms = 7.8125us, which we round to 7500ns to make sure we hit them all
  localparam real SETTING_REFRESH_TIMER_NANO_SEC = 7500;

  // Reads will be delayed by 1 cycle when enabled
  // Highly recommended that you use with SDRAM with FAST_INPUT_REGISTER enabled for timing and stability
  // This makes read timing incompatible with the test model
  localparam SETTING_USE_FAST_INPUT_REGISTER = 1;

  ////////////////////////////////////////////////////////////////////////////////////////
  // Generated parameters

  // Number of cycles after reset until we start command inhibit
  localparam CYCLES_UNTIL_START_INHIBIT =
      `CEIL(SETTING_INHIBIT_DELAY_MICRO_SEC * 500.0 / CLOCK_PERIOD_NANO_SEC);
  // Number of cycles after reset until we clear command inhibit and start operation
  // We add 100 cycles for good measure
  localparam CYCLES_UNTIL_CLEAR_INHIBIT = 100 +
      `CEIL(SETTING_INHIBIT_DELAY_MICRO_SEC * 1000.0 / CLOCK_PERIOD_NANO_SEC);

  // Number of cycles for precharge duration
  // localparam CYCLES_FOR_PRECHARGE =
  // `CEIL(SETTING_T_RP_MIN_PRECHARGE_CMD_PERIOD_NANO_SEC / CLOCK_PERIOD_NANO_SEC);

  // Number of cycles for autorefresh duration
  localparam CYCLES_FOR_AUTOREFRESH =
      `CEIL(SETTING_T_RFC_MIN_AUTOREFRESH_PERIOD_NANO_SEC / CLOCK_PERIOD_NANO_SEC);

  // Number of cycles between two active commands to the same bank
  // TODO: Use this value
  localparam CYCLES_BETWEEN_ACTIVE_COMMAND =
      `CEIL(SETTING_T_RC_MIN_ACTIVE_TO_ACTIVE_PERIOD_NANO_SEC / CLOCK_PERIOD_NANO_SEC);

  // Number of cycles after active command before a read/write can be executed
  localparam CYCLES_FOR_ACTIVE_ROW =
      `CEIL(SETTING_T_RCD_MIN_READ_WRITE_DELAY_NANO_SEC / CLOCK_PERIOD_NANO_SEC);

  // Number of cycles after write before next command
  localparam CYCLES_AFTER_WRITE_FOR_NEXT_COMMAND =
      `CEIL(
          (SETTING_T_WR_MIN_WRITE_AUTO_PRECHARGE_RECOVERY_NANO_SEC + SETTING_T_RP_MIN_PRECHARGE_CMD_PERIOD_NANO_SEC) / CLOCK_PERIOD_NANO_SEC);

  // Number of cycles between each autorefresh command
  localparam CYCLES_PER_REFRESH =
      `CEIL(SETTING_REFRESH_TIMER_NANO_SEC / CLOCK_PERIOD_NANO_SEC);

  // Number of cycles row has to stay open before precharge
  localparam CYCLES_PER_ROW_OPEN_WITH_PRECHARGE =
      `MAX(
          `CEIL(
              (SETTING_T_RAS_MIN_ROW_ACTIVE_TIME_NANO_SEC + SETTING_T_RP_MIN_PRECHARGE_CMD_PERIOD_NANO_SEC) / CLOCK_PERIOD_NANO_SEC),
          `CEIL(SETTING_T_RC_MIN_ROW_CYCLE_TIME_NANO_SEC / CLOCK_PERIOD_NANO_SEC)
      );

  ////////////////////////////////////////////////////////////////////////////////////////
  // Init helpers
  // Number of cycles after reset until we are done with precharge
  // We add 10 cycles for good measure
  localparam CYCLES_UNTIL_INIT_PRECHARGE_END = 10 + CYCLES_UNTIL_CLEAR_INHIBIT +
      `CEIL(SETTING_T_RP_MIN_PRECHARGE_CMD_PERIOD_NANO_SEC / CLOCK_PERIOD_NANO_SEC);

  localparam CYCLES_UNTIL_REFRESH1_END = CYCLES_UNTIL_INIT_PRECHARGE_END + CYCLES_FOR_AUTOREFRESH;
  localparam CYCLES_UNTIL_REFRESH2_END = CYCLES_UNTIL_REFRESH1_END + CYCLES_FOR_AUTOREFRESH;

  // Reserved, write burst, operating mode, CAS latency, burst type, burst length
  wire [12:0] configured_mode = {
    3'b0, 1'b1, 2'b0, CAS_LATENCY[2:0], 1'b0, 3'h0
  };

  localparam P0_OUTPUT_WIDTH = P0_BURST_LENGTH * 16;
  localparam P1_OUTPUT_WIDTH = P1_BURST_LENGTH * 16;

  localparam OUTPUT_WIDTH = P0_OUTPUT_WIDTH > P1_OUTPUT_WIDTH ? P0_OUTPUT_WIDTH : P1_OUTPUT_WIDTH;

  localparam P0_ADDR_LSB = $clog2(P0_BURST_LENGTH);
  localparam P1_ADDR_LSB = $clog2(P1_BURST_LENGTH);

  // nCS, nRAS, nCAS, nWE
  typedef enum bit [3:0] {
    COMMAND_NOP           = 4'b0111,
    COMMAND_ACTIVE        = 4'b0011,
    COMMAND_READ          = 4'b0101,
    COMMAND_WRITE         = 4'b0100,
    COMMAND_PRECHARGE     = 4'b0010,
    COMMAND_AUTO_REFRESH  = 4'b0001,
    COMMAND_LOAD_MODE_REG = 4'b0000
  } command;

  ////////////////////////////////////////////////////////////////////////////////////////
  // State machine

  typedef enum bit [2:0] {
    INIT,
    STANDBY,
    IDLE,
    DELAY,
    WRITE,
    READ,
    READ_OUTPUT
  } state_fsm;

  (* fsm_encoding = "auto" *)
  state_fsm state;

  (* fsm_encoding = "none" *)
  state_fsm delay_state;

  // TODO: Could use fewer bits
  reg [31:0] delay_counter = 0;
  // Number of cycles since row was locked
  reg [7:0] ras_counter = 8'hff;
  // The number of words we're reading
  reg [3:0] burst_counter = 0;

  // Measures when auto refresh needs to be triggered
  reg [15:0] refresh_counter = 0;

  reg active_port = 0;

  command sdram_command;
  assign {SDRAM_nCS, SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} = sdram_command;

  ////////////////////////////////////////////////////////////////////////////////////////
  // Port 0 specifics

  // Cache the signals we received, potentially while busy
  reg [23:0] p0_cmd_addr_queue = 0;

  reg p0_cmd_we_queue = 0;
  reg p0_cmd_pending = 0;

  reg     [P0_OUTPUT_WIDTH - 1:0] p0_wdata_queue = 0;
  reg [P0_BURST_LENGTH * 2 - 1:0] p0_wdata_we_queue = 0;

  // The current p0 address that should be used for any operations on this first cycle only
  wire [23:0] p0_cmd_addr_current = p0_cmd_pending ? p0_cmd_addr_queue : {p0_cmd_addr, {{P0_ADDR_LSB}{1'b0}}};

  // An active new request or cached request
  wire p0_cmd_wr = p0_cmd_pending ? p0_cmd_we_queue  : (p0_cmd_valid && p0_cmd_we);
  wire p0_cmd_rd = p0_cmd_pending ? !p0_cmd_we_queue : (p0_cmd_valid && !p0_cmd_we);

  ////////////////////////////////////////////////////////////////////////////////////////
  // Port 1 specifics

  // Cache the signals we received, potentially while busy
  reg [23:0] p1_cmd_addr_queue = 0;

  reg p1_cmd_we_queue = 0;
  reg p1_cmd_pending = 0;

  reg     [P1_OUTPUT_WIDTH - 1:0] p1_wdata_queue = 0;
  reg [P1_BURST_LENGTH * 2 - 1:0] p1_wdata_we_queue = 0;

  // The current p1 address that should be used for any operations on this first cycle only
  wire [23:0] p1_cmd_addr_current = p1_cmd_pending ? p1_cmd_addr_queue : {p1_cmd_addr, {{P1_ADDR_LSB}{1'b0}}};

  // An active new request or cached request
  wire p1_cmd_wr = p1_cmd_pending ? p1_cmd_we_queue  : (p1_cmd_valid && p1_cmd_we);
  wire p1_cmd_rd = p1_cmd_pending ? !p1_cmd_we_queue : (p1_cmd_valid && !p1_cmd_we);

  ////////////////////////////////////////////////////////////////////////////////////////
  // Helpers

  // Activates a row
  task set_active_command(logic port, logic [23:0] addr, state_fsm next_state);
    sdram_command <= COMMAND_ACTIVE;

    // Set active port
    active_port <= port;

    // Upper two bits choose the bank
    SDRAM_BA <= addr[23:22];

    // Row address
    SDRAM_A <= addr[21:9];

    if (CYCLES_FOR_ACTIVE_ROW <= 1) begin
        state <= next_state;
    end else begin
        state       <= DELAY;
        delay_state <= next_state;

        // Current construction takes two cycles to write next data
        delay_counter <= CYCLES_FOR_ACTIVE_ROW - 32'h2;
    end

    // Initiate burst counter
    burst_counter <= 0;

    // Initiate RAS counter
    ras_counter <= 0;
  endtask

  reg dq_output = 0;

  reg [15:0] sdram_data = 0;
  assign SDRAM_DQ = dq_output ? sdram_data : 16'hZZZZ;

  assign init_complete = (state != INIT);

  assign p0_cmd_ready = !p0_cmd_pending && init_complete;
  assign p1_cmd_ready = !p1_cmd_pending && init_complete;

  wire [23:0] cmd_addr_queue = active_port ? p1_cmd_addr_queue : p0_cmd_addr_queue;

  wire [OUTPUT_WIDTH - 1:0] wdata_queue = active_port ?
    {{(OUTPUT_WIDTH - P1_OUTPUT_WIDTH){1'b0}}, p1_wdata_queue} :
    {{(OUTPUT_WIDTH - P0_OUTPUT_WIDTH){1'b0}}, p0_wdata_queue};

  wire [15:0] wdata_we_queue = active_port ?
    {{(16 - P1_BURST_LENGTH * 2){1'b0}}, p1_wdata_we_queue} :
    {{(16 - P0_BURST_LENGTH * 2){1'b0}}, p0_wdata_we_queue};

  wire [3:0] expected_count = active_port ? P1_BURST_LENGTH : P0_BURST_LENGTH;

  ////////////////////////////////////////////////////////////////////////////////////////
  // Process

  wire cmd_pending = (refresh_counter >= CYCLES_PER_REFRESH[15:0]) ||
      p0_cmd_wr || p0_cmd_rd || p1_cmd_wr || p1_cmd_rd;

  always_ff @(posedge clk) begin
    if (reset) begin
      // Assert and hold CKE at logic low
      SDRAM_CKE     <= 0;
      sdram_command <= COMMAND_NOP;
      dq_output     <= 0;

      state <= INIT;

      delay_counter <= 0;
      delay_state   <= IDLE;

      refresh_counter <= 0;
      ras_counter     <= 8'hff;

      p0_cmd_pending <= 0;
      p1_cmd_pending <= 0;

      p0_wdata_ready <= 0;
      p1_wdata_ready <= 0;

      p0_rdata_valid <= 0;
      p1_rdata_valid <= 0;

    end else begin
      // Cache port 0 input values
      if (p0_cmd_valid && p0_cmd_ready) begin
        p0_cmd_addr_queue <= p0_cmd_addr_current;
        p0_cmd_we_queue   <= p0_cmd_we;
        p0_cmd_pending    <= 1'b1;

        p0_wdata_queue    <= p0_wdata;
        p0_wdata_we_queue <= p0_wdata_we;
      end

      // Cache port 1 input values
      if (p1_cmd_valid && p1_cmd_ready) begin
        p1_cmd_addr_queue <= p1_cmd_addr_current;
        p1_cmd_we_queue   <= p1_cmd_we;
        p1_cmd_pending    <= 1'b1;

        p1_wdata_queue    <= p1_wdata;
        p1_wdata_we_queue <= p1_wdata_we;
      end

      // Ensure pulse
      p0_rdata_valid <= 0;
      p0_wdata_ready <= 0;

      p1_rdata_valid <= 0;
      p1_wdata_ready <= 0;

      // Default to NOP at all times in between commands
      // NOP
      sdram_command <= COMMAND_NOP;

      if (state != INIT) begin
        refresh_counter <= refresh_counter + 16'h1;

        if (!(&ras_counter))
          ras_counter <= ras_counter + 8'h1;
      end

      case (state)
        INIT: begin
          delay_counter <= delay_counter + 32'h1;

          if (delay_counter == CYCLES_UNTIL_START_INHIBIT) begin
            // Start setting inhibit
            // 5. Starting at some point during this 100us period, bring CKE high
            SDRAM_CKE <= 1;

            // We're already asserting NOP above
          end else if (delay_counter == CYCLES_UNTIL_CLEAR_INHIBIT) begin
            // Clear inhibit, start precharge
            sdram_command <= COMMAND_PRECHARGE;

            // Mark all banks for refresh
            SDRAM_A[10] <= 1;
          end else if (delay_counter == CYCLES_UNTIL_INIT_PRECHARGE_END || delay_counter == CYCLES_UNTIL_REFRESH1_END) begin
            // Precharge done (or first auto refresh), auto refresh
            // CKE high specifies auto refresh
            SDRAM_CKE <= 1;

            sdram_command <= COMMAND_AUTO_REFRESH;
          end else if (delay_counter == CYCLES_UNTIL_REFRESH2_END) begin
            // Second auto refresh done, load mode register
            sdram_command <= COMMAND_LOAD_MODE_REG;

            SDRAM_BA <= 2'b0;
            SDRAM_A  <= configured_mode;
          end else if (delay_counter == CYCLES_UNTIL_REFRESH2_END + SETTING_T_MRD_MIN_LOAD_MODE_CLOCK_CYCLES) begin
            // We can now execute commands
            state <= IDLE;

            // We're already asserting NOP above
          end
        end
        STANDBY: begin
          // Stop outputting on DQ and hold in high Z
          dq_output <= 0;

          // Disable clock enable to save power
          SDRAM_CKE <= 0;

          if (cmd_pending) begin
            state     <= IDLE;
            SDRAM_CKE <= 1;
          end

          // We're already asserting NOP above
        end
        IDLE: begin
          // Stop outputting on DQ and hold in high Z
          dq_output <= 0;

          if (ras_counter < CYCLES_PER_ROW_OPEN_WITH_PRECHARGE[7:0]) begin
            // Since we auto-precharge, ensure we wait for at least tRAS + tRP before activating next row
            state <= IDLE;

          end else if (refresh_counter >= CYCLES_PER_REFRESH[15:0]) begin
            // Trigger refresh
            state         <= DELAY;
            delay_state   <= IDLE;
            delay_counter <= CYCLES_FOR_AUTOREFRESH > 32'h2 ? CYCLES_FOR_AUTOREFRESH - 32'h2 : 32'h0;

            refresh_counter <= 0;

            sdram_command <= COMMAND_AUTO_REFRESH;
          end else if (p0_cmd_wr) begin
            // Port 0 write
            set_active_command(0, p0_cmd_addr_current, WRITE);
          end else if (p0_cmd_rd) begin
            // Port 0 read
            set_active_command(0, p0_cmd_addr_current, READ);
          end else if (p1_cmd_wr) begin
            // Port 1 write
            set_active_command(1, p1_cmd_addr_current, WRITE);
          end else if (p1_cmd_rd) begin
            // Port 1 read
            set_active_command(1, p1_cmd_addr_current, READ);
          end else if (ALLOW_STANDBY) begin
            state     <= STANDBY;
            SDRAM_CKE <= 0;
          end
        end
        DELAY: begin
          if (delay_counter != 0) begin
            delay_counter <= delay_counter - 32'h1;

          end else begin
            case (delay_state)
              STANDBY: state <= STANDBY;
              WRITE: state <= WRITE;
              READ: state <= READ;
              READ_OUTPUT: state <= READ_OUTPUT;
              default: state <= IDLE;
            endcase
          end
        end
        WRITE: begin
          logic [127:0] temp;
          logic         last;

          last = burst_counter == (expected_count - 1);

          case (active_port)
            0: begin
              temp = {{(128 - P0_OUTPUT_WIDTH){1'b0}}, p0_wdata_queue};
            end
            1: begin
              temp = {{(128 - P1_OUTPUT_WIDTH){1'b0}}, p1_wdata_queue};
            end
          endcase

          // Enable DQ output
          dq_output <= 1;

          // Pick range from write data registers
          case (burst_counter)
            0: begin sdram_data <= temp[15:0];    SDRAM_DQM <= ~wdata_we_queue[1:0];   end
            1: begin sdram_data <= temp[31:16];   SDRAM_DQM <= ~wdata_we_queue[3:2];   end
            2: begin sdram_data <= temp[47:32];   SDRAM_DQM <= ~wdata_we_queue[5:4];   end
            3: begin sdram_data <= temp[63:48];   SDRAM_DQM <= ~wdata_we_queue[7:6];   end
            4: begin sdram_data <= temp[79:64];   SDRAM_DQM <= ~wdata_we_queue[9:8];   end
            5: begin sdram_data <= temp[95:80];   SDRAM_DQM <= ~wdata_we_queue[11:10]; end
            6: begin sdram_data <= temp[111:96];  SDRAM_DQM <= ~wdata_we_queue[13:12]; end
            7: begin sdram_data <= temp[127:112]; SDRAM_DQM <= ~wdata_we_queue[15:14]; end
          endcase

          // NOTE: Bank is still set from ACTIVE command assertion
          // High bit enables auto precharge. I assume the top 2 bits are unused
          // Precharge when last word is written
          SDRAM_A <= {2'b0, last, 1'b0, cmd_addr_queue[8:0] + {4'b0, burst_counter}};

          sdram_command <= COMMAND_WRITE;

          // We assume burst has not finished yet
          state         <= WRITE;
          burst_counter <= burst_counter + 4'd1;

          if (last) begin
            state       <= DELAY;
            delay_state <= IDLE;

            // A write must wait for auto precharge (tWR) and precharge command period (tRP)
            // Takes one cycle to get back to IDLE, and another to read command
            delay_counter <= CYCLES_AFTER_WRITE_FOR_NEXT_COMMAND > 32'h2 ? CYCLES_AFTER_WRITE_FOR_NEXT_COMMAND - 32'h2 : 32'h0;

            case (active_port)
              0: begin
                p0_wdata_ready <= 1;

                // Clear pending command
                p0_cmd_pending <= 1'b0;
              end
              1: begin
                p1_wdata_ready <= 1;

                // Clear pending command
                p1_cmd_pending <= 1'b0;
              end
            endcase
          end
        end
        READ: begin
          logic last;

          last = burst_counter == (expected_count - 1);

          if (CAS_LATENCY == 1 && ~SETTING_USE_FAST_INPUT_REGISTER) begin
            // Go directly to read
            state <= READ_OUTPUT;
          end else begin
            state       <= DELAY;
            delay_state <= READ_OUTPUT;

            // Takes one cycle to go to read data, and one to actually read the data
            // Fast input register delays operation by a cycle
            delay_counter <= (CAS_LATENCY + SETTING_USE_FAST_INPUT_REGISTER) > 32'h2 ? (CAS_LATENCY + SETTING_USE_FAST_INPUT_REGISTER) - 32'h2 : 32'h0;
          end

          // NOTE: Bank is still set from ACTIVE command assertion
          // High bit enables auto precharge. I assume the top 2 bits are unused
          // Precharge when last word is read
          SDRAM_A <= {2'b0, last, 1'b0, cmd_addr_queue[8:0] + {4'b0, burst_counter}};

          // Fetch all bytes
          SDRAM_DQM <= 2'b0;

          sdram_command <= COMMAND_READ;

          if (last) begin
            case (active_port)
              0: begin
                // Clear pending command
                p0_cmd_pending <= 1'b0;
              end
              1: begin
                // Clear pending command
                p1_cmd_pending <= 1'b0;
              end
            endcase
          end
        end
        READ_OUTPUT: begin
          logic [127:0] temp;
          logic         last;

          last = burst_counter == (expected_count - 1);

          case (active_port)
            0: begin
              temp[P0_OUTPUT_WIDTH - 1:0] = p0_rdata;
            end
            1: begin
              temp[P1_OUTPUT_WIDTH - 1:0] = p1_rdata;
            end
          endcase

         case (burst_counter)
            0: temp[15:0]    = SDRAM_DQ;
            1: temp[31:16]   = SDRAM_DQ;
            2: temp[47:32]   = SDRAM_DQ;
            3: temp[63:48]   = SDRAM_DQ;
            4: temp[79:64]   = SDRAM_DQ;
            5: temp[95:80]   = SDRAM_DQ;
            6: temp[111:96]  = SDRAM_DQ;
            7: temp[127:112] = SDRAM_DQ;
          endcase

          state         <= last ? IDLE : READ;
          burst_counter <= burst_counter + 4'd1;

          case (active_port)
            0: begin
              p0_rdata       <= temp[P0_OUTPUT_WIDTH - 1:0];
              p0_rdata_valid <= last;
            end
            1: begin
              p1_rdata       <= temp[P1_OUTPUT_WIDTH - 1:0];
              p1_rdata_valid <= last;
            end
          endcase
        end
        default: begin
          state <= INIT;
        end
      endcase
    end
  end

  initial begin
    $display("sdram: CLOCK_SPEED=%0d Hz, CLOCK_PERIOD_NANO_SEC=%0d ns", CLOCK_SPEED, $rtoi(CLOCK_PERIOD_NANO_SEC));
    $display("sdram: CYCLES_UNTIL_START_INHIBIT=%0d", CYCLES_UNTIL_START_INHIBIT);
    $display("sdram: CYCLES_UNTIL_CLEAR_INHIBIT=%0d", CYCLES_UNTIL_CLEAR_INHIBIT);
    $display("sdram: CYCLES_UNTIL_INIT_PRECHARGE_END=%0d", CYCLES_UNTIL_INIT_PRECHARGE_END);
    $display("sdram: CYCLES_UNTIL_REFRESH1_END=%0d", CYCLES_UNTIL_REFRESH1_END);
    $display("sdram: CYCLES_UNTIL_REFRESH2_END=%0d", CYCLES_UNTIL_REFRESH2_END);
    $display("sdram: CYCLES_FOR_AUTOREFRESH=%0d", CYCLES_FOR_AUTOREFRESH);
    $display("sdram: CYCLES_FOR_ACTIVE_ROW=%0d", CYCLES_FOR_ACTIVE_ROW);
    $display("sdram: CYCLES_AFTER_WRITE_FOR_NEXT_COMMAND=%0d", CYCLES_AFTER_WRITE_FOR_NEXT_COMMAND);
    $display("sdram: CYCLES_PER_REFRESH=%0d", CYCLES_PER_REFRESH);
    $display("sdram: CYCLES_PER_ROW_OPEN_WITH_PRECHARGE=%0d", CYCLES_PER_ROW_OPEN_WITH_PRECHARGE);
  end

endmodule
// vim:ts=2 sw=2 tw=120 et
