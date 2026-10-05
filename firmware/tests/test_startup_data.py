"""Exercise the real linker script with SRAM code sizes that require padding."""
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


@unittest.skipUnless(shutil.which('riscv64-unknown-elf-as'), 'RISC-V binutils required')
class StartupDataTest(unittest.TestCase):
    def test_rom_copy_preserves_initialized_data(self):
        linker = Path(__file__).resolve().parents[1] / 'linker.ld'
        for sram_code_size in (4, 8, 12):
            with self.subTest(sram_code_size=sram_code_size), tempfile.TemporaryDirectory() as tmp:
                work = Path(tmp)
                generated = work / 'generated'
                generated.mkdir()
                (generated / 'output_format.ld').write_text('OUTPUT_FORMAT("elf32-littleriscv")\n')
                (generated / 'regions.ld').write_text('''MEMORY {
                    main_ram : ORIGIN = 0x40000000, LENGTH = 0x1000000
                    sram : ORIGIN = 0x10000000, LENGTH = 0x2000
                    drive_shmem : ORIGIN = 0x50000000, LENGTH = 0x2000
                }''')
                # Referencing source symbols makes ld emit their PROVIDEs.
                (work / 'startup.S').write_text(f'''
                    .section .text
                    .global _start
                _start:
                    .word _fdata_rom, _ftext_sram_rom
                    .section .sramfunc,"ax"
                    .space {sram_code_size}, 0x5a
                    .section .data
                    .global console_state
                console_state:
                    .byte 0, 0, 3, 0
                    .word 0x12345678, 0x87654321, 0
                ''')
                def run(tool, *args):
                    return subprocess.run(['riscv64-unknown-elf-' + tool, *args],
                                          cwd=work, check=True, capture_output=True, text=True).stdout
                run('as', '-march=rv32i', '-mabi=ilp32', '-o', 'startup.o', 'startup.S')
                run('ld', '-m', 'elf32lriscv', '-T', str(linker), '-o', 'startup.elf', 'startup.o')
                symbols = {name: int(address, 16) for address, kind, name in
                           (line.split() for line in run('nm', 'startup.elf').splitlines())}
                run('objcopy', '-O', 'binary', 'startup.elf', 'startup.bin')
                image = (work / 'startup.bin').read_bytes()
                source = symbols['_fdata_rom'] - 0x40000000
                length = symbols['_edata'] - symbols['_fdata']
                offset = symbols['console_state'] - symbols['_fdata']
                # Model crt0's copy loop, then inspect the FILE flags/callbacks.
                initialized = image[source:source + length]
                self.assertEqual(initialized[offset:offset + 16],
                                 bytes.fromhex('00000300 78563412 21436587 00000000'))
                source = symbols['_ftext_sram_rom'] - 0x40000000
                self.assertEqual(image[source:source + sram_code_size], b'\x5a' * sram_code_size)
