/* =============================================================================
 * tb/fpga/riscv-tests-ram.ld
 * =============================================================================
 * tb/riscv-tests-env/link.ld moved to main RAM: links the vendored riscv-tests
 * at 0x80000000 so they execute out of the (modeled) PS DDR through the FPGA
 * memory bridge, in tb/fpga/soc_ddr_tb.sv. .tohost keeps its 0x3000 offset,
 * so sim/verilator/run_fpga_tests.sh passes +TOHOST_ADDR=80003000.
 * =============================================================================
 */

OUTPUT_ARCH("riscv")
ENTRY(_start)

SECTIONS
{
  . = 0x80000000;

  .text.init : { *(.text.init) }

  . = 0x80003000;
  .tohost : { *(.tohost) }

  . = ALIGN(4);
  .data : { *(.data*) }
  .bss  : { *(.bss*) *(COMMON) }

  . = ALIGN(4);
  _end = .;
}
