# ---------------------------------------------------------------------------
# Copyright 2026 Mateusz Nalewajski
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.
#
# SPDX-License-Identifier: GPL-3.0-or-later
# ---------------------------------------------------------------------------

import os

from litex.build.vhd2v_converter import VHD2VConverter
from litex.gen import *
from litex.soc.interconnect import stream
from litex.soc.interconnect.csr import *
from litex.soc.interconnect.csr_eventmanager import *
from migen import *

from gateware.video_terminal_overlay import VideoOverlay


class C64Control(LiteXModule):
    def __init__(self):
        self.flags = CSRStorage(16, reset=0b0000100001111111, description="C64 flags")
        self.vic_reset_req = CSRStorage(1, reset=0, description="C64 VIC reset request")
        self.cpu_reset_req = CSRStorage(1, reset=1, description="C64 CPU reset request")
        self.cpu_pause_req = CSRStorage(1, reset=0, description="C64 CPU puse request")
        self.block_ack = CSRStorage(1, reset=0, description="Block device ACK (toggle)")
        self.img_mounted = CSRStorage(1, reset=0, description="Floppy disk image mounted (toggle)")
        self.img_readonly = CSRStorage(1, reset=0, description="Floppy disk image read-only")
        self.img_size = CSRStorage(32, reset=0, description="Floppy disk image size")
        self.img_id = CSRStorage(16, reset=0, description="Floppy disk image ID")

        self.block_lba = CSRStatus(32, description="Block device LBA")
        self.block_cnt = CSRStatus(6, description="Block device count")

        self.hid_key_modifiers = CSRStatus(8, description="HID key modifiers")
        self.hid_key_0 = CSRStatus(8, description="HID key 0")

        self.tape_play = CSRStorage(1, reset=0, description="Tape play (toggle)")
        self.tape_cass_sense = CSRStatus(1, description="Tape cassette sense")
        self.tape_cass_motor = CSRStatus(1, description="Tape cassette motor")

        self.ps2_character_valid = CSRStorage(1, reset=0, description="PS2 character valid (toggle)")
        self.ps2_character_data = CSRStorage(8, reset=0, description="PS2 character data")

        self.submodules.ev = EventManager()
        self.ev.block_rd = EventSourcePulse(description="Block device read trigger")
        self.ev.block_wr = EventSourcePulse(description="Block device write trigger")
        self.ev.hid_key = EventSourcePulse(description="HID key report received")
        self.ev.kbd_overlay = EventSourcePulse(description="Toggle screen overlay")
        self.ev.kbd_reset_req = EventSourcePulse(description="Reset request")
        self.ev.kbd_tape_play = EventSourcePulse(description="Tape play trigger")
        self.ev.tape_stop = EventSourcePulse(description="Tape stop event")
        self.ev.finalize()


