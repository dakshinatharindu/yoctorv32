// =============================================================================
// tb/soc/programs/03_uart_rx_irq.S
// =============================================================================
// Directed SoC-level test: interrupt-driven UART RX through the PLIC.
// soc_tb.sv's uart_tx_injector drives one byte (default 0x41 'A', see
// +INJECT_BYTE/+INJECT_CYCLE) onto uart_rx partway through the run, as if
// an external peer sent it. Programs the UART's RX-data-available
// interrupt (IER bit 0), the PLIC (priority/enable/threshold for source 1,
// the UART), and mie.MEIE/mstatus.MIE, then spins until the external
// interrupt arrives. Handler: claims via PLIC, confirms the claimed ID is
// 1, reads RBR and checks it against the injected byte, confirms LSR.DR
// cleared, completes via PLIC, done.
// =============================================================================

#include "test_macros.h"

.section .text.start
.global _start
_start:
    li   sp, 0x7ff0

    la   t0, trap_handler
    csrw mtvec, t0

    li   s0, 0x10000000  // UART_BASE

    // UART: divisor=1, 8N1, enable RX-data-available interrupt (IER bit0).
    li   t0, 0x83
    sw   t0, 0x0C(s0)     // LCR: DLAB=1
    li   t1, 1
    sw   t1, 0x00(s0)     // DLL = 1
    sw   zero, 0x04(s0)   // DLM = 0
    li   t0, 0x03
    sw   t0, 0x0C(s0)     // LCR: DLAB=0, 8N1
    li   t0, 0x01
    sw   t0, 0x04(s0)     // IER: RX data available enable

    // PLIC: priority[1]=1, threshold=0 (1 > 0, so it can fire), enable
    // source 1 for context 0. Offsets 0x2000/0x200000 exceed sw's 12-bit
    // immediate range, so each PLIC register is addressed as its own
    // absolute li'd constant rather than PLIC_BASE+offset.
    li   t2, 0x0C000004   // priority[1]
    li   t0, 1
    sw   t0, 0(t2)
    li   t2, 0x0C200000   // threshold, context 0
    sw   zero, 0(t2)
    li   t2, 0x0C002000   // enable, context 0
    li   t0, 0x2
    sw   t0, 0(t2)

    // Enable MEIE (mie bit 11) + global MIE (mstatus bit 3).
    li   t0, 0x800
    csrs mie, t0
    li   t0, 0x8
    csrs mstatus, t0

    li   x20, 0           // set by the handler once the RX interrupt fires
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
    RVTEST_FAIL 2         // unexpected mcause

.Lh_ext:
    // Claim via PLIC; confirm it was source 1 (the UART).
    li   t2, 0x0C200004    // claim/complete, context 0
    lw   t0, 0(t2)
    ASSERT_EQ t0, 1, 3

    // Read RBR; confirm it matches the byte the testbench injected.
    lw   t0, 0x00(s0)
    andi t0, t0, 0xFF
    ASSERT_EQ t0, 0x41, 4  // must match soc_tb.sv's default +INJECT_BYTE

    // LSR.DR must have cleared on that RBR read.
    lw   t0, 0x14(s0)
    andi t0, t0, 0x01
    ASSERT_EQ t0, 0, 5

    // Complete via PLIC (write 1 to claim/complete).
    li   t0, 1
    sw   t0, 0(t2)

    li   x20, 1
    la   t0, test_done
    csrw mepc, t0
    mret

test_done:
    ASSERT_EQ x20, 1, 1
    RVTEST_PASS
