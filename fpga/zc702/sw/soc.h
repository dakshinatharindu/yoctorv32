// =============================================================================
// fpga/zc702/sw/soc.h
// =============================================================================
// Addresses and UART definitions shared by the bare-metal FPGA programs
// (assembly; include with #include "soc.h").
//
// The UART registers are word-spaced (reg-shift=2), see rtl/peripherals/
// uart.sv. Its divisor resets to 0, so nothing is transmitted until DLL/DLM
// are written. uart.sv's bit period is divisor * 16 clk cycles, giving
// divisor = CLK_HZ / (16 * BAUD), rounded to nearest. CLK_HZ and BAUD come
// from the build scripts and must match the clock the FPGA top generates.
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
#define LSR_TEMT  0x40   // transmitter completely idle

// Main RAM as the core sees it (PS DDR behind fpga/zc702/rtl/mem_bridge.sv),
// and where the Linux boot convention expects things in it.
#define RAM_BASE   0x80000000
#define DTB_ADDR   0x81000000

// Every image started from RAM_BASE carries this word at offset 0x38. It is
// the second magic number of the RISC-V Linux kernel Image header ("RSC\x05"),
// so a real kernel has it, and the boot program refuses to jump without it.
#define IMAGE_MAGIC_OFFSET 0x38
#define IMAGE_MAGIC        0x05435352

// Program the UART for CLK_HZ/BAUD, 8N1. Expects the UART base in \base and
// clobbers \tmp.
.macro uart_init base, tmp
    li   \tmp, 0x83            // LCR: DLAB=1, 8 data bits / no parity / 1 stop
    sw   \tmp, UART_LCR(\base)
    li   \tmp, (UART_DIVISOR & 0xff)
    sw   \tmp, UART_THR(\base) // DLL
    li   \tmp, ((UART_DIVISOR >> 8) & 0xff)
    sw   \tmp, UART_DLM(\base) // DLM
    li   \tmp, 0x03            // LCR: DLAB=0, 8N1
    sw   \tmp, UART_LCR(\base)
.endm
