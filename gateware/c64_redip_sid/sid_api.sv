// ----------------------------------------------------------------------------
// This file is part of reDIP SID, a MOS 6581/8580 SID FPGA emulation platform.
// Copyright (C) 2022 - 2023  Dag Lem <resid@nimrod.no>
//
// This source describes Open Hardware and is licensed under the CERN-OHL-S v2.
//
// You may redistribute and modify this source and make products using it under
// the terms of the CERN-OHL-S v2 (https://ohwr.org/cern_ohl_s_v2.txt).
//
// This source is distributed WITHOUT ANY EXPRESS OR IMPLIED WARRANTY,
// INCLUDING OF MERCHANTABILITY, SATISFACTORY QUALITY AND FITNESS FOR A
// PARTICULAR PURPOSE. Please see the CERN-OHL-S v2 for applicable conditions.
//
// Source location: https://github.com/daglem/reDIP-SID
// ----------------------------------------------------------------------------

// ----------------------------------------------------------------------------
// this file is based on reDIP-SID sid_api.sv
// with changes to remove SystemVerilog-specific
// code in module I/O section and adapted so it can be
// used with rest of FPGA implementation of Icepi Zero C64
// by m1nl
// ----------------------------------------------------------------------------

`default_nettype none
`timescale 1 ns / 1 ps

