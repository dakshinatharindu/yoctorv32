// =============================================================================
// fpga/zc702/sw/hello.S
// =============================================================================
// Bare-metal test program for the ZC702: programs the UART's baud divisor,
// prints a banner, then echoes every received byte, all in polling mode (no
// interrupts).
//
// It is linked at 0x80000000 (ram.ld), loaded into PS DDR over JTAG
// (scripts/run.tcl) and started by the boot program (boot.S). Like a Linux
// kernel Image, it begins with a jump over the image magic word the boot
// program checks for.
//
// UART details and the CLK_HZ/BAUD divisor calculation are in soc.h.
// =============================================================================

#include "soc.h"

.section .text.start
.global _start
_start:
    j    start
    .org IMAGE_MAGIC_OFFSET
    .word IMAGE_MAGIC
start:
    li   s0, UART_BASE
    uart_init s0, t0

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
    .asciz "\r\nyoctorv32 on ZC702: running from DDR at 80000000\r\nType something, it will be echoed:\r\n"
