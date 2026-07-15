// =============================================================================
// tb/soc/programs/01_timer_irq.S
// =============================================================================
// Directed SoC-level test: real timer interrupt through CLINT, exercising
// the new interrupt-taken path in csr.sv end-to-end (mip.MTIP live from an
// external CLINT reached through the real data_bus interconnect, mie.MTIE +
// mstatus.MIE gating, mepc pointing at the preempted instruction, mret
// escaping cleanly).
//
// Programs mtimecmp a small delta past the current mtime, enables the
// timer interrupt, then spins (no WFI decode yet — out of scope for this
// pass) until the interrupt actually fires and preempts the spin loop.
// =============================================================================

#include "test_macros.h"

.section .text.start
.global _start
_start:
    li   sp, 0x7ff0

    la   t0, trap_handler
    csrw mtvec, t0

    // CLINT base + standard SiFive register offsets.
    li   s0, 0x11000000  // CLINT_BASE
    li   s1, 0xBFF8       // mtime_lo offset
    li   s2, 0x4000       // mtimecmp_lo offset
    li   s3, 0x4004       // mtimecmp_hi offset

    // Safe ordering: raise mtimecmp_hi first so the 64-bit compare can't
    // spuriously fire against mtime's current (near-zero) hi half while
    // mtimecmp_lo is still being reprogrammed.
    add  t0, s0, s3
    sw   zero, 0(t0)      // mtimecmp_hi = 0

    add  t0, s0, s1
    lw   t1, 0(t0)        // t1 = mtime_lo (current)
    li   t2, 500
    add  t1, t1, t2       // t1 = target = mtime_lo + 500

    add  t0, s0, s2
    sw   t1, 0(t0)        // mtimecmp_lo = target

    // Enable MTIE (mie bit 7) + global MIE (mstatus bit 3).
    li   t0, 0x80
    csrs mie, t0
    li   t0, 0x8
    csrs mstatus, t0

    li   x20, 0           // set by the handler once the timer trap fires
.Lspin:
    j    .Lspin

// =============================================================================
// Shared trap handler. Confirms the cause is the timer interrupt, then
// redirects mepc to test_done (rather than back into the spin loop) before
// mret — mtip stays asserted until mtimecmp is reprogrammed again, so
// returning into .Lspin would just retrigger the same trap immediately.
// =============================================================================
.align 2
trap_handler:
    csrr t0, mcause
    li   t1, 0x80000007
    beq  t0, t1, .Lh_timer
    RVTEST_FAIL 2         // unexpected mcause

.Lh_timer:
    li   x20, 1
    // mtip stays asserted (level-triggered) until mtimecmp is reprogrammed
    // past it again; a real ISR always does this before returning. Mask
    // MTIE off here instead, since this test only expects exactly one
    // interrupt — otherwise the moment mret restores mstatus.MIE, the
    // still-pending timer interrupt would immediately retrigger forever.
    li   t1, 0x80
    csrc mie, t1
    la   t0, test_done
    csrw mepc, t0
    mret

test_done:
    ASSERT_EQ x20, 1, 1
    RVTEST_PASS
