// =============================================================================
// tb/core/programs/01_alu_imm.S
// =============================================================================
// Directed test: OP-IMM and OP instructions (decode.sv ALU op mapping),
// plus LUI/AUIPC immediate formation.
// =============================================================================

#include "test_macros.h"

.section .text.start
.global _start
_start:
    li    sp, 0x7ff0

    // ADDI
    addi  x10, x0, 5
    ASSERT_EQ x10, 5, 1
    addi  x10, x0, -1
    ASSERT_EQ x10, -1, 2

    // SLTI / SLTIU
    li    x11, -1
    slti  x10, x11, 0
    ASSERT_EQ x10, 1, 3
    sltiu x10, x11, 1
    ASSERT_EQ x10, 0, 4

    // XORI / ORI / ANDI
    li    x11, 0xAAAAAAAA
    xori  x10, x11, -1
    ASSERT_EQ x10, 0x55555555, 5

    li    x11, 0x0F0
    ori   x10, x11, 0x00F
    ASSERT_EQ x10, 0x0FF, 6
    andi  x10, x11, 0x0FF
    ASSERT_EQ x10, 0x0F0, 7

    // SLLI / SRLI / SRAI
    li    x11, 1
    slli  x10, x11, 31
    ASSERT_EQ x10, 0x80000000, 8

    li    x11, 0x80000000
    srli  x10, x11, 31
    ASSERT_EQ x10, 1, 9
    srai  x10, x11, 31
    ASSERT_EQ x10, -1, 10

    // LUI
    lui   x10, 0xDEAD0
    ASSERT_EQ x10, 0xDEAD0000, 11

    // AUIPC: pc-relative, check against an `la` of the same instruction
auipc_check:
    auipc x10, 0
    la    x11, auipc_check
    ASSERT_EQ_REG x10, x11, 12

    // R-type
    li    x11, 7
    li    x12, 3
    add   x10, x11, x12
    ASSERT_EQ x10, 10, 13
    sub   x10, x11, x12
    ASSERT_EQ x10, 4, 14
    and   x10, x11, x12
    ASSERT_EQ x10, 3, 15
    or    x10, x11, x12
    ASSERT_EQ x10, 7, 16
    xor   x10, x11, x12
    ASSERT_EQ x10, 4, 17

    li    x11, 1
    li    x12, 4
    sll   x10, x11, x12
    ASSERT_EQ x10, 16, 18

    li    x11, 0x80000000
    li    x12, 4
    srl   x10, x11, x12
    ASSERT_EQ x10, 0x08000000, 19
    sra   x10, x11, x12
    ASSERT_EQ x10, 0xF8000000, 20

    li    x11, -5
    li    x12, 3
    slt   x10, x11, x12
    ASSERT_EQ x10, 1, 21
    sltu  x10, x11, x12
    ASSERT_EQ x10, 0, 22

    RVTEST_PASS
