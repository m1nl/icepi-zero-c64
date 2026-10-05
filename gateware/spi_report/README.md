# Receive-only SPI report peripheral

`report_slave.v` and `gateware/spi_report.py` implement the LiteX peripheral
instantiated as `spi_report` in the Icepi Zero target.

- SPI mode 1, MSB first, with an active-low CS. Reception runs directly on the
  falling edge of SPI SCK. SCK directly clocks the receive registers in both
  hardware and simulation. Completed bytes cross into the system clock domain
  without a combinational feedback clock filter.
- The first byte must be `0x01`; every complete byte of an accepted transaction,
  **including that target byte**, is recorded. Other targets are ignored until
  CS rises. A partial final byte is discarded. Complete preceding bytes remain.
- Completed bytes cross into the system clock domain using a toggle and a stable
  byte mailbox. Allow at least four system-clock periods between completed
  bytes, including across consecutive transactions. CS must be asserted before
  the first sampling edge and deasserted after the last sampling edge.
- Eight bytes of distributed RAM use synchronous writes and exactly one
  asynchronous eight-bit read port. Circular write and read pointers advance
  modulo eight. A full write overwrites the oldest unread byte and advances the
  read pointer; a simultaneous read makes room without an overrun. A four-bit
  occupancy count distinguishes full from empty even when pointers coincide.
  There is no additional FIFO, report decoding, or transmit interface.

The uncached Wishbone window is `0xb0000000` through `0xb000000f`. Data accesses
at offsets `0x00` through `0x07` all read the same FIFO head, regardless of byte
address. Each read with nonzero byte select consumes **one byte**, including
32-bit reads. Word reads return that byte with 24 zero bits; byte reads place it
in the requested Wishbone byte lane. Empty reads return zero without advancing
the pointer. Writes are acknowledged but ignored. The response is captured on
the same clock edge as the pop, so it remains stable during ACK even if SPI
records another byte. RAM contents themselves are not reset or erased.

Two read-only metadata words support packet parsing and overrun recovery:

| Offset | Contents |
| --- | --- |
| `0x00`–`0x07` | Aliases for the next FIFO byte; a read consumes one byte |
| `0x08` | Total recorded bytes, modulo 2^32 |
| `0x0c` | Bit 0: FIFO head starts a packet; bits 4:1: occupancy (0–8); bits 31:5: overwrite count, modulo 2^27 |

Metadata reads do not consume bytes. A slot's start marker is updated on every
write and selected using the read pointer, so a payload byte of `0x01` cannot
be mistaken for a new packet. Firmware checks the overwrite count before and
after each data read to detect a head change between metadata and data access.

Firmware uses repeated aligned volatile 32-bit reads at offset zero and takes
bits 7:0 of each response. VexRiscv Lite drives `SEL=1111` for all reads, including
byte loads, and then extracts the addressed byte lane inside the CPU. A byte
load at offset 1, 2, or 3 therefore extracts zero from our zero-extended response.
Masters that select the byte lane explicitly can use byte loads. Ordinary libc
`memcpy` is unsuitable for this consuming MMIO window.

The only CSR is `spi_report_status`: bit 0 indicates unread bytes (the requested
“fifo not empty” flag), and bit 1 indicates CS active or a completed byte still
crossing into the system domain. IRQ is asserted when the first accepted byte
is recorded and remains asserted until all queued bytes have been read; further
writes assert it again. The LiteX-generated `SPI_REPORT_INTERRUPT` constant
identifies its CPU interrupt. No event pending/enable CSRs are added.

Header wiring: CS = GPIO18/N4, SCK = GPIO24/L1, MOSI = GPIO25/J2.
MISO = GPIO21/F2 and IRQN = GPIO22/P2 are declared and reserved, but left
unconnected to the receive-only module. The IRQ described above is the SoC's
internal CPU interrupt, not the header IRQN signal.

