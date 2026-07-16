// =============================================================================
// tb/soc/programs/04_uart_tx_irq.S
// =============================================================================
// Directed SoC-level test: interrupt-driven UART TX through the PLIC.
// Sends "Hi\n" the way a real driver does: write the first byte directly
// (poll-style kickoff), then enable THRE-empty (IER bit1) so each
// subsequent byte is sent from the interrupt handler once the previous one
// finishes. After the last byte, the handler masks IER bit1 (matching the
// documented level-based-THRE simplification in uart.sv — the driver
// itself is responsible for not re-arming an interrupt it has nothing left
// to service) so it can't spuriously refire. soc_tb.sv's uart_rx_monitor
// independently decodes the transmitted waveform, same cross-check
// 02_uart_tx.S already relies on.
// =============================================================================

#include "test_macros.h"

.section .text.start
.global _start
_start:
    li   sp, 0x7ff0

    la   t0, trap_handler
    csrw mtvec, t0

    li   s0, 0x10000000  // UART_BASE

    // UART: divisor=1, 8N1 (IER left at 0 for now).
    li   t0, 0x83
    sw   t0, 0x0C(s0)
    li   t1, 1
    sw   t1, 0x00(s0)
    sw   zero, 0x04(s0)
    li   t0, 0x03
    sw   t0, 0x0C(s0)

    // PLIC: priority[1]=1, threshold=0, enable source 1 for context 0.
    li   t2, 0x0C000004
    li   t0, 1
    sw   t0, 0(t2)
    li   t2, 0x0C200000
    sw   zero, 0(t2)
    li   t2, 0x0C002000
    li   t0, 0x2
    sw   t0, 0(t2)

    // Enable MEIE (mie bit 11) + global MIE (mstatus bit 3).
    li   t0, 0x800
    csrs mie, t0
    li   t0, 0x8
    csrs mstatus, t0

    li   s2, 0            // count of chars sent via interrupt so far
    li   x20, 0

    // Kick off transmission with the first byte, then enable THRE-empty
    // interrupt for the rest.
    li   t3, 'H'
    sw   t3, 0x00(s0)
    li   t0, 0x02
    sw   t0, 0x04(s0)     // IER: THRE enable (bit1)

.Lspin:
    j    .Lspin

// =============================================================================
// Shared trap handler.
// =============================================================================
.align 2
trap_handler:
    csrr t0, mcause
    li   t1, 0x8000000B   // CAUSE_M_EXTERNAL_INT
    beq  t0, t1, .Lh_ext
    RVTEST_FAIL 2

.Lh_ext:
    li   t2, 0x0C200004   // claim/complete, context 0
    lw   t0, 0(t2)
    ASSERT_EQ t0, 1, 3

    li   t4, 0
    beq  s2, t4, .Lh_send_i
    li   t4, 1
    beq  s2, t4, .Lh_send_nl

    // Nothing left to send: mask THRE-empty so it can't spuriously refire
    // (see uart.sv's header — the driver, not the hardware, is responsible
    // for this with our deliberately level-based THRE-pending signal).
    sw   zero, 0x04(s0)
    li   x20, 1
    la   t0, test_done
    csrw mepc, t0
    j    .Lh_complete

.Lh_send_i:
    li   t3, 'i'
    sw   t3, 0x00(s0)
    j    .Lh_complete

.Lh_send_nl:
    li   t3, '\n'
    sw   t3, 0x00(s0)

.Lh_complete:
    addi s2, s2, 1
    li   t0, 1
    sw   t0, 0(t2)         // PLIC complete
    mret

test_done:
    ASSERT_EQ x20, 1, 1
    RVTEST_PASS
