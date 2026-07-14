/* =============================================================================
 * tb/riscv-tests-env/link.ld
 * =============================================================================
 * Linker script for the vendored riscv-tests ISA suite (tb/riscv-tests-env/riscv-tests).
 * Upstream's own env/p/link.ld assumes RAM at 0x80000000; this core resets to
 * PC 0 (core_pkg::RESET_PC), so .text.init (containing _start, from
 * RVTEST_CODE_BEGIN) must start at 0x00000000 instead.
 *
 * .tohost is placed at 0x3000: the largest vendored test (rv32ui-p-ld_st)
 * compiles to ~4160 bytes of .text.init, so 0x3000 leaves comfortable margin
 * before .tohost while still fitting in the 32K RAM modeled by core_tb.sv.
 * sim/verilator/run_riscv_tests.sh passes +TOHOST_ADDR=3000 to match.
 * =============================================================================
 */

OUTPUT_ARCH("riscv")
ENTRY(_start)

/* No MEMORY/region ("> RAM") placement here on purpose: assigning multiple
 * output sections to the same named region makes the linker pack them back
 * to back within that region, silently overriding an explicit ". = 0x3000;"
 * dot-assignment in between. Plain SECTIONS with explicit "." jumps (same
 * style as the upstream env/p/link.ld this replaces) is what actually
 * honors the 0x3000 gap tohost needs. */
SECTIONS
{
  . = 0x00000000;

  .text.init : { *(.text.init) }

  . = 0x3000;
  .tohost : { *(.tohost) }

  . = ALIGN(4);
  .data : { *(.data*) }
  .bss  : { *(.bss*) *(COMMON) }

  . = ALIGN(4);
  _end = .;
}
