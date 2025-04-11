# Telepath

Telepath is an Operating System prototype for the RISC-V ISA (RV64G) with:

- Shared memory IPC
- Message passing IPC via Channels (built on top of shared memory with minimal overhead)
- Microkernel with user space drivers
- Capability-based security
- Symmetric multiprocessing (SMP)
- Pre-emptive multitasking
- Round-robin scheduling
- Futex support

## Building

Required software for building is the [Zig](https://ziglang.org) compiler (version 0.14 currently) and the tar archiver (for creating the driver archive for init). To build the kernel image and the init executable (analogous to Linux initramfs), run the following command.

```
zig build
```

## Running

The operating system can be run on the QEMU virtual machine (qemu-system-riscv64) with the following command.

```
zig build run
```
