# icepi-zero-c64

A complete C64 implementation for the IcePi-Zero FPGA board, featuring HDMI video output, dual USB HID input support, and 1541 floppy drive emulation.

This project integrates several open-source FPGA cores to reproduce functionality of the original C64 hardware:

- 6510 CPU - https://github.com/GideonZ/1541ultimate/tree/master/fpga/6502n/vhdl_source
- VIC-II graphics chip - https://github.com/randyrossi/vicii-kawari
- SID 6581 / 8580 sound chip - https://github.com/daglem/reDIP-SID
- CIA 6526 / 8521 I/O chips - https://github.com/daglem/reDIP-CIA

In addition, the system runs a LiteX SoC with a VexRiscv soft-core CPU to handle system services such as SD card access and ROM loading - https://github.com/enjoy-digital/litex

Hardware used - [IcePi-Zero](https://github.com/cheyao/icepi-zero) FPGA board (Lattice ECP5U-25F with 256Mbit SDRAM)

[Watch popular C64 demos](https://youtube.com/playlist?list=PLx57TRDm5jOb3XmBs3nD0p_45FGw70Ht1&si=9r16wObv-iXTmFdy) recorded via HDMI grabber connected directly to the board!

![IcePi-Zero board](doc/board.jpeg)

## Building

### Prerequisites

Install the following tools:
- GHDL
- Yosys
- Project Trellis
- nextpnr (with ECP5 support)
- Python 3.8+
- openFPGALoader

### Setup Build Environment

```bash
# Clone repository with submodules
git clone --recursive https://github.com/m1nl/icepi-zero-c64
cd icepi-zero-c64

# Initialize git submodules
git submodule update --init

# Create Python virtual environment
python3 -m venv venv
source venv/bin/activate

# Install LiteX
mkdir litex_src
cd litex_src
wget https://raw.githubusercontent.com/enjoy-digital/litex/master/litex_setup.py
chmod +x litex_setup.py
./litex_setup.py --init --install
cd ..
```

### Build Gateware and Firmware

```bash
# Build FPGA bitstream
python3 -m boards.targets.icepi_zero --build

# Build firmware
make -C firmware BUILD_DIR=../build/icepi_zero/
```

## Installation

### Flash FPGA

```bash
# Flash bitstream to SPI flash
openFPGALoader -b icepi-zero --write-flash build/icepi_zero/gateware/icepi_zero.bit

# Flash BIOS to SPI flash at offset 0x200000
openFPGALoader -b icepi-zero --write-flash --offset 0x200000 build/icepi_zero/software/bios/bios.bin
```

### Download ROMs
```bash
# Change to c64_roms directory
cd c64_roms

# Download ROMs
./get_stock.sh
```

### Prepare SD Card

1. Format SD card as FAT32
2. Copy `firmware/boot.json` to SD card root
3. Copy `firmware/icepi-zero-c64.bin` to SD card root
4. Create a `c64_roms` directory on the SD card
5. Copy contents of `c64_roms/dist/*` to `c64_roms` on the SD card
