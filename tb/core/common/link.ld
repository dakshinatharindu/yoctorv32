/* =============================================================================
 * tb/core/common/link.ld
 * =============================================================================
 * Minimal bare-metal linker script for directed core-level test programs.
 * Core resets to PC 0 (core_pkg::RESET_PC), so .text starts at address 0.
 * TOHOST_ADDR (see test_macros.h) is left unbacked by any section — it is a
 * bus address the testbench snoops, not real memory the program reads back.
 * ============================================================================= */

OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY
{
  RAM (rwx) : ORIGIN = 0x00000000, LENGTH = 32K
}

SECTIONS
{
  . = 0x00000000;

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
