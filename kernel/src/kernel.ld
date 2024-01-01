OUTPUT_ARCH("riscv")
ENTRY(entry)

SECTIONS {
	. = 0x80400000;

	.text : {
		*(.text.entry)
		*(.text .text.*)
	}

	.rodata : {
		*(.srodata .srodata.*)
		*(.rodata .rodata.*)
	}

	.data : {
		*(.sdata .sdata.*)
		*(.data .data.*)
	}

	.bss : {
		*(.sbss .sbss.*)
		*(.bss .bss.*)
	}
}
