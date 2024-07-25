OUTPUT_ARCH("riscv")

SECTIONS {
	. = 0x80400000;
	PROVIDE(kernel_linker_start = .);

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

	PROVIDE(kernel_linker_end = .);
}
