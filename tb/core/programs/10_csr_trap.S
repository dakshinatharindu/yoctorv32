// =============================================================================
// tb/core/programs/10_csr_trap.S
// =============================================================================
// Directed test: bare-minimal M-mode CSR/trap machinery (csr.sv, decode.sv's
// SYSTEM-opcode decode, the sys_redirect pipeline flush/redirect path).
// Covers CSRRW/S/C/WI/SI/CI on mscratch, read-only CSR reads (mhartid/misa),
// ECALL/illegal-instruction/misaligned-load/misaligned-store traps routed
// through one shared handler, and MRET resuming execution right after each
// faulting instruction.
// =============================================================================

#include "test_macros.h"

.section .text.start
.global _start
_start:
    li   sp, 0x7ff0

    // Route all traps to the shared handler below (direct mode).
    la   t0, trap_handler
    csrw mtvec, t0

    // -------------------------------------------------------------------
    // CSRRW/CSRRS/CSRRC round-trip on mscratch (reset value 0).
    // -------------------------------------------------------------------
    li    t0, 0xAAAA5555
    csrrw t1, mscratch, t0
    ASSERT_EQ t1, 0, 1              // csrrw returns the pre-write value
    csrr  t1, mscratch
    ASSERT_EQ t1, 0xAAAA5555, 2

    li    t0, 0x0000000F
    csrrs t1, mscratch, t0
    ASSERT_EQ t1, 0xAAAA5555, 3     // csrrs also returns the pre-write value
    csrr  t1, mscratch
    ASSERT_EQ t1, 0xAAAA555F, 4

    li    t0, 0x0000000F
    csrrc t1, mscratch, t0
    ASSERT_EQ t1, 0xAAAA555F, 5
    csrr  t1, mscratch
    ASSERT_EQ t1, 0xAAAA5550, 6

    // A zero operand on CSRRS/CSRRC must not write (pure read, e.g. `csrr`).
    csrrs t1, mscratch, x0
    ASSERT_EQ t1, 0xAAAA5550, 7
    csrr  t1, mscratch
    ASSERT_EQ t1, 0xAAAA5550, 8

    // -------------------------------------------------------------------
    // Immediate forms: CSRRWI/CSRRSI/CSRRCI (5-bit unsigned immediate).
    // -------------------------------------------------------------------
    csrrwi t1, mscratch, 5
    ASSERT_EQ t1, 0xAAAA5550, 9
    csrr   t1, mscratch
    ASSERT_EQ t1, 5, 10

    csrrsi t1, mscratch, 2          // mscratch |= 2 -> 7
    csrr   t1, mscratch
    ASSERT_EQ t1, 7, 11

    csrrci t1, mscratch, 1          // mscratch &= ~1 -> 6
    csrr   t1, mscratch
    ASSERT_EQ t1, 6, 12

    // -------------------------------------------------------------------
    // Read-only CSRs: reading them must not trap (operand-zero CSRRS).
    // -------------------------------------------------------------------
    csrr t1, mhartid
    ASSERT_EQ t1, 0, 13
    csrr t1, misa
    ASSERT_EQ t1, 0x40001101, 14

    // -------------------------------------------------------------------
    // ECALL round trip: handler sets x20, bumps mepc past the ecall, mrets.
    // -------------------------------------------------------------------
    li   x20, 0
    ecall
    ASSERT_EQ x20, 1, 15

    // -------------------------------------------------------------------
    // Illegal instruction trap: handler sets x21, bumps mepc, mrets.
    // -------------------------------------------------------------------
    li   x21, 0
    .word 0xFFFFFFFF        // reserved encoding: opcode 7'b1111111 -> illegal
    ASSERT_EQ x21, 1, 16

    // -------------------------------------------------------------------
    // Misaligned load trap (cause 4): handler sets x22, bumps mepc, mrets.
    // -------------------------------------------------------------------
    li   x22, 0
    li   t0, 0x2001
    lw   t3, 0(t0)
    ASSERT_EQ x22, 1, 17

    // -------------------------------------------------------------------
    // Misaligned store trap (cause 6): handler sets x23, bumps mepc, mrets;
    // also confirm the misaligned store never actually touched memory.
    // -------------------------------------------------------------------
    li   t0, 0x2000
    li   t1, 0x11111111
    sw   t1, 0(t0)           // aligned baseline write

    li   x23, 0
    li   t0, 0x2001
    li   t1, 0x22222222
    sw   t1, 0(t0)           // misaligned -> must trap, must not write
    ASSERT_EQ x23, 1, 18

    li   t0, 0x2000
    lw   t2, 0(t0)
    ASSERT_EQ t2, 0x11111111, 19   // baseline word must be untouched

    RVTEST_PASS

// =============================================================================
// Shared trap handler: dispatch on mcause, mark which handler ran, advance
// mepc past the single-word faulting/trapping instruction, mret.
// =============================================================================
.align 2
trap_handler:
    csrr t0, mcause
    li   t1, 11
    beq  t0, t1, .Lh_ecall
    li   t1, 2
    beq  t0, t1, .Lh_illegal
    li   t1, 4
    beq  t0, t1, .Lh_load_mis
    li   t1, 6
    beq  t0, t1, .Lh_store_mis
    RVTEST_FAIL 20            // unexpected mcause

.Lh_ecall:
    li   x20, 1
    j    .Lh_advance_and_return

.Lh_illegal:
    li   x21, 1
    j    .Lh_advance_and_return

.Lh_load_mis:
    li   x22, 1
    j    .Lh_advance_and_return

.Lh_store_mis:
    li   x23, 1
    j    .Lh_advance_and_return

.Lh_advance_and_return:
    csrr t0, mepc
    addi t0, t0, 4
    csrw mepc, t0
    mret
