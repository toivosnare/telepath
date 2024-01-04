.section .text.entry
.global entry
entry:
	auipc a0, 0
	la sp, stack_physical_end
	j main

.section .bss
stack_physical_start:
	.space 16384
stack_physical_end:
