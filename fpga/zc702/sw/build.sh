#!/usr/bin/env bash
# ==========================================================
# fpga/zc702/sw/build.sh
# Builds the bare-metal FPGA programs:
#
#   boot.mem    the boot program (boot.S) as the boot-RAM init file that
#               fpga/zc702/rtl/mem_bridge.sv loads: one 32-bit little-endian
#               word per line, for $readmemh. It is built into the bitstream,
#               so run this before fpga/zc702/scripts/build.tcl.
#   hello.bin   the hello program (hello.S), linked at 0x80000000, to be
#               loaded into PS DDR over JTAG (fpga/zc702/scripts/run.tcl).
#   hello.vh    the same as byte-wide Verilog hex with RAM-relative
#               addresses, for simulation (tb/fpga/fpga_soc_tb.sv).
#
# Needs the RISC-V toolchain (riscv32-unknown-elf- on PATH, as in the dev
# container; override with RISCV_PREFIX).
#
# Usage (from anywhere):
#   fpga/zc702/sw/build.sh
#   CLK_HZ=40000000 fpga/zc702/sw/build.sh   # if the FPGA clock changes
#   OUT_DIR=/some/dir fpga/zc702/sw/build.sh  # default: fpga/zc702/build
#
# Also written next to the images: .elf and .dis (disassembly) of each.
# ==========================================================

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT"

SW="fpga/zc702/sw"
OUT_DIR=${OUT_DIR:-$ROOT/fpga/zc702/build}
mkdir -p "$OUT_DIR"

RISCV_PREFIX=${RISCV_PREFIX:-riscv32-unknown-elf-}
CLK_HZ=${CLK_HZ:-50000000}
BAUD=${BAUD:-9600}

# Must match BOOT_BYTES in fpga/zc702/rtl/mem_bridge.sv.
BOOT_BYTES=4096

CFLAGS=(-march=rv32ima_zicsr -mabi=ilp32 -mno-relax -nostdlib -nostartfiles
        -DCLK_HZ="$CLK_HZ" -DBAUD="$BAUD" -I "$SW")

# ---- boot program -> boot RAM image --------------------------------------
echo "[INFO] Assembling boot.S (CLK_HZ=$CLK_HZ, BAUD=$BAUD)..."
# tb/core/common/link.ld places .text.start at address 0 (RESET_PC).
"${RISCV_PREFIX}gcc" "${CFLAGS[@]}" \
    -T tb/core/common/link.ld \
    -o "$OUT_DIR/boot.elf" "$SW/boot.S"

"${RISCV_PREFIX}objdump" -d "$OUT_DIR/boot.elf" > "$OUT_DIR/boot.dis"
"${RISCV_PREFIX}objcopy" -O binary "$OUT_DIR/boot.elf" "$OUT_DIR/boot.bin"
truncate -s %4 "$OUT_DIR/boot.bin"   # pad to a whole number of words

SIZE=$(stat -c %s "$OUT_DIR/boot.bin")
if [ "$SIZE" -gt "$BOOT_BYTES" ]; then
    echo "[FAIL] boot program is $SIZE bytes, boot RAM is $BOOT_BYTES bytes" >&2
    exit 1
fi

# od prints each 4-byte group as one host-endian (little-endian) word, which
# is the value the core expects at that word address.
od -An -v -tx4 -w4 "$OUT_DIR/boot.bin" | tr -d ' ' > "$OUT_DIR/boot.mem"
echo "[PASS] $OUT_DIR/boot.mem ($SIZE bytes, $((SIZE / 4)) words)"

# ---- hello program -> DDR image --------------------------------------------
echo "[INFO] Assembling hello.S for DDR at 0x80000000..."
"${RISCV_PREFIX}gcc" "${CFLAGS[@]}" \
    -T "$SW/ram.ld" \
    -o "$OUT_DIR/hello.elf" "$SW/hello.S"

"${RISCV_PREFIX}objdump" -d "$OUT_DIR/hello.elf" > "$OUT_DIR/hello.dis"
"${RISCV_PREFIX}objcopy" -O binary "$OUT_DIR/hello.elf" "$OUT_DIR/hello.bin"
truncate -s %4 "$OUT_DIR/hello.bin"
# RAM-relative addresses: the simulation's image array starts at RAM_BASE.
"${RISCV_PREFIX}objcopy" -O verilog --change-addresses -0x80000000 \
    "$OUT_DIR/hello.elf" "$OUT_DIR/hello.vh"
echo "[PASS] $OUT_DIR/hello.bin ($(stat -c %s "$OUT_DIR/hello.bin") bytes)"
