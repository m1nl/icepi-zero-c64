import struct
import sys
from pathlib import Path

inp = sys.argv[1]
outp = sys.argv[2]

data = Path(inp).read_bytes()

# --- verify CRT header ---
if data[0:16] != b"C64 CARTRIDGE   ":
    print("Not a valid CRT file")
    sys.exit(1)

i = 0x40  # CRT header size
rom_all = bytearray()
bank_id = 0


def read_u32(b, off):
    return struct.unpack(">I", b[off : off + 4])[0]


def read_u16(b, off):
    return struct.unpack(">H", b[off : off + 2])[0]


while i < len(data):
    if data[i : i + 4] != b"CHIP":
        break

    chip_size = read_u32(data, i + 0x4)
    chip_type = read_u16(data, i + 0x8)

    if chip_type != 0:
        i += chip_size
        continue

    # CHIP header layout:
    # 0x00: "CHIP"
    # 0x04: size
    # 0x08: chip type (ROM/RAM)
    # 0x0C: bank number
    # 0x0E: load address
    # 0x10: data...

    bank = read_u16(data, i + 0xA)
    load_addr = read_u16(data, i + 0xC)
    size = read_u16(data, i + 0xE)
    payload = data[i + 0x10 : i + 0x10 + size]
    # --- Action Replay specifics ---
    # AR cartridges use ROML ($8000) or ROMH ($A000)
    if load_addr in (0x8000, 0xA000):
        print(f"[OK] Bank {bank} ({len(payload)} bytes)")
        rom_all += payload

    else:
        print(f"[SKIP] Non-ROM chip at bank {bank}, addr={hex(load_addr)}")

    i += chip_size


# write full combined ROM
Path(outp).write_bytes(rom_all)
print("\nDONE")
print(f"Total ROM size: {len(rom_all)} bytes")
