// =============================================================================
// tb/core/programs/12_pmp.S
// =============================================================================
// Directed test: PMP CSRs (pmpcfg0-3, pmpaddr0-15) must be legal, plain
// read/write storage (no enforcement — this core never enters S/U mode, so
// there's no privilege boundary left for PMP to guard). Confirmed necessary
// by tracing a real Linux boot: early M-mode setup unconditionally writes
// pmpaddr0/pmpcfg0, which would otherwise illegal-instruction-trap.
//
// Exercises both ends of the implemented range (pmpcfg0/pmpaddr0 and
// pmpcfg3/pmpaddr15) plus a value with bits set across the whole word, to
// catch an off-by-one in the range decode or a truncated storage width.
// =============================================================================

#include "test_macros.h"

.section .text.start
.global _start
_start:
    li   sp, 0x7ff0

    la   t0, trap_handler
    csrw mtvec, t0

    // pmpcfg0 / pmpaddr0 (low end of the implemented range).
    li    t0, 0x0000001F
    csrw  pmpcfg0, t0
    csrr  t1, pmpcfg0
    ASSERT_EQ t1, 0x0000001F, 1

    li    t0, 0xFFFFFFFF
    csrw  pmpaddr0, t0
    csrr  t1, pmpaddr0
    ASSERT_EQ t1, 0xFFFFFFFF, 2

    // pmpcfg3 / pmpaddr15 (high end of the implemented range).
    li    t0, 0xAAAA5555
    csrw  pmpcfg3, t0
    csrr  t1, pmpcfg3
    ASSERT_EQ t1, 0xAAAA5555, 3

    li    t0, 0x12345678
    csrw  pmpaddr15, t0
    csrr  t1, pmpaddr15
    ASSERT_EQ t1, 0x12345678, 4

    // pmpcfg0/pmpaddr0 must be independent storage from pmpcfg3/pmpaddr15
    // (a range-decode off-by-one could alias them onto the same register).
    csrr  t1, pmpcfg0
    ASSERT_EQ t1, 0x0000001F, 5
    csrr  t1, pmpaddr0
    ASSERT_EQ t1, 0xFFFFFFFF, 6

    RVTEST_PASS

// Shared trap handler: any trap here means a PMP access illegal-instruction
// trapped, which is exactly the bug this test exists to catch.
.align 2
trap_handler:
    RVTEST_FAIL 7
