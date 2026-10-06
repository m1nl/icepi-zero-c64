INCLUDE generated/output_format.ld
ENTRY(_start)

__DYNAMIC = 0;

INCLUDE generated/regions.ld

SECTIONS
{
	.text :
	{
		_ftext = .;
		/* Make sure crt0 files come first, and they, and the isr */
		/* don't get disposed of by greedy optimisation */
		*crt0*(.text)
		KEEP(*crt0*(.text))
		KEEP(*(.text.isr))

		*(.text .stub .text.* .gnu.linkonce.t.*)
		. = ALIGN(4);
		_etext = .;
	} > main_ram

	.text_sram : ALIGN(4)
	{
		. = ALIGN(4);
		_ftext_sram = .;
		KEEP(*(.sramfunc))
		. = ALIGN(4);
		_etext_sram = .;
	} > sram AT > main_ram

	.rodata :
	{
		. = ALIGN(8);
		_frodata = .;
		*(.rodata .rodata.* .gnu.linkonce.r.*)
		*(.rodata1)
		*(.got .got.*)
		*(.toc .toc.*)
		. = ALIGN(8);
		_erodata = .;
	} > main_ram

	/* Align the section itself so its ROM image starts at _fdata too.
	 * Aligning only inside the section can leave leading padding in the
	 * ROM image, shifting initialized data (including stdout) at startup. */
	.data : ALIGN(8)
	{
		. = ALIGN(8);
		_fdata = .;
		*(.data .data.* .gnu.linkonce.d.*)
		*(.data1)
		_gp = ALIGN(16);
		*(.sdata .sdata.* .gnu.linkonce.s.*)
		. = ALIGN(8);
		_edata = .;
	} > sram AT > main_ram

	.bss :
	{
		. = ALIGN(8);
		_fbss = .;
		*(.dynsbss)
		*(.sbss .sbss.* .gnu.linkonce.sb.*)
		*(.scommon)
		*(.dynbss)
		*(.bss .bss.* .gnu.linkonce.b.*)
		*(COMMON)
		. = ALIGN(8);
		_ebss = .;
		_end = .;
	} > sram
}

_heap_base = _ftext + 100K;
_heap_end  = _ftext + 8M;

PROVIDE(_fstack = ORIGIN(sram) + LENGTH(sram));

PROVIDE(_ftext_sram_rom = LOADADDR(.text_sram) + (_ftext_sram - ADDR(.text_sram)));
PROVIDE(_etext_sram_rom = _ftext_sram_rom + (_etext_sram - _ftext_sram));

PROVIDE(_fdata_rom = LOADADDR(.data) + (_fdata - ADDR(.data)));
PROVIDE(_edata_rom = _fdata_rom + (_edata - _fdata));

PROVIDE(_fheap = _heap_base);
PROVIDE(_eheap = _heap_end);

PROVIDE(_fdrive_shmem = ORIGIN(drive_shmem));
PROVIDE(_edrive_shmem = ORIGIN(drive_shmem) + LENGTH(drive_shmem));
