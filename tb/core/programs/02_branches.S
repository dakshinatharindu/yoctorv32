// =============================================================================
// tb/core/programs/02_branches.S
// =============================================================================
// Directed test: all six branch conditions (branch_unit.sv br_op mapping),
// taken and not-taken, plus a backward-branch loop to exercise repeated
// PC redirects.
// =============================================================================

#include "test_macros.h"

.section .text.start
.global _start
_start:
    li   sp, 0x7ff0

    // BEQ taken
    li   x10, 5
    li   x11, 5
    beq  x10, x11, 1f
    RVTEST_FAIL 1
1:

    // BEQ not taken
    li   x10, 5
    li   x11, 6
    beq  x10, x11, 2f
    j    3f
2:
    RVTEST_FAIL 2
3:

    // BNE taken
    bne  x10, x11, 4f
    RVTEST_FAIL 3
4:

    // BLT signed: -1 < 1
    li   x10, -1
    li   x11, 1
    blt  x10, x11, 5f
    RVTEST_FAIL 4
5:

    // BGE signed: 1 >= -1
    bge  x11, x10, 6f
    RVTEST_FAIL 5
6:

    // BLTU unsigned: 0xFFFFFFFF is NOT < 1 unsigned
    bltu x10, x11, 7f
    j    8f
7:
    RVTEST_FAIL 6
8:

    // BGEU unsigned: 0xFFFFFFFF >= 1
    bgeu x10, x11, 9f
    RVTEST_FAIL 7
9:

    // Backward-branch loop: sum 1..5, expect 15
    li   x12, 0
    li   x13, 1
loop:
    add  x12, x12, x13
    addi x13, x13, 1
    li   x14, 6
    blt  x13, x14, loop
    ASSERT_EQ x12, 15, 8

    RVTEST_PASS
