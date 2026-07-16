// =============================================================================
// tb/linux_boot/boot_stub.S
// =============================================================================
// Tiny reset-vector stub: real hardware resets to a fixed PC with all GPRs
// zero, so it can't preload a0 (hart id) / a1 (DTB pointer) the way remu's
// C++ harness cheats by poking the CPU object directly before the first
// step(). This stub lives at RESET_PC (0x0, unchanged core_pkg default)
// and sets up the RISC-V Linux boot convention by hand before jumping to
// the kernel entry point.
//
// _start itself is a single jump, deliberately: this system has no MMU, so
// a stray NULL(+small offset) pointer dereference from the kernel (caught
// on real hardware by a page fault) instead silently reads whatever is
// physically at that address. Found the hard way — a NULL fs_type in
// alloc_fs_context() read address 0x8, landed on this stub's own
// instruction bytes (which happened to disassemble as a plausible-looking
// pointer), and the kernel jumped through it and crashed. Padding real_start
// out to a high, structurally-implausible offset (no real kernel struct
// field lives at +0x800) means addresses 0..0x7ff genuinely read as zero
// (this testbench's memory is zero-initialized) instead of tempting a wild
// dereference into actually-executable-looking bytes.
// =============================================================================

.section .text.start
.global _start
_start:
    j    real_start

.org 0x800
real_start:
    li   a0, 0            // hart id = 0
    li   a1, 0x81000000   // dtb pointer (16 MiB into RAM, past the kernel Image)
    li   t0, 0x80000000   // kernel entry (Image load address)
    jr   t0
