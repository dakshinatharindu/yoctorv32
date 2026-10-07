// =============================================================================
// fpga/zc702/sw/hello/hello.S
// =============================================================================
// Bare-metal test program for the ZC702: programs the UART's baud divisor,
// prints a banner, then echoes every received byte, all in polling mode (no
// interrupts). Built two ways by build.sh:
//
//   hello.mem      milestone 1: linked at address 0 (core_pkg::RESET_PC), for
//                  the 64 KiB block RAM in fpga_top.sv.
//   hello_ddr.bin  milestone 2: built with -DDDR_IMAGE and linked at
//                  0x80000000, to be loaded into PS DDR and started by the
//                  boot program (sw/boot/boot.S). That build begins with a
//                  jump over the image magic word the boot program checks
//                  for, at the offset where a Linux kernel Image has it.
//
// UART details and the CLK_HZ/BAUD divisor calculation are in common/soc.h.
// =============================================================================

#include "soc.h"

.section .text.start
.global _start
_start:
#ifdef DDR_IMAGE
    j    start
    .org IMAGE_MAGIC_OFFSET
    .word IMAGE_MAGIC
start:
#endif
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
#ifdef DDR_IMAGE
    .asciz "\r\nyoctorv32 on ZC702: running from DDR at 80000000\r\nType something, it will be echoed:\r\n"
#else
    .asciz "\r\n\r\nyoctorv32 on ZC702: the RV32IMA core is alive\r\nType something, it will be echoed:\r\n"
#endif
