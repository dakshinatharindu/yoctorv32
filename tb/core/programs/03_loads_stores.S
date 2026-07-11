// =============================================================================
// tb/core/programs/03_loads_stores.S
// =============================================================================
// Directed test: LSU byte/halfword/word store+load, sign vs. zero extension,
// and all four byte offsets within a word (exercises lsu.sv's byte_off mux
// and wstrb generation).
// =============================================================================

#include "test_macros.h"

.section .text.start
.global _start
_start:
    li   sp, 0x7ff0
    li   x5, 0x2000        // scratch data base (clear of .text and TOHOST_ADDR)

    // Word store/load
    li   x6, 0xDEADBEEF
    sw   x6, 0(x5)
    lw   x7, 0(x5)
    ASSERT_EQ_REG x7, x6, 1

    // Byte store/load: signed vs. unsigned
    li   x6, 0xFFFFFF80    // -128
    sb   x6, 4(x5)
    lb   x7, 4(x5)
    ASSERT_EQ x7, -128, 2
    lbu  x7, 4(x5)
    ASSERT_EQ x7, 0x80, 3

    // Halfword store/load: signed vs. unsigned
    li   x6, 0xFFFF8000    // -32768
    sh   x6, 8(x5)
    lh   x7, 8(x5)
    ASSERT_EQ x7, -32768, 4
    lhu  x7, 8(x5)
    ASSERT_EQ x7, 0x8000, 5

    // Four individual byte stores at offsets 0..3 of one word, then a
    // word-read back to check byte placement/endianness.
    li   x6, 0x11
    sb   x6, 12(x5)
    li   x6, 0x22
    sb   x6, 13(x5)
    li   x6, 0x33
    sb   x6, 14(x5)
    li   x6, 0x44
    sb   x6, 15(x5)
    lw   x7, 12(x5)
    ASSERT_EQ x7, 0x44332211, 6

    lb   x7, 13(x5)
    ASSERT_EQ x7, 0x22, 7
    lb   x7, 15(x5)
    ASSERT_EQ x7, 0x44, 8

    // Halfword at byte offset 2 within a word (byte_off[1]=1 path in lsu.sv)
    li   x6, 0xABCD
    sh   x6, 14(x5)
    lhu  x7, 14(x5)
    ASSERT_EQ x7, 0xABCD, 9

    RVTEST_PASS
