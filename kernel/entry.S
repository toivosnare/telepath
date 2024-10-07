#include "entry.h"

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
	mv a0, a1
	la sp, kernel_stack
	li t0, KERNEL_STACK_SIZE_PER_HART
	addi a1, a1, 1
	mul t0, t0, a1
	add sp, sp, t0
	j secondaryHartMain

.global trampoline
.align 12
trampoline:
	csrw satp, a1
	sfence.vma
	add sp, sp, a2
	la ra, main
	add ra, ra, a2
	jr ra

.global handleTrap
.align 2
handleTrap:
	csrrw a0, sscratch, a0
	beqz a0, handleTrap2
	sd ra, 8(a0)
	sd sp, 16(a0)
	sd gp, 24(a0)
	sd tp, 32(a0)
	sd t0, 40(a0)
	sd t1, 48(a0)
	sd t2, 56(a0)
	sd s0, 64(a0)
	sd s1, 72(a0)
	sd a1, 88(a0)
	sd a2, 96(a0)
	sd a3, 104(a0)
	sd a4, 112(a0)
	sd a5, 120(a0)
	sd a6, 128(a0)
	sd a7, 136(a0)
	sd s2, 144(a0)
	sd s3, 152(a0)
	sd s4, 160(a0)
	sd s5, 168(a0)
	sd s6, 176(a0)
	sd s7, 184(a0)
	sd s8, 192(a0)
	sd s9, 200(a0)
	sd s10, 208(a0)
	sd s11, 216(a0)
	sd t3, 224(a0)
	sd t4, 232(a0)
	sd t5, 240(a0)
	sd t6, 248(a0)
	csrr t0, sepc
	sd t0, 0(a0)
	csrr t0, sscratch
	sd t0, 80(a0)
	la sp, kernel_stack
	li t0, KERNEL_STACK_SIZE_PER_HART
	ld a1, 256(a0)
	addi t1, a1, 1
	mul t0, t0, t1
	add sp, sp, t0
	j handleTrap2

.global returnToUserspace
returnToUserspace:
	csrw sscratch, a0
	ld t0, 0(a0)
	csrw sepc, t0
	ld ra, 8(a0)
	ld sp, 16(a0)
	ld gp, 24(a0)
	ld tp, 32(a0)
	ld t0, 40(a0)
	ld t1, 48(a0)
	ld t2, 56(a0)
	ld s0, 64(a0)
	ld s1, 72(a0)
	ld a1, 88(a0)
	ld a2, 96(a0)
	ld a3, 104(a0)
	ld a4, 112(a0)
	ld a5, 120(a0)
	ld a6, 128(a0)
	ld a7, 136(a0)
	ld s2, 144(a0)
	ld s3, 152(a0)
	ld s4, 160(a0)
	ld s5, 168(a0)
	ld s6, 176(a0)
	ld s7, 184(a0)
	ld s8, 192(a0)
	ld s9, 200(a0)
	ld s10, 208(a0)
	ld s11, 216(a0)
	ld t3, 224(a0)
	ld t4, 232(a0)
	ld t5, 240(a0)
	ld t6, 248(a0)
	ld a0, 80(a0)
	sret

.global idle
idle:
	mv sp, a0
	mv a1, a1
	li t0, 0
	csrw sscratch, t0
	csrs sstatus, 2
1:
	wfi
	j 1b