module sid_api (
    input  wire        clk,
    // bus_i_t mapped to individual signals
    input  wire [4:0]  bus_addr,
    input  wire [7:0]  bus_data,
    input  wire        bus_phi2,
    input  wire        bus_phi2_n,
    input  wire        bus_r_w_n,
    input  wire        bus_res,
    // cs_t mapped to individual signals
    input  wire        cs_n,
    input  wire        cs_io1_n,
    input  wire        a8,
    input  wire        a5,
    output wire [7:0]  data_o,
    // pot_i_t mapped to individual signals
    input  wire [1:0]  pot_charged,
    // pot_o_t mapped to individual signals
    output wire        pot_discharge,
    // audio_t mapped to individual signals
    input  wire [23:0] audio_i_left,
    input  wire [23:0] audio_i_right,
    output reg  [19:0] audio_o_left,
    output reg  [19:0] audio_o_right,
    // extra control
    input wire         sid_model,
    input wire         sid_mono,
    input wire         sid_variants
);

    sid::cfg_t sid1_cfg, sid2_cfg;

    // Pick requested SID variant
    assign sid1_cfg.model     = sid_model ? sid::MOS8580 : sid::MOS6581;
    assign sid1_cfg.variant   = sid::VARIANT_A;
    assign sid1_cfg.addr      = sid::D400;
    assign sid1_cfg.fc_base   = 9'd245;
    assign sid1_cfg.fc_offset = -11'sd780;

    assign sid2_cfg.model     = sid_model ? sid::MOS8580 : sid::MOS6581;
    assign sid2_cfg.variant   = sid_variants ? sid::VARIANT_B : sid::VARIANT_A;
    assign sid2_cfg.addr      = sid_mono ? (sid::D400 | sid::D420 | sid::D500) : (sid::D420 | sid::D500);
    assign sid2_cfg.fc_base   = 9'd240;
    assign sid2_cfg.fc_offset = -11'sd785;

    // Internal type mapping wires
    wire sid_bus_i_t_internal;
    wire sid_cs_t_internal;
    wire sid_reg8_t_internal;
    wire sid_pot_i_t_internal;
    wire sid_pot_o_t_internal;
    wire sid_audio_t_internal;

    // Map input signals to internal bus structure
    sid::bus_i_t bus_i;
    assign bus_i.addr = bus_addr;
    assign bus_i.data = bus_data;
    assign bus_i.phi2 = bus_phi2;
    assign bus_i.r_w_n = bus_r_w_n;
    assign bus_i.res = bus_res;

    // Map input signals to internal cs structure
    sid::cs_t cs;
    assign cs.cs_n = cs_n;
    assign cs.cs_io1_n = cs_io1_n;
    assign cs.a8 = a8;
    assign cs.a5 = a5;

    // Map input signals to internal pot structure
    sid::pot_i_t pot_i;
    assign pot_i.charged = pot_charged;

    // Map output pot signal
    sid::pot_o_t pot_o;
    assign pot_discharge = pot_o.discharge;

    // Map input signals to internal audio structure
    sid::audio_t audio_i;
    assign audio_i.left = audio_i_left;
    assign audio_i.right = audio_i_right;

    // SID pipeline cycle counters.
    sid::cycle_t voice_cycle_count = 0;
    sid::cycle_t voice_cycle;
    logic        voice_cycle_idle;
    sid::cycle_t filter_cycle = 0;

    always_comb begin
        // Idling of voice pipeline.
        voice_cycle_idle = filter_cycle == 4 || filter_cycle == 5;
        voice_cycle      = voice_cycle_idle ? 0 : voice_cycle_count;
    end

    always_ff @(posedge clk) begin
        // Start voice pipeline after the falling edge of phi2.
        // Pause voice pipeline at filter pipeline cycle 5 and 6, for the
        // latter pipeline to catch up.
        if (bus_phi2_n) begin
            // Jump directly from cycle 18 to cycle 1 if need be, just
            // keeping within the 20 cycle budget described in
            // Pipelining.md.
            voice_cycle_count <= 1;
        end else if (voice_cycle_count == 18) begin
            // Wrap around to zero after cycle 18, which is the last cycle
            // used in sid_control.sv
            voice_cycle_count <= 0;
        end else if (voice_cycle_count != 0 && !voice_cycle_idle) begin
            voice_cycle_count <= voice_cycle_count + 1;
        end

        // Start filter pipeline at voice pipeline cycle 7; one cycle before
        // the first voice output is ready.
        // Keep counting until the counter wraps around to zero.
        filter_cycle <= filter_cycle + 4'(voice_cycle == 6 || filter_cycle != 0);
    end

    // Tick approximately every ms, for smaller counters in submodules.
    // ~1MHz / 1024 = ~1kHz
    logic  [9:0] count_us = 0;
    logic [10:0] count_us_next;
    logic        tick_ms;

    always_comb begin
        // Use carry as tick.
        count_us_next = { 1'b0, count_us } + 1;
        tick_ms = count_us_next[10];
    end

    always_ff @(posedge clk) begin
        if (voice_cycle == 1) begin
            // Update counter, discarding carry.
            count_us <= count_us_next[9:0];
        end
    end

    // NB! Don't put multi-bit variables in arrays, as Yosys handles that incorrectly.
    logic [1:0] sid_cs;
    logic [1:0] model;
    logic [1:0] variant;

    always_comb begin
        model = { sid2_cfg.model, sid1_cfg.model };
        variant = { sid2_cfg.variant, sid1_cfg.variant };
    end

    // SID read-only registers.
    sid::pot_reg_t sid1_pot;
    sid::reg8_t    sid1_osc3 = 0, sid2_osc3 = 0;
    sid::reg8_t    sid1_env3 = 0, sid2_env3 = 0;

    always_comb begin
        // Chip select decode.
        // SID 2 address is configurable.
        // SID 1 is always located at D400.
        sid_cs[1] = sid2_cfg.addr[sid::D400_BIT] & ~cs.cs_n |
                    sid2_cfg.addr[sid::D420_BIT] & ~cs.cs_n & cs.a5 |
                    sid2_cfg.addr[sid::D500_BIT] & ~cs.cs_n & cs.a8 |
                    sid2_cfg.addr[sid::DE00_BIT] & ~cs.cs_io1_n;
        sid_cs[0] = sid2_cfg.addr[sid::D400_BIT] & ~cs.cs_n |
                    ~cs.cs_n & ~sid_cs[1];

        // Default to SID 1.
        // Return FF for SID 2 POTX/Y.
        mreg.pot  = (sid_cs == 2'b10) ? '1 : sid1_pot;
        mreg.osc3 = (sid_cs == 2'b10) ? sid2_osc3 : sid1_osc3;
        mreg.env3 = (sid_cs == 2'b10) ? sid2_env3 : sid1_env3;
    end

    // SID control registers.
    sid::freq_pw_t      freq_pw_1;
    logic [2:0]         test;
    logic [2:0]         sync;
    sid::control_t      control_4;
    sid::envelope_reg_t ereg_5;
    sid::filter_reg_t   freg_1;
    sid::misc_reg_t     mreg;

    sid_control control (
        .clk          (clk),
        .tick_ms      (tick_ms),
        .voice_cycle  (voice_cycle),
        .filter_cycle (filter_cycle),
        .bus_i        (bus_i),
        .cs           (sid_cs),
        .model        (model),
        .freq_pw_1    (freq_pw_1),
        .test         (test),
        .sync         (sync),
        .control_4    (control_4),
        .ereg_5       (ereg_5),
        .freg_1       (freg_1),
        .mreg         (mreg),
        .data_o       (data_o)
    );

    // SID waveform generator.
    sid::reg12_t   wav;

    sid_waveform waveform (
        .clk       (clk),
        .tick_ms   (tick_ms),
        .cycle     (voice_cycle),
        .res       (bus_i.res),
        .model     (model),
        .variant   (variant),
        .freq_pw_1 (freq_pw_1),
        .test      (test),
        .sync      (sync),
        .control_4 (control_4),
        .wav       (wav)
    );

    // SID envelope generator.
    sid::reg8_t    env;

    sid_envelope envelope (
        .clk    (clk),
        .cycle  (voice_cycle),
        .res    (bus_i.res),
        .ereg_5 (ereg_5),
        .env    (env)
    );

    // Store OSC3 and ENV3 for both SIDs.
    always_ff @(posedge clk) begin
        if (voice_cycle == 8) begin
            sid1_osc3 <= wav[11-:8];
            sid1_env3 <= env;
        end

        if (voice_cycle == 11) begin
            sid2_osc3 <= wav[11-:8];
            sid2_env3 <= env;
        end
    end

    // Pipeline for voice outputs.
    sid::s22_t dca;

    sid_voice voice (
        .clk   (clk),
        .cycle (voice_cycle),
        .model (model),
        .wav   (wav),
        .env   (env),
        .dca   (dca)
    );

    // Pipeline for filter outputs.
    sid::s20_t filter_o;
    sid::s24_t ext_in_1 = '0;
    sid::s24_t ext_in_2 = '0;

    always_ff @(posedge clk) begin
        if (filter_cycle == 1) begin
            { ext_in_1, ext_in_2 } <= audio_i;
        end else if (filter_cycle == 6) begin
            ext_in_1 <= ext_in_2;
        end

        if (filter_cycle == 9) begin
            audio_o_left <= filter_o;
        end else if (filter_cycle == 14) begin
            audio_o_right <= filter_o;
        end
    end

    sid_filter filter (
        .clk     (clk),
        .cycle   (filter_cycle),
        .freg    (freg_1),
        .cfg     (filter_cycle <= 5 ? sid1_cfg : sid2_cfg),
        // EXT IN or internal voice.
        .voice_i (filter_cycle == 5 || filter_cycle == 10 ? ext_in_1[23-:22] : dca),
        .audio_o (filter_o)
    );

    // SID POTX / POTY.
    sid_pot potxy (
       .clk   (clk),
       .cycle (voice_cycle),
       .pot_i (pot_i),
       .pot_o (pot_o),
       .pot   (sid1_pot)
    );
endmodule
