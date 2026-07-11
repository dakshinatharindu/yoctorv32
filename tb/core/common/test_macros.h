/* =============================================================================
 * tb/core/common/test_macros.h
 * =============================================================================
 * Minimal riscv-tests-style pass/fail convention for directed core_top tests.
 * No CSR/ecall support exists yet, so "done" is signaled the only way this
 * core can: a store to TOHOST_ADDR, which core_tb.sv snoops on the dmem bus.
 *
 *   value == 1          -> PASS
 *   value == (code<<1)|1 -> FAIL with `code` (code 0 is reserved, use >=1)
 *
 * Every macro here ends by spinning (`j 1b`) so the core parks after
 * reporting instead of executing whatever garbage follows in memory.
 * ============================================================================= */

#ifndef TB_CORE_TEST_MACROS_H
#define TB_CORE_TEST_MACROS_H

#define TOHOST_ADDR 0x1000

// Internal spin/skip labels use GAS's `\@` (a counter incremented on every
// macro invocation) so they never collide with numeric local labels
// (1f/2f/...) used by the calling test code — plain "1:" here would
// otherwise be captured by the caller's own "1f" references.
.macro RVTEST_PASS
    li   t0, TOHOST_ADDR
    li   t1, 1
    sw   t1, 0(t0)
.Lspin\@:
    j    .Lspin\@
.endm

.macro RVTEST_FAIL code
    li   t0, TOHOST_ADDR
    li   t1, (((\code) << 1) | 1)
    sw   t1, 0(t0)
.Lspin\@:
    j    .Lspin\@
.endm

/* Fail with `code` unless reg == expected. Clobbers t0/t1/t6. */
.macro ASSERT_EQ reg, expected, code
    li   t6, \expected
    beq  \reg, t6, .Lok\@
    RVTEST_FAIL \code
.Lok\@:
.endm

/* Fail with `code` unless ra == rb. Clobbers t0/t1. */
.macro ASSERT_EQ_REG ra, rb, code
    beq  \ra, \rb, .Lok\@
    RVTEST_FAIL \code
.Lok\@:
.endm

#endif
