// =============================================================================
// tb/core/programs/07_div.S
// =============================================================================
// Directed test: RV32M DIV/DIVU/REM/REMU via the multi-cycle div_unit and
// its pipeline stall (execute_stage.sv/hazard_unit.sv/id_ex_reg.sv). Covers
// sign combinations, divide-by-zero, INT_MIN/-1 overflow, forwarding out of
// a completed divide, and a load-use hazard feeding a divide.
// =============================================================================

#include "test_macros.h"

.section .text.start
.global _start
_start:
    li   sp, 0x7ff0

    // Signed DIV/REM, all sign combinations of 17 and 5.
    li    x10, 17
    li    x11, 5
    div   x12, x10, x11
    ASSERT_EQ x12, 3, 1
    rem   x12, x10, x11
    ASSERT_EQ x12, 2, 2

    li    x10, -17
    li    x11, 5
    div   x12, x10, x11
    ASSERT_EQ x12, -3, 3
    rem   x12, x10, x11
    ASSERT_EQ x12, -2, 4

    li    x10, 17
    li    x11, -5
    div   x12, x10, x11
    ASSERT_EQ x12, -3, 5
    rem   x12, x10, x11
    ASSERT_EQ x12, 2, 6

    li    x10, -17
    li    x11, -5
    div   x12, x10, x11
    ASSERT_EQ x12, 3, 7
    rem   x12, x10, x11
    ASSERT_EQ x12, -2, 8

    // Unsigned DIVU/REMU.
    li    x10, 0xFFFFFFFF
    li    x11, 2
    divu  x12, x10, x11
    ASSERT_EQ x12, 0x7FFFFFFF, 9
    remu  x12, x10, x11
    ASSERT_EQ x12, 1, 10

    // Divide-by-zero: no trap, spec-defined results.
    li    x10, 42
    li    x11, 0
    div   x12, x10, x11
    ASSERT_EQ x12, 0xFFFFFFFF, 11
    rem   x12, x10, x11
    ASSERT_EQ x12, 42, 12
    divu  x12, x10, x11
    ASSERT_EQ x12, 0xFFFFFFFF, 13
    remu  x12, x10, x11
    ASSERT_EQ x12, 42, 14

    // Signed overflow: INT_MIN / -1.
    li    x10, 0x80000000
    li    x11, -1
    div   x12, x10, x11
    ASSERT_EQ x12, 0x80000000, 15
    rem   x12, x10, x11
    ASSERT_EQ x12, 0, 16

    // Forwarding: instruction immediately after DIV consumes its result.
    li    x10, 100
    li    x11, 7
    div   x12, x10, x11    // x12 = 14
    addi  x13, x12, 1
    ASSERT_EQ x13, 15, 17

    // Load-use hazard feeding straight into a divide.
    li    x5, 0x2000
    li    x6, 100
    sw    x6, 0(x5)
    lw    x7, 0(x5)
    li    x9, 9
    div   x8, x7, x9       // 100 / 9 = 11
    ASSERT_EQ x8, 11, 18

    RVTEST_PASS
