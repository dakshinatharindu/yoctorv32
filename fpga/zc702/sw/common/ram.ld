/* =============================================================================
 * fpga/zc702/sw/common/ram.ld
 * =============================================================================
 * Linker script for bare-metal programs that are loaded into main RAM (PS DDR
 * on the board) and started by the boot program's jump to 0x80000000, the
 * same address the Linux kernel Image is loaded at.
 * ============================================================================= */

OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY
{
  RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 64M
}

SECTIONS
{
  . = 0x80000000;

  .text : {
    *(.text.start)
    *(.text*)
  } > RAM

  .rodata : { *(.rodata*) } > RAM
  .data   : { *(.data*)   } > RAM
  .bss    : { *(.bss*) *(COMMON) } > RAM

  . = ALIGN(4);
  _end = .;
}
