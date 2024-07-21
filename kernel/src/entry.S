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
; .global returnToUserspace
; returnToUserspace:
; 	csrw sscratch, a0
; 	sfence.vma
; 	csrw satp, a1
; 	sfence.vma
; 	# csrrc sstatus, 256
; 	ld t0, 0(a2)
; 	csrw sepc, t0
; 	ld ra, 8(a2)
; 	ld sp, 16(a2)
; 	ld gp, 24(a2)
; 	ld tp, 32(a2)
; 	ld t0, 40(a2)
; 	ld t1, 48(a2)
; 	ld t2, 56(a2)
; 	ld s0, 64(a2)
; 	ld s1, 72(a2)
; 	ld a0, 80(a2)
; 	ld a1, 88(a2)
; 	ld a3, 104(a2)
; 	ld a4, 112(a2)
; 	ld a5, 120(a2)
; 	ld a6, 128(a2)
; 	ld a7, 136(a2)
; 	ld s2, 144(a2)
; 	ld s3, 152(a2)
; 	ld s4, 160(a2)
; 	ld s5, 168(a2)
; 	ld s6, 176(a2)
; 	ld s7, 184(a2)
; 	ld s8, 192(a2)
; 	ld s9, 200(a2)
; 	ld s10, 208(a2)
; 	ld s11, 216(a2)
; 	ld t3, 224(a2)
; 	ld t4, 232(a2)
; 	ld t5, 240(a2)
; 	ld t6, 248(a2)
; 	ld a2, 96(a2)
; 	sret


