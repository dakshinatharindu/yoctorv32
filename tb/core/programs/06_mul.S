// =============================================================================
// tb/core/programs/06_mul.S
// =============================================================================
// Directed test: RV32M MUL/MULH/MULHSU/MULHU (single-cycle, folded into
// alu.sv) across sign combinations, including INT_MIN operands.
// =============================================================================

#include "test_macros.h"

.section .text.start
.global _start
_start:
    li   sp, 0x7ff0

    // MUL: low 32 bits, sign-agnostic.
    li    x10, 6
    li    x11, 7
    mul   x12, x10, x11
    ASSERT_EQ x12, 42, 1

    li    x10, -6
    li    x11, 7
    mul   x12, x10, x11
    ASSERT_EQ x12, -42, 2

    li    x10, -6
    li    x11, -7
    mul   x12, x10, x11
    ASSERT_EQ x12, 42, 3

    // MULH: signed x signed, high word. 65536 * 65536 = 2^32 -> hi=1, lo=0.
    li    x10, 0x00010000
    li    x11, 0x00010000
    mulh  x12, x10, x11
    ASSERT_EQ x12, 1, 4
    mul   x12, x10, x11
    ASSERT_EQ x12, 0, 5

    // MULHSU: signed(-1) * unsigned(65536) = -65536 -> hi=0xFFFFFFFF, lo=0xFFFF0000.
    li    x10, -1
    li    x11, 0x00010000
    mulhsu x12, x10, x11
    ASSERT_EQ x12, 0xFFFFFFFF, 6
    mul   x12, x10, x11
    ASSERT_EQ x12, 0xFFFF0000, 7

    // MULHU: unsigned(0xFFFFFFFF)^2 = 0xFFFFFFFE00000001 -> hi=0xFFFFFFFE.
    li    x10, 0xFFFFFFFF
    li    x11, 0xFFFFFFFF
    mulhu x12, x10, x11
    ASSERT_EQ x12, 0xFFFFFFFE, 8

    // INT_MIN * INT_MIN (signed): 2^62 -> hi=0x40000000, lo=0.
    li    x10, 0x80000000
    li    x11, 0x80000000
    mulh  x12, x10, x11
    ASSERT_EQ x12, 0x40000000, 9
    mul   x12, x10, x11
    ASSERT_EQ x12, 0, 10

    // INT_MIN (signed) * INT_MIN-bit-pattern-as-unsigned (2^31): -2^62 ->
    // hi=0xC0000000, lo=0.
    li    x10, 0x80000000
    li    x11, 0x80000000
    mulhsu x12, x10, x11
    ASSERT_EQ x12, 0xC0000000, 11

    RVTEST_PASS
