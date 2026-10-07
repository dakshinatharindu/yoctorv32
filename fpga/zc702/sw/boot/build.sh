#!/usr/bin/env bash
# ==========================================================
# fpga/zc702/sw/boot/build.sh
# Builds the boot program for the DDR-backed SoC and converts it to the
# boot-RAM init file fpga/zc702/rtl/mem_bridge.sv loads: one 32-bit
# little-endian word per line, for $readmemh. Run this before
# fpga/zc702/scripts/build_ddr.tcl; the image is built into the bitstream.
#
# Needs the RISC-V toolchain (riscv32-unknown-elf- on PATH, as in the dev
# container; override with RISCV_PREFIX).
#
# Usage (from anywhere):
#   fpga/zc702/sw/boot/build.sh
#   CLK_HZ=40000000 fpga/zc702/sw/boot/build.sh    # if the FPGA clock changes
#   OUT_DIR=/some/dir fpga/zc702/sw/boot/build.sh   # default: fpga/zc702/build
#
# Outputs, in OUT_DIR:
#   boot.mem   boot-RAM init file
#   boot.elf   linked program
#   boot.dis   disassembly, for reference
# ==========================================================

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
cd "$ROOT"

OUT_DIR=${OUT_DIR:-$ROOT/fpga/zc702/build}
mkdir -p "$OUT_DIR"

RISCV_PREFIX=${RISCV_PREFIX:-riscv32-unknown-elf-}
CLK_HZ=${CLK_HZ:-50000000}
BAUD=${BAUD:-9600}

# Must match BOOT_BYTES in fpga/zc702/rtl/mem_bridge.sv.
BOOT_BYTES=4096

echo "[INFO] Assembling boot.S (CLK_HZ=$CLK_HZ, BAUD=$BAUD)..."
# tb/core/common/link.ld places .text.start at address 0 (RESET_PC).
"${RISCV_PREFIX}gcc" \
    -march=rv32ima_zicsr -mabi=ilp32 -mno-relax \
    -nostdlib -nostartfiles \
    -DCLK_HZ="$CLK_HZ" -DBAUD="$BAUD" -I fpga/zc702/sw/common \
    -T tb/core/common/link.ld \
    -o "$OUT_DIR/boot.elf" fpga/zc702/sw/boot/boot.S

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
