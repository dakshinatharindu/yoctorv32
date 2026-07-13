// =============================================================================
// tb/core/programs/09_lrsc.S
// =============================================================================
// Directed test: RV32A LR.W/SC.W reservation handling (lsu.sv). Like AMOs,
// LR/SC have no immediate/offset field, so addresses are computed into a
// register first.
// =============================================================================

#include "test_macros.h"

.section .text.start
.global _start
_start:
    li   sp, 0x7ff0
    li   x5, 0x2000        // reservation address

    // LR + modify + SC: success (0 == success per spec).
    li    x6, 5
    sw    x6, 0(x5)
    lr.w  x7, (x5)
    ASSERT_EQ x7, 5, 1
    addi  x8, x7, 1
    sc.w  x9, x8, (x5)
    ASSERT_EQ x9, 0, 2
    lw    x10, 0(x5)
    ASSERT_EQ x10, 6, 3

    // SC without a live reservation (previous SC already cleared it) fails.
    li    x11, 42
    sc.w  x12, x11, (x5)
    ASSERT_EQ x12, 1, 4
    lw    x13, 0(x5)
    ASSERT_EQ x13, 6, 5     // memory unchanged by the failed SC

    // LR, then SC to a different address: fails, and memory at the LR
    // address is untouched.
    addi  x14, x5, 16
    lr.w  x15, (x5)
    li    x16, 77
    sc.w  x17, x16, (x14)
    ASSERT_EQ x17, 1, 6
    lw    x18, 0(x5)
    ASSERT_EQ x18, 6, 7

    // LR, then a plain store to the *same* reserved address, then SC:
    // the intervening store must invalidate the reservation, so SC fails
    // and does not overwrite the plain store's value.
    lr.w  x19, (x5)
    li    x20, 999
    sw    x20, 0(x5)
    li    x21, 111
    sc.w  x22, x21, (x5)
    ASSERT_EQ x22, 1, 8
    lw    x23, 0(x5)
    ASSERT_EQ x23, 999, 9

    RVTEST_PASS
