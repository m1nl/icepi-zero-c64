# Repository Guidelines

## Project Structure & Module Organization

- `boards/platforms/` defines FPGA pins and electrical constraints; `boards/targets/icepi_zero.py` assembles the LiteX SoC.
- `gateware/` contains Verilog/SystemVerilog cores and Python Migen/LiteX wrappers. The SPI report receiver lives in `gateware/spi_report/`, with its wrapper in `gateware/spi_report.py`.
- `firmware/` contains C firmware, startup assembly, the linker script, and host-side regression tests in `firmware/tests/`.
- `doc/`, `c64_roms/`, and `ter-u16b.bdf` provide documentation, ROM assets, and the terminal font. `build/` holds generated outputs; `litex_src/` and `venv/` support the local toolchain.
- Several gateware cores are Git submodules. Initialize them with `git submodule update --init --recursive`; keep upstream changes separate from project changes.

## Build, Test, and Development Commands

Run commands from the repository root:

```sh
venv/bin/python -m boards.targets.icepi_zero --build
make -C firmware BUILD_DIR=../build/icepi_zero/
venv/bin/python -m unittest discover -s gateware/spi_report/tests -v
python3 -m unittest discover -s firmware/tests -v
```

These build the ECP5 bitstream, build firmware using generated SoC headers, and run gateware and firmware regressions. Gateware checks require Yosys and Icarus Verilog; startup tests require RISC-V binutils. Additional core testbenches use Cocotb and their local Makefiles.

The project also supports the [MiSTle IcePi carrier board](https://github.com/MiSTle-Dev/Boards/tree/main/icepi_carrier), which offers broader USB compatibility through FPGA Companion. Add `--with-external-leds` and/or `--with-joysticks` for its optional interfaces. SPI debug defaults off; enable it with `SPI_HID_DEBUG=1` and force firmware recompilation.

## Coding Style & Naming Conventions

Follow nearby code: four spaces in Python and C, two spaces in Verilog. Use descriptive snake_case names for signals/functions and uppercase names for constants and parameters. Preserve module interfaces and clock-domain boundaries. No repository-wide formatter configuration is provided; run `git diff --check` before submitting.

## Testing Guidelines

Name Python regression files `test_*.py` and methods `test_*`. Add focused coverage for protocol, interrupt, pin-mapping, or memory-layout changes. No numeric coverage threshold is defined. Validate LUTRAM inference and pin conflicts when changing hardware interfaces; report simulation and physical-board results separately.

## Commit & Pull Request Guidelines

History uses short imperative subjects, such as `update signal type`; no Conventional Commits requirement is evident. Keep commits focused. Describe the problem, resulting behavior, relevant issues, and validation in each PR. Include screenshots for visible display changes and identify required firmware/bitstream rebuilds.

## SID Optimization Context

- Both generic SID multipliers already infer ECP5 DSPs. Account for this when evaluating further DSP optimizations.
- A reverted experiment moved operand registers into explicit DSP input registers. It preserved cycle timing and passed simulation and routed timing, but saved only 6 LUTs (22,677 to 22,671) and 54 fabric flip-flops; DSP usage remained at 13.
- Treat these figures as a single-seed result, not a guaranteed improvement. The experiment offered no meaningful benefit for the project's LUT-focused optimization; require new evidence before reintroducing it.

## MiSTle IcePi Carrier Interface Requirements

- Enable optional carrier interfaces with `--with-external-leds` and/or `--with-joysticks` on the gateware build command. Both default to disabled and can be enabled independently.
- Preserve the external LED mapping: green on GPIO13 indicates C64 running, yellow on GPIO14 indicates 1541 activity, and red on GPIO15 indicates CPU pause / REU DMA.
- Drive carrier LEDs directly from these status signals as active-high outputs, with the carrier board's pull-down configuration. Apply PWM dimming only to the five onboard LEDs.
- Configure both GPIO joystick ports as active-low inputs with internal pull-ups. Preserve this contact order and pin mapping:

  | Contact | Port A | Port B |
  | --- | --- | --- |
  | Up | GPIO2 | GPIO8 |
  | Down | GPIO1 | GPIO7 |
  | Left | GPIO4 | GPIO10 |
  | Right | GPIO3 | GPIO9 |
  | Fire | GPIO0 | GPIO6 |
  | Second fire | GPIO5 | GPIO11 |

- The carrier board numbers bits as `RLDUABXY`. Preserve the platform's reordering of the six wired contacts to `UDLRAB` to match USB gamepads.
- Synchronize GPIO inputs and combine them with USB gamepads and both FPGA Companion SPI joystick states through the existing joystick routing and swap setting.
- Preserve FPGA Companion support for `ABXY` and Select/Start. Companion joysticks must work without enabling the GPIO joystick ports; tie absent GPIO ports to their inactive state.
- Enabling either carrier interface must release the overlapping legacy debug header. Do not request the alternate `gpio` resource alongside these interfaces because it shares expansion pins.