class C64Top(Module):
    def __init__(
        self,
        platform,
        sdram_port,
        drive_rom,
        drive_shmem,
        leds,
        tmds_0,
        tmds_1,
        tmds_2,
        usb_0,
        usb_1,
        iec,
        sdram_bank=0b11,
        sys_clk_freq=31527777,
        clk_domain="sys",
        tmds_clk_freq=27588750,
        tmds_clk_domain="hdmi",
        usb_clk_domain="usb",
    ):
        self.tap_sink = tap_sink = stream.Endpoint([("data", 8)])
        self.ps2_sink = ps2_sink = stream.Endpoint([("data", 8)])
        self.video_overlay = video_overlay = VideoOverlay()

        self.submodules.control = control = C64Control()

        block_ack_d = Signal()
        block_ack_pulse = Signal()
        self.sync += block_ack_d.eq(self.control.block_ack.storage)
        self.comb += block_ack_pulse.eq(self.control.block_ack.storage ^ block_ack_d)

        img_mounted_d = Signal()
        img_mounted_pulse = Signal()
        self.sync += img_mounted_d.eq(self.control.img_mounted.storage)
        self.comb += img_mounted_pulse.eq(self.control.img_mounted.storage ^ img_mounted_d)

        tape_play_d = Signal()
        tape_play_pulse = Signal()
        self.sync += tape_play_d.eq(self.control.tape_play.storage)
        self.comb += tape_play_pulse.eq(self.control.tape_play.storage ^ tape_play_d)

        tape_cass_sense_n = Signal()
        tape_cass_motor_n = Signal()
        self.comb += self.control.tape_cass_sense.status.eq(~tape_cass_sense_n)
        self.comb += self.control.tape_cass_motor.status.eq(~tape_cass_motor_n)

        tape_cass_sense_n_d = Signal()
        self.sync += tape_cass_sense_n_d.eq(tape_cass_sense_n)
        self.comb += self.control.ev.tape_stop.trigger.eq(tape_cass_sense_n & ~tape_cass_sense_n_d)

        rst = Signal()
        self.comb += rst.eq(ResetSignal(clk_domain) | ~sdram_port.init_complete)

        vic_reset_req = self.control.vic_reset_req.storage
        cpu_reset_req = self.control.cpu_reset_req.storage
        cpu_pause_req = self.control.cpu_pause_req.storage

        # IEC open-drain pads
        # The bus is active-low open-collector: a device pulls the line low to assert it.
        # TSTriple: oe=1 drives pad low (o=0), oe=0 releases pad (high-Z, pulled up by PULLMODE=UP).
        iec_data_out = Signal()
        iec_clk_out = Signal()
        iec_atn_out = Signal()
        iec_data_in = Signal()
        iec_clk_in = Signal()
        iec_atn_in = Signal()

        for sig_out, sig_in, pad in [
            (iec_data_out, iec_data_in, iec.data),
            (iec_clk_out, iec_clk_in, iec.clk),
            (iec_atn_out, iec_atn_in, iec.atn),
        ]:
            t = TSTriple()
            self.specials += t.get_tristate(pad)
            self.comb += [
                t.o.eq(0),
                t.oe.eq(~sig_out),
                sig_in.eq(t.i),
            ]

        tap_fifo_rd_data = Signal(8)
        tap_fifo_rd_valid = Signal()
        tap_fifo_rd_en = Signal()
        self.comb += [
            tap_fifo_rd_data.eq(tap_sink.data),
            tap_fifo_rd_valid.eq(tap_sink.valid),
            tap_sink.ready.eq(tap_fifo_rd_en),
        ]

        ps2_fifo_rd_data = Signal(8)
        ps2_fifo_rd_valid = Signal()
        ps2_fifo_rd_en = Signal()
        self.comb += [
            ps2_fifo_rd_data.eq(ps2_sink.data),
            ps2_fifo_rd_valid.eq(ps2_sink.valid),
            ps2_sink.ready.eq(ps2_fifo_rd_en),
        ]

        ps2_character_valid_d = Signal()
        ps2_character_valid_pulse = Signal()
        self.sync += ps2_character_valid_d.eq(self.control.ps2_character_valid.storage)
        self.comb += ps2_character_valid_pulse.eq(self.control.ps2_character_valid.storage ^ ps2_character_valid_d)

        ps2_source = stream.Endpoint([("data", 8)])

        self.comb += [
            ps2_source.data.eq(self.control.ps2_character_data.storage),
            ps2_source.valid.eq(ps2_character_valid_pulse),
        ]

        self.submodules.ps2_fifo = ps2_fifo = stream.SyncFIFO([("data", 8)], 16, buffered=True)

        self.comb += [
            ps2_source.connect(ps2_fifo.sink),
            ps2_fifo.source.connect(ps2_sink),
        ]

        drive_shmem_en = Signal()
        drive_shmem_we = Signal(4)

        self.comb += [
            drive_shmem.we.eq(Mux(drive_shmem_en, drive_shmem_we, 0)),
        ]

        self.specials += Instance(
            "c64_top",
            p_SDRAM_BANK=sdram_bank,
            p_C1541_EXTERNAL_ROM=(drive_rom is not None),
            p_SYS_CLK_FREQUENCY=int(sys_clk_freq),
            p_TMDS_CLK_FREQUENCY=int(tmds_clk_freq),
            i_clk=ClockSignal(clk_domain),
            i_rst=rst,
            i_vic_reset_req=vic_reset_req,
            i_cpu_reset_req=cpu_reset_req,
            i_cpu_pause_req=cpu_pause_req,
            # SDRAM port
            o_mem_cmd_addr=sdram_port.cmd_addr,
            o_mem_cmd_we=sdram_port.cmd_we,
            o_mem_cmd_valid=sdram_port.cmd_valid,
            i_mem_cmd_ready=sdram_port.cmd_ready,
            o_mem_wdata=sdram_port.wdata,
            o_mem_wdata_we=sdram_port.wdata_we,
            i_mem_wdata_ready=sdram_port.wdata_ready,
            i_mem_rdata=sdram_port.rdata,
            i_mem_rdata_valid=sdram_port.rdata_valid,
            # LEDs
            o_leds=leds,
            # TMDS
            i_tmds_clk=ClockSignal(tmds_clk_domain),
            i_tmds_rst=ResetSignal(tmds_clk_domain),
            o_tmds_0=tmds_0,
            o_tmds_1=tmds_1,
            o_tmds_2=tmds_2,
            # USB
            i_usb_clk=ClockSignal(usb_clk_domain),
            i_usb_rst=ResetSignal(usb_clk_domain),
            o_usb_pullup_dp_0=usb_0.pullup[0],
            o_usb_pullup_dn_0=usb_0.pullup[1],
            o_usb_pullup_dp_1=usb_1.pullup[0],
            o_usb_pullup_dn_1=usb_1.pullup[1],
            io_usb_dp_0=usb_0.d_p,
            io_usb_dn_0=usb_0.d_n,
            io_usb_dp_1=usb_1.d_p,
            io_usb_dn_1=usb_1.d_n,
            # Flags
            i_flags=self.control.flags.storage,
            # IEC serial bus
            o_iec_data_out=iec_data_out,
            o_iec_clk_out=iec_clk_out,
            o_iec_atn_out=iec_atn_out,
            i_iec_data_in=iec_data_in,
            i_iec_clk_in=iec_clk_in,
            i_iec_atn_in=iec_atn_in,
            # 1541 drive ROM
            o_drive_rom_en=None,
            o_drive_rom_addr=(drive_rom.adr if drive_rom else None),
            i_drive_rom_dout=(drive_rom.dat_r if drive_rom else None),
            # 1541 drive shared memory
            o_drive_shmem_en=drive_shmem_en,
            o_drive_shmem_addr=drive_shmem.adr,
            o_drive_shmem_din=drive_shmem.dat_w,
            i_drive_shmem_dout=drive_shmem.dat_r,
            o_drive_shmem_we=drive_shmem_we,
            # Block device
            o_block_lba=self.control.block_lba.status,
            o_block_cnt=self.control.block_cnt.status,
            o_block_rd=self.control.ev.block_rd.trigger,
            o_block_wr=self.control.ev.block_wr.trigger,
            i_block_ack=block_ack_pulse,
            # Floppy disk image
            i_img_mounted=img_mounted_pulse,
            i_img_readonly=self.control.img_readonly.storage,
            i_img_size=self.control.img_size.storage,
            i_img_id=self.control.img_id.storage,
            # Video overlay
            i_overlay_pixel=self.video_overlay.rgb,
            o_overlay_pixel_x=self.video_overlay.x,
            o_overlay_pixel_y=self.video_overlay.y,
            i_overlay_pixel_valid=self.video_overlay.valid,
            # HID key report
            o_hid_key_report_out=self.control.ev.hid_key.trigger,
            o_hid_key_modifiers_out=self.control.hid_key_modifiers.status,
            o_hid_key_0_out=self.control.hid_key_0.status,
            # Tape
            i_tape_play_toggle=tape_play_pulse,
            o_tape_cass_sense_n=tape_cass_sense_n,
            o_tape_cass_motor_n=tape_cass_motor_n,
            i_tap_fifo_rd_data=tap_fifo_rd_data,
            i_tap_fifo_rd_valid=tap_fifo_rd_valid,
            o_tap_fifo_rd_en=tap_fifo_rd_en,
            # PS2 emulation
            i_ps2_fifo_rd_data=ps2_fifo_rd_data,
            i_ps2_fifo_rd_valid=ps2_fifo_rd_valid,
            o_ps2_fifo_rd_en=ps2_fifo_rd_en,
            # Other
            o_kbd_overlay_pulse=self.control.ev.kbd_overlay.trigger,
            o_kbd_reset_pulse=self.control.ev.kbd_reset_req.trigger,
            o_kbd_tape_play_pulse=self.control.ev.kbd_tape_play.trigger,
        )

        gateware_dir = os.path.dirname(__file__)

        # Top-level and core C64 modules
        platform.add_source(os.path.join(gateware_dir, "c64_top.v"))
        platform.add_source(os.path.join(gateware_dir, "vicii_kawari.v"))
        platform.add_source(os.path.join(gateware_dir, "cpu6510.v"))
        platform.add_source(os.path.join(gateware_dir, "c64_bus_arbiter.v"))
        platform.add_source(os.path.join(gateware_dir, "c64_c1541.v"))
        platform.add_source(os.path.join(gateware_dir, "c64_keyboard.v"))
        platform.add_source(os.path.join(gateware_dir, "c64_ram.v"))
        platform.add_source(os.path.join(gateware_dir, "c64_redip_cia.v"))
        platform.add_source(os.path.join(gateware_dir, "c64_redip_sid.v"))
        platform.add_source(os.path.join(gateware_dir, "c64_tape.v"))
        platform.add_source(os.path.join(gateware_dir, "c64_action_replay.v"))
        platform.add_source(os.path.join(gateware_dir, "usb_hid_host_dual.v"))

        # CDC primitives
        platform.add_source_dir(os.path.join(gateware_dir, "cdc"))

        # Utility (reset sync etc.)
        platform.add_source_dir(os.path.join(gateware_dir, "util"))

        # USB HID host
        platform.add_source_dir(os.path.join(gateware_dir, "usb_hid_host", "rtl"))
        platform.add_source_dir(os.path.join(gateware_dir, "usb_hid_host", "rom"))

        # HDMI / TMDS encoder
        platform.add_source_dir(os.path.join(gateware_dir, "hdmi"))

        # vicii-kawari HDL core
        vicii_kawari_hdl_dir = os.path.join(gateware_dir, "vicii-kawari", "hdl")
        platform.add_source(os.path.join(vicii_kawari_hdl_dir, "videoram.v"))
        platform.add_source(os.path.join(vicii_kawari_hdl_dir, "serration.v"))
        platform.add_source(os.path.join(vicii_kawari_hdl_dir, "lumareg.v"))
        platform.add_source(os.path.join(vicii_kawari_hdl_dir, "equalization.v"))
        platform.add_source(os.path.join(vicii_kawari_hdl_dir, "divide.v"))
        platform.add_source(os.path.join(vicii_kawari_hdl_dir, "colorreg.v"))
        platform.add_source(os.path.join(vicii_kawari_hdl_dir, "sprites.v"))
        platform.add_source(os.path.join(vicii_kawari_hdl_dir, "registers_scaled.v"))
        platform.add_source(os.path.join(vicii_kawari_hdl_dir, "raster.v"))
        platform.add_source(os.path.join(vicii_kawari_hdl_dir, "pixel_sequencer.v"))
        platform.add_source(os.path.join(vicii_kawari_hdl_dir, "matrix.v"))
        platform.add_source(os.path.join(vicii_kawari_hdl_dir, "lightpen.v"))
        platform.add_source(os.path.join(vicii_kawari_hdl_dir, "hires_dvi_sync_scaled.v"))
        platform.add_source(os.path.join(vicii_kawari_hdl_dir, "hires_pixel_sequencer.v"))
        platform.add_source(os.path.join(vicii_kawari_hdl_dir, "hires_matrix.v"))
        platform.add_source(os.path.join(vicii_kawari_hdl_dir, "hires_addressgen.v"))
        platform.add_source(os.path.join(vicii_kawari_hdl_dir, "cycles.v"))
        platform.add_source(os.path.join(vicii_kawari_hdl_dir, "comp_sync.v"))
        platform.add_source(os.path.join(vicii_kawari_hdl_dir, "bus_access.v"))
        platform.add_source(os.path.join(vicii_kawari_hdl_dir, "border.v"))
        platform.add_source(os.path.join(vicii_kawari_hdl_dir, "addressgen_spartan.v"))
        platform.add_source(os.path.join(vicii_kawari_hdl_dir, "vicii.v"))
        platform.add_source(os.path.join(vicii_kawari_hdl_dir, "common.vh"))

        # reDIP-CIA core
        redip_cia_hdl_dir = os.path.join(gateware_dir, "c64_redip_cia", "reDIP-CIA", "gateware")
        platform.add_source(os.path.join(redip_cia_hdl_dir, "cia_pkg.sv"))
        platform.add_source(os.path.join(redip_cia_hdl_dir, "cia_edgedet.sv"))
        platform.add_source(os.path.join(redip_cia_hdl_dir, "cia_ports.sv"))
        platform.add_source(os.path.join(redip_cia_hdl_dir, "cia_timer.sv"))
        platform.add_source(os.path.join(redip_cia_hdl_dir, "cia_tod.sv"))
        platform.add_source(os.path.join(redip_cia_hdl_dir, "cia_serial.sv"))
        platform.add_source(os.path.join(redip_cia_hdl_dir, "cia_interrupt.sv"))
        platform.add_source(os.path.join(redip_cia_hdl_dir, "cia_control.sv"))
        platform.add_source(os.path.join(redip_cia_hdl_dir, "bcd_add.sv"))
        platform.add_source(os.path.join(redip_cia_hdl_dir, "bcd_update.sv"))
        platform.add_source(os.path.join(gateware_dir, "c64_redip_cia", "cia_core.sv"))

        # reDIP-SID core
        redip_sid_hdl_dir = os.path.join(gateware_dir, "c64_redip_sid", "reDIP-SID", "gateware")
        platform.add_source(os.path.join(redip_sid_hdl_dir, "sid_pkg.sv"))
        platform.add_source(os.path.join(redip_sid_hdl_dir, "sid_control.sv"))
        platform.add_source(os.path.join(redip_sid_hdl_dir, "sid_dac.sv"))
        platform.add_source(os.path.join(redip_sid_hdl_dir, "sid_envelope.sv"))
        platform.add_source(os.path.join(redip_sid_hdl_dir, "sid_filter.sv"))
        platform.add_source(os.path.join(redip_sid_hdl_dir, "sid_pot.sv"))
        platform.add_source(os.path.join(redip_sid_hdl_dir, "sid_voice.sv"))
        platform.add_source(os.path.join(redip_sid_hdl_dir, "sid_waveform.sv"))
        platform.add_source(os.path.join(gateware_dir, "c64_redip_sid", "sid_api.sv"))
        platform.add_source(os.path.join(gateware_dir, "c64_redip_sid", "muladd.sv"))
        platform.add_source(os.path.join(gateware_dir, "c64_redip_sid", "dc_blocker.v"))

        # reDIP-SID core
        redip_sid_hdl_dir = os.path.join(gateware_dir, "c64_redip_sid", "reDIP-SID", "gateware")
        platform.add_source(os.path.join(redip_sid_hdl_dir, "sid_pkg.sv"))
        platform.add_source(os.path.join(redip_sid_hdl_dir, "sid_control.sv"))
        platform.add_source(os.path.join(redip_sid_hdl_dir, "sid_dac.sv"))
        platform.add_source(os.path.join(redip_sid_hdl_dir, "sid_envelope.sv"))
        platform.add_source(os.path.join(redip_sid_hdl_dir, "sid_filter.sv"))
        platform.add_source(os.path.join(redip_sid_hdl_dir, "sid_pot.sv"))
        platform.add_source(os.path.join(redip_sid_hdl_dir, "sid_voice.sv"))
        platform.add_source(os.path.join(redip_sid_hdl_dir, "sid_waveform.sv"))
        platform.add_source(os.path.join(gateware_dir, "c64_redip_sid", "muladd.sv"))
        platform.add_source(os.path.join(gateware_dir, "c64_redip_sid", "sid_api.sv"))

        # 1541 drive core
        c1541_hdl_dir = os.path.join(gateware_dir, "c64_c1541")
        platform.add_source(os.path.join(c1541_hdl_dir, "c1541_drv.v"))
        platform.add_source(os.path.join(c1541_hdl_dir, "c1541_gcr.v"))
        platform.add_source(os.path.join(c1541_hdl_dir, "c1541_logic.v"))
        platform.add_source(os.path.join(c1541_hdl_dir, "c1541_track.v"))
        platform.add_source(os.path.join(c1541_hdl_dir, "iecdrv_ram.v"))
        platform.add_source(os.path.join(c1541_hdl_dir, "iecdrv_rom.v"))

        # Action Replay cartridge core
        action_replay_hdl_dir = os.path.join(gateware_dir, "c64_action_replay")
        platform.add_source(os.path.join(action_replay_hdl_dir, "c64_action_replay_pla.v"))

        # 6502 CPU (VHDL -> Verilog)
        cpu6502_dir = os.path.join(gateware_dir, "6502n")
        cpu6502 = VHD2VConverter(
            platform,
            name="proc_core",
            sources=[
                os.path.join(cpu6502_dir, "alu.vhd"),
                os.path.join(cpu6502_dir, "bit_cpx_cpy.vhd"),
                os.path.join(cpu6502_dir, "data_oper.vhd"),
                os.path.join(cpu6502_dir, "implied.vhd"),
                os.path.join(cpu6502_dir, "pkg_6502_decode.vhd"),
                os.path.join(cpu6502_dir, "pkg_6502_defs.vhd"),
                os.path.join(cpu6502_dir, "pkg_6502_opcodes.vhd"),
                os.path.join(cpu6502_dir, "proc_control.vhd"),
                os.path.join(cpu6502_dir, "proc_core.vhd"),
                os.path.join(cpu6502_dir, "proc_interrupt.vhd"),
                os.path.join(cpu6502_dir, "proc_registers.vhd"),
                os.path.join(cpu6502_dir, "shifter.vhd"),
            ],
        )
        cpu6502._ghdl_opts.append("-fsynopsys")
        self.submodules.cpu6502 = cpu6502

        # T65 CPU (VHDL -> Verilog, fallback)
        t65_dir = os.path.join(gateware_dir, "T65")
        t65 = VHD2VConverter(
            platform,
            name="T65",
            sources=[
                os.path.join(t65_dir, "T65_ALU.vhd"),
                os.path.join(t65_dir, "T65_MCode.vhd"),
                os.path.join(t65_dir, "T65_Pack.vhd"),
                os.path.join(t65_dir, "T65.vhd"),
            ],
        )
        t65._ghdl_opts.append("-fsynopsys")
        self.submodules.t65 = t65

        # VIA6522 (VHDL -> Verilog)
        iecdrv_via6522_dir = os.path.join(gateware_dir, "c64_c1541")
        iecdrv_via6522 = VHD2VConverter(
            platform,
            name="iecdrv_via6522",
            sources=[
                os.path.join(iecdrv_via6522_dir, "iecdrv_via6522.vhd"),
            ],
        )
        iecdrv_via6522._ghdl_opts.append("-fsynopsys")
        self.submodules.iecdrv_via6522 = iecdrv_via6522
