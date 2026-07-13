// =============================================================================
// tb/core/programs/08_amo.S
// =============================================================================
// Directed test: RV32A AMOSWAP/ADD/XOR/AND/OR/MIN/MAX/MINU/MAXU. Each op
// checks both the returned old value (rd) and the resulting memory content.
// AMO instructions have no immediate/offset field, so the address is always
// computed into a register first.
// =============================================================================

#include "test_macros.h"

.section .text.start
.global _start
_start:
    li   sp, 0x7ff0
    li   x5, 0x2000        // scratch data base

    // AMOSWAP.W
    addi  x4, x5, 0
    li    x6, 10
    sw    x6, 0(x4)
    li    x7, 99
    amoswap.w x8, x7, (x4)
    ASSERT_EQ x8, 10, 1
    lw    x9, 0(x4)
    ASSERT_EQ x9, 99, 2

    // AMOADD.W
    addi  x4, x5, 4
    li    x6, 10
    sw    x6, 0(x4)
    li    x7, 3
    amoadd.w x8, x7, (x4)
    ASSERT_EQ x8, 10, 3
    lw    x9, 0(x4)
    ASSERT_EQ x9, 13, 4

    // AMOXOR.W
    addi  x4, x5, 8
    li    x6, 0xF0F0F0F0
    sw    x6, 0(x4)
    li    x7, 0x0F0F0F0F
    amoxor.w x8, x7, (x4)
    ASSERT_EQ x8, 0xF0F0F0F0, 5
    lw    x9, 0(x4)
    ASSERT_EQ x9, 0xFFFFFFFF, 6

    // AMOAND.W
    addi  x4, x5, 12
    li    x6, 0xFF00FF00
    sw    x6, 0(x4)
    li    x7, 0x0FF00FF0
    amoand.w x8, x7, (x4)
    ASSERT_EQ x8, 0xFF00FF00, 7
    lw    x9, 0(x4)
    ASSERT_EQ x9, 0x0F000F00, 8

    // AMOOR.W
    addi  x4, x5, 16
    li    x6, 0xF0F0F0F0
    sw    x6, 0(x4)
    li    x7, 0x0F0F0F0F
    amoor.w x8, x7, (x4)
    ASSERT_EQ x8, 0xF0F0F0F0, 9
    lw    x9, 0(x4)
    ASSERT_EQ x9, 0xFFFFFFFF, 10

    // AMOMIN.W (signed): min(10, -3) = -3
    addi  x4, x5, 20
    li    x6, 10
    sw    x6, 0(x4)
    li    x7, -3
    amomin.w x8, x7, (x4)
    ASSERT_EQ x8, 10, 11
    lw    x9, 0(x4)
    ASSERT_EQ x9, -3, 12

    // AMOMAX.W (signed): max(-3, 10) = 10
    addi  x4, x5, 24
    li    x6, -3
    sw    x6, 0(x4)
    li    x7, 10
    amomax.w x8, x7, (x4)
    ASSERT_EQ x8, -3, 13
    lw    x9, 0(x4)
    ASSERT_EQ x9, 10, 14

    // AMOMINU.W (unsigned): minu(0xFFFFFFFF, 5) = 5
    addi  x4, x5, 28
    li    x6, 0xFFFFFFFF
    sw    x6, 0(x4)
    li    x7, 5
    amominu.w x8, x7, (x4)
    ASSERT_EQ x8, 0xFFFFFFFF, 15
    lw    x9, 0(x4)
    ASSERT_EQ x9, 5, 16

    // AMOMAXU.W (unsigned): maxu(5, 0xFFFFFFFF) = 0xFFFFFFFF
    addi  x4, x5, 32
    li    x6, 5
    sw    x6, 0(x4)
    li    x7, 0xFFFFFFFF
    amomaxu.w x8, x7, (x4)
    ASSERT_EQ x8, 5, 17
    lw    x9, 0(x4)
    ASSERT_EQ x9, 0xFFFFFFFF, 18

    RVTEST_PASS
