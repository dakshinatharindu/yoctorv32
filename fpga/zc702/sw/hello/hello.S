// =============================================================================
// fpga/zc702/sw/hello/hello.S
// =============================================================================
// Milestone 1 bare-metal program for the ZC702: programs the UART's baud
// divisor, prints a banner, then echoes every received byte, all in polling
// mode (no interrupts). Runs from the 64 KiB block RAM in fpga_top.sv, linked
// at address 0 (core_pkg::RESET_PC).
//
// The UART registers are word-spaced (reg-shift=2), see rtl/peripherals/
// uart.sv. Its divisor resets to 0, so nothing is transmitted until DLL/DLM
// are written. uart.sv's bit period is divisor * 16 clk cycles, giving
// divisor = CLK_HZ / (16 * BAUD), rounded to nearest. CLK_HZ and BAUD come
// from build.sh and must match the clock fpga_top.sv actually generates.
// =============================================================================

#ifndef CLK_HZ
#define CLK_HZ 50000000
#endif
#ifndef BAUD
#define BAUD 9600
#endif

#define UART_DIVISOR ((CLK_HZ + 8 * BAUD) / (16 * BAUD))

#define UART_BASE 0x10000000
#define UART_THR  0x00   // write: transmit holding; DLL while LCR.DLAB=1
#define UART_RBR  0x00   // read:  receive buffer
#define UART_DLM  0x04   // while LCR.DLAB=1
#define UART_LCR  0x0C
#define UART_LSR  0x14

#define LSR_DR    0x01   // received byte available
#define LSR_THRE  0x20   // transmit holding register empty

.section .text.start
.global _start
_start:
    li   sp, 0x10000         // top of the 64 KiB block RAM
    li   s0, UART_BASE

    li   t0, 0x83            // LCR: DLAB=1, 8 data bits / no parity / 1 stop
    sw   t0, UART_LCR(s0)
    li   t0, (UART_DIVISOR & 0xff)
    sw   t0, UART_THR(s0)    // DLL
    li   t0, ((UART_DIVISOR >> 8) & 0xff)
    sw   t0, UART_DLM(s0)    // DLM
    li   t0, 0x03            // LCR: DLAB=0, 8N1
    sw   t0, UART_LCR(s0)

    la   s1, banner
    jal  ra, puts

// Echo loop. Enter arrives as CR alone, so follow it with LF.
echo:
    lw   t0, UART_LSR(s0)
    andi t0, t0, LSR_DR
    beqz t0, echo
    lw   t3, UART_RBR(s0)    // reading RBR clears LSR.DR
    jal  ra, putc
    li   t0, '\r'
    bne  t3, t0, echo
    li   t3, '\n'
    jal  ra, putc
    j    echo

// puts: send the NUL-terminated string at s1. Clobbers t0, t3, s1, s2.
puts:
    mv   s2, ra
.Lputs_next:
    lbu  t3, 0(s1)
    beqz t3, .Lputs_done
    jal  ra, putc
    addi s1, s1, 1
    j    .Lputs_next
.Lputs_done:
    jr   s2

// putc: poll LSR.THRE, then write t3 to THR. Clobbers t0. Returns via ra.
putc:
    lw   t0, UART_LSR(s0)
    andi t0, t0, LSR_THRE
    beqz t0, putc
    sw   t3, UART_THR(s0)
    ret

.section .rodata
banner:
    .asciz "\r\n\r\nyoctorv32 on ZC702: the RV32IMA core is alive\r\nType something, it will be echoed:\r\n"
