// =============================================================================
// fpga/zc702/sw/boot.S
// =============================================================================
// Boot program for the DDR-backed SoC on the ZC702. Lives in the 4 KiB boot
// RAM at address 0 (core_pkg::RESET_PC), built into the bitstream. It is the
// FPGA counterpart of tb/linux_boot/boot_stub.S: it sets up the RISC-V Linux
// boot convention (a0 = hart id, a1 = device tree address) and jumps to the
// image at the start of main RAM. On top of that it:
//   - programs the UART and prints a banner, so there is a sign of life that
//     does not depend on anything in DDR
//   - checks that an image has actually been loaded (IMAGE_MAGIC, see soc.h)
//     before jumping, and otherwise says what it found and waits for a key
//     press before looking again, instead of running whatever DDR holds
//
// _start is a single jump and real_start sits at 0x800, with zeros between,
// for the reason explained in boot_stub.S: without an MMU a kernel NULL
// (+small offset) dereference reads this memory, and it should read zeros
// rather than something that looks like a pointer.
// =============================================================================

#include "soc.h"

.section .text.start
.global _start
_start:
    j    real_start

.org 0x800
real_start:
    li   s0, UART_BASE
    uart_init s0, t0

    la   s1, msg_banner
    jal  ra, puts

check_image:
    li   s4, RAM_BASE
    lw   s3, IMAGE_MAGIC_OFFSET(s4)
    li   t0, IMAGE_MAGIC
    bne  s3, t0, no_image

    la   s1, msg_jump
    jal  ra, puts

    // Let the last character leave the UART: the image may reprogram it.
.Lwait_idle:
    lw   t0, UART_LSR(s0)
    andi t0, t0, LSR_TEMT
    beqz t0, .Lwait_idle

    li   a0, 0                 // hart id
    li   a1, DTB_ADDR          // device tree pointer
    jr   s4

no_image:
    la   s1, msg_no_image
    jal  ra, puts
    jal  ra, puthex            // the word found where the magic should be
    la   s1, msg_retry
    jal  ra, puts
.Lwait_key:
    lw   t0, UART_LSR(s0)
    andi t0, t0, LSR_DR
    beqz t0, .Lwait_key
    lw   t0, UART_RBR(s0)      // reading RBR clears LSR.DR
    j    check_image

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

// puthex: send s3 as 8 hexadecimal digits. Clobbers t0, t1, t3, s2.
puthex:
    mv   s2, ra
    li   t1, 28
.Lhex_next:
    srl  t3, s3, t1
    andi t3, t3, 0xf
    addi t3, t3, '0'
    li   t0, '9'
    bleu t3, t0, .Lhex_put
    addi t3, t3, 'A' - '0' - 10
.Lhex_put:
    jal  ra, putc
    addi t1, t1, -4
    bgez t1, .Lhex_next
    jr   s2

// putc: poll LSR.THRE, then write t3 to THR. Clobbers t0. Returns via ra.
putc:
    lw   t0, UART_LSR(s0)
    andi t0, t0, LSR_THRE
    beqz t0, putc
    sw   t3, UART_THR(s0)
    ret

.section .rodata
msg_banner:
    .asciz "\r\nyoctorv32 boot\r\n"
msg_jump:
    .asciz "image found, jumping to 80000000\r\n"
msg_no_image:
    .asciz "no image at 80000000: expected 05435352 at +0x38, found "
msg_retry:
    .asciz "\r\nload one, then press any key to retry\r\n"
