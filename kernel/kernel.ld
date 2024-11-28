OUTPUT_ARCH("riscv")

SECTIONS {
	. = 0x80400000;

	PROVIDE(linker_text = .);
	.text : {
		*(.text.entry)
		*(.text .text.*)
	}

	. = ALIGN(4096);

	PROVIDE(linker_rodata = .);
	.rodata : {
		*(.srodata .srodata.*)
		*(.rodata .rodata.*)
	}

	. = ALIGN(4096);

	PROVIDE(linker_data = .);
	.data : {
		*(.sdata .sdata.*)
		*(.data .data.*)
	}

	PROVIDE(linker_bss = .);
	.bss : {
		*(.sbss .sbss.*)
		*(.bss .bss.*)
	}

	. = ALIGN(4096);

	PROVIDE(linker_plic = .);
	.plic : {
		.plic
	}

	. = ALIGN(4096);

	PROVIDE(linker_end = .);
}
