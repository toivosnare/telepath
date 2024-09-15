# Telepath

Telepath is an Operating System prototype for the RISC-V (RV64G) ISA with:

- Shared memory IPC
- Message passing IPC via Channels (built on top of shared memory with minimal overhead)
- Microkernel with user space drivers
- Capability-based security
- Preemptive multitasking
- Round-robin scheduling
- Futex support
- Buddy system page allocator.

## Building

Required software for building is the [Zig](https://ziglang.org) compiler (version 0.13 currently) and the tar archiver (for creating the driver arhive for init). To build the kernel image, run the following command.

```
zig build
```

## Running

The operating system can be run on the QEMU (qemu-system-riscv64) virtual machine with the following command. 

```
zig build run
```
