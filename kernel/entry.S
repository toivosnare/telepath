#include "entry_defines.h"

.section .text.entry
.global bootHartEntry
bootHartEntry:
	auipc a2, 0
	la sp, kernel_stack
	li t0, KERNEL_STACK_SIZE_PER_HART
	add sp, sp, t0
	j bootHartMain

.section .text
.global secondaryHartEntry
secondaryHartEntry:
	la sp, kernel_stack
	li t0, KERNEL_STACK_SIZE_PER_HART
	mul t0, t0, a1
	add sp, sp, t0
	j secondaryHartMain

.global trampoline
.align 12
trampoline:
	csrw satp, a0
	sfence.vma
	la sp, kernel_stack
	li t0, KERNEL_STACK_SIZE_PER_HART
	addi a1, a1, 1
	mul t0, t0, a1
	add sp, sp, t0
	add sp, sp, a2
	la ra, main
	add ra, ra, a2
	jr ra

.global returnToUserspace
returnToUserspace:
	li t0, 256
	csrrc zero, sstatus, t0
	csrw sscratch, a0
	ld t0, 0(a1)
	csrrw zero, sepc, t0
	ld ra, 8(a1)
	ld sp, 16(a1)
	ld gp, 24(a1)
	ld tp, 32(a1)
	ld t0, 40(a1)
	ld t1, 48(a1)
	ld t2, 56(a1)
	ld s0, 64(a1)
	ld s1, 72(a1)
	ld a0, 80(a1)
	ld a2, 96(a1)
	ld a3, 104(a1)
	ld a4, 112(a1)
	ld a5, 120(a1)
	ld a6, 128(a1)
	ld a7, 136(a1)
	ld s2, 144(a1)
	ld s3, 152(a1)
	ld s4, 160(a1)
	ld s5, 168(a1)
	ld s6, 176(a1)
	ld s7, 184(a1)
	ld s8, 192(a1)
	ld s9, 200(a1)
	ld s10, 208(a1)
	ld s11, 216(a1)
	ld t3, 224(a1)
	ld t4, 232(a1)
	ld t5, 240(a1)
	ld t6, 248(a1)
	ld a1, 88(a1)
	sret

.global handleTrap
.align 2
handleTrap:
	csrr a0, scause
	csrr a1, stval
	la sp, kernel_stack
	li t0, KERNEL_STACK_SIZE_PER_HART
	add sp, sp, t0
	la t0, handleTrap2
	jr t0
