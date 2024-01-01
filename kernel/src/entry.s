.section .text.entry
.global entry
entry:
	la t0, fdt_address
	sd a1, 0(t0)
	la sp, stack_end
	j main

.section .bss
.global fdt_address
fdt_address:
	.dword
stack_start:
	.space 16384
stack_end:
