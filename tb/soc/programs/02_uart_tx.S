// =============================================================================
// tb/soc/programs/02_uart_tx.S
// =============================================================================
// Directed SoC-level test: minimal 16550-compatible UART TX (rtl/peripherals/
// uart.sv), through the real interconnect, in polling mode. Programs the
// baud divisor (DLL/DLM while LCR.DLAB=1), sets 8N1, then sends "Hi\n" one
// byte at a time, polling LSR.THRE before each write and LSR.TEMT at the
// end. soc_tb.sv's uart_rx_monitor independently decodes the actual
// uart_tx waveform and logs it for a second, hardware-level confirmation.
// =============================================================================

#include "test_macros.h"

.section .text.start
.global _start
_start:
    li   sp, 0x7ff0

    li   s0, 0x10000000   // UART_BASE

    // Program divisor=1 (115200 baud @ the assumed 1.8432MHz reference —
    // matches uart_rx_monitor's BIT_PERIOD_CYCLES=16 in soc_tb.sv).
    li   t0, 0x83          // LCR: DLAB=1, 8 data bits / no parity / 1 stop
    sw   t0, 0x0C(s0)
    li   t1, 1
    sw   t1, 0x00(s0)      // DLL = 1
    sw   zero, 0x04(s0)    // DLM = 0
    li   t0, 0x03
    sw   t0, 0x0C(s0)      // LCR: DLAB=0, 8N1

    li   t3, 'H'
    jal  ra, send_byte
    li   t3, 'i'
    jal  ra, send_byte
    li   t3, '\n'
    jal  ra, send_byte

    // Wait for the transmitter to be fully idle before declaring victory.
.Lwait_temt:
    lw   t0, 0x14(s0)      // LSR
    andi t0, t0, 0x40      // TEMT
    beqz t0, .Lwait_temt

    RVTEST_PASS

// send_byte: poll LSR.THRE then write t3 to THR. Clobbers t0. Returns via ra.
.align 2
send_byte:
.Lwait_thre:
    lw   t0, 0x14(s0)      // LSR
    andi t0, t0, 0x20      // THRE
    beqz t0, .Lwait_thre
    sw   t3, 0x00(s0)      // THR
    jr   ra