The [MiSTle IcePi carrier board](https://github.com/MiSTle-Dev/Boards/tree/main/icepi_carrier)
offers broader USB compatibility with IcePi-Zero through its FPGA Companion.
Its SPI wiring uses `PULLMODE=UP` on all five pins:

| Signal | GPIO | FPGA site | Header pin |
| --- | --- | --- | --- |
| CS | 18 | N4 | 12 |
| SCK | 24 | L1 | 18 |
| MOSI | 25 | J2 | 22 |
| MISO | 21 | F2 | 40 |
| IRQN | 22 | P2 | 15 |

Header pins and GPIO numbers are separate numbering schemes.

IEC data uses GPIO20/F1, clock uses GPIO16/H3, and ATN uses GPIO12/J3.
The system I2C peripheral and GPIO2/GPIO3 pin resource
are commented out for now.

`firmware/spi_hid.c` drains the ring on `SPI_REPORT_INTERRUPT`. The companion's
keyboard format from `src/ps2helper.c` is `01 01 legacy-event full-HID-usage`,
followed by an already translated PS/2 Set-2 sequence. Firmware strips the four
header bytes and queues complete key events for foreground processing.
With the overlay closed, regular keys and modifiers go to the existing C64
PS/2 interface. With the overlay open, HID usages go through the same console
input processing as USB HID, including shifted text, arrows, function keys,
and control shortcuts. Releases for keys pressed before opening the overlay
still reach the C64, preventing stuck keys.

Print Screen toggles the overlay and Pause/Break resets the C64 CPU through
the existing reset handler. These hotkeys work in either overlay state and
ignore repeated make events until release; Pause's header-only release rearms
it. Mouse and status reports are consumed without forwarding to
the keyboard-only PS/2 input.

Joystick reports are seven bytes: `01 03 port RLDUABXY analog-X analog-Y extra`.
Ports 0 and 1 update `c64_control_companion_joy_a` and
`c64_control_companion_joy_b`; other ports and incomplete/oversized reports
are discarded. Each 10-bit CSR holds active-high state in LSB-first order
`UDLRABXY`, Select, Start. Firmware reverses the four direction bits, retains
ABXY, and maps extra-button bits 2/3 to Select/Start. Analog axes and the
remaining extra buttons are ignored; the companion already translates axis
movement into digital directions.

Complete joystick reports update the CSRs immediately from the parser, without
entering the keyboard queue or waiting for PS/2 pacing. Neutral reports clear
the state; initialization clears both CSRs. Gateware combines each state with
the corresponding native USB gamepad and active-low external joystick contacts
before the existing keyboard joystick emulation, port swap, and gamepad hotkey
logic. Releasing one source leaves buttons held by another source asserted.
Companion joystick support works whether or not external GPIO ports are enabled.

The foreground sends whole sequences and spaces byte writes by 9 ms to match
the C64 keyboard's 120 Hz byte consumption. Interrupts remain enabled during
these waits. Foreground also finishes reports whose CS rose after their last
byte interrupt. A software queue holds up to 31 complete PS/2 sequences.

The hardware ring remains eight bytes: IRQs must drain it before the producer
overwrites unread bytes, including during 10-byte Print Screen break and
12-byte Pause packets. Overwritten, truncated, and excessive packets are
discarded, and reception resumes at a marked packet start. A full software
queue drops whole sequences. This interface has no flow control.

Rebuild the gateware and firmware together: firmware now needs the metadata
words as well as the SPI CSR and interrupt definitions in generated headers.
The firmware's power command reports I2C disabled when built for this target.

Serial debugging is disabled by default. With `SPI_HID_DEBUG=1`, startup prints the
SPI base address, CPU interrupt number, mode, and pin assignments. The foreground
prints complete raw reports before filtering them for PS/2 forwarding, including
mouse, joystick, unsupported, and malformed keyboard reports. Example:

```text
[spi] report len=5: 01 01 04 04 1c
[spi] report len=6: 01 01 84 04 f0 1c
[spi] status=00 bytes=11 level=0 overruns=0 irq=2 dropped=0 log_lost=0 mask=0000000f pending=00000000
```

With the target's uptime timer, a status line prints once per second even when
no reports arrive. `bytes` is the hardware's accepted-byte counter, `irq` counts
actual SPI IRQ handler calls (foreground polling does not increment it), and
`level` is the remaining hardware occupancy. `overruns` counts overwritten
hardware bytes; `dropped` counts discarded report/queue events. `log_lost` counts
debug records discarded when their separate seven-record queue fills. Printing
never runs in the IRQ handler. Partial reports interrupted by overwrites or
excessive length are labeled `partial/overrun` or `oversize`.

If `bytes` stays zero, no complete target-`0x01` bytes are being accepted. If
`bytes` increases while `irq` stays zero, foreground polling is receiving data
but the interrupt path needs attention. Overruns mean firmware did not consume
bytes before the eight-byte buffer filled. The firmware build tests cover debug
enabled and disabled; enable it and force recompilation with:

```sh
make -B -C firmware BUILD_DIR=../build/icepi_zero/ SPI_HID_DEBUG=1
```

Run the integration simulation with:

```sh
venv/bin/python -m unittest discover -s gateware/spi_report/tests -v
python3 -m unittest discover -s firmware/tests -v
```

Check hardware synthesis and distributed-RAM inference with:

```sh
yosys -p 'read_verilog gateware/spi_report/report_slave.v; synth_ecp5 -top spi_report_slave; stat'
```
