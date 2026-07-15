// =============================================================================
// tb/core/programs/11_wfi.S
// =============================================================================
// Directed test: WFI (decode.sv's SYSTEM/funct12=0x105 case) must be a
// legal instruction, not an illegal-instruction trap. No interrupt source
// is wired up in this core-only harness (core_tb.sv ties mtip=0), and WFI
// is decoded as a plain NOP (no stall-until-interrupt implemented), so
// execution must simply fall through to the next instruction.
//
// Encoded via raw .word (rather than the `wfi` mnemonic) to sidestep any
// assembler/ISA-string mnemonic-availability question, the same approach
// 10_csr_trap.S already uses for its illegal-instruction case.
// =============================================================================

#include "test_macros.h"

.section .text.start
.global _start
_start:
    li   sp, 0x7ff0

    la   t0, trap_handler
    csrw mtvec, t0

    li   x20, 0
    .word 0x10500073        // wfi
    li   x20, 1              // must be reached: wfi must not trap
    ASSERT_EQ x20, 1, 1

    RVTEST_PASS

// Shared trap handler: if WFI incorrectly traps, land here and fail loudly
// with a distinct code rather than hanging.
.align 2
trap_handler:
    RVTEST_FAIL 2
