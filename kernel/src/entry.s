.section .text.entry
.global entry
entry:
	la sp, stack_end
	j main

.section .bss
stack_start:
	.space 16384
stack_end:
