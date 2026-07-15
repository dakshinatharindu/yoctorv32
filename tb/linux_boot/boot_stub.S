// =============================================================================
// tb/linux_boot/boot_stub.S
// =============================================================================
// Tiny reset-vector stub: real hardware resets to a fixed PC with all GPRs
// zero, so it can't preload a0 (hart id) / a1 (DTB pointer) the way remu's
// C++ harness cheats by poking the CPU object directly before the first
// step(). This stub lives at RESET_PC (0x0, unchanged core_pkg default)
// and sets up the RISC-V Linux boot convention by hand before jumping to
// the kernel entry point.
// =============================================================================

.section .text.start
.global _start
_start:
    li   a0, 0            // hart id = 0
    li   a1, 0x81000000   // dtb pointer (16 MiB into RAM, past the kernel Image)
    li   t0, 0x80000000   // kernel entry (Image load address)
    jr   t0
