// =============================================================================
// tb/fpga/jump_to_ram.S
// =============================================================================
// Smallest possible boot-RAM contents for simulation: jump from the reset
// vector to the start of main RAM. Used to run the riscv-tests through the
// DDR bridge (tb/fpga/soc_ddr_tb.sv); their own startup code resets every
// register, so the t0 this leaves behind does not matter.
// =============================================================================

.section .text.start
.global _start
_start:
    lui  t0, 0x80000
    jr   t0
