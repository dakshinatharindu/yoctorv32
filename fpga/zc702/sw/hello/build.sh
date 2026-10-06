#!/usr/bin/env bash
# ==========================================================
# fpga/zc702/sw/hello/build.sh
# Builds the milestone 1 bare-metal program and converts it to the block-RAM
# init file fpga_top.sv loads: one 32-bit little-endian word per line, for
# $readmemh. Run this before fpga/zc702/scripts/build.tcl.
#
# Needs the RISC-V toolchain (riscv32-unknown-elf- on PATH, as in the dev
# container; override with RISCV_PREFIX).
#
# Usage (from anywhere):
#   fpga/zc702/sw/hello/build.sh
#   CLK_HZ=40000000 fpga/zc702/sw/hello/build.sh   # if fpga_top's clock changes
#
# Outputs, in fpga/zc702/build/:
#   hello.mem   block-RAM init file
#   hello.elf   linked program
#   hello.dis   disassembly, for reference
# ==========================================================

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
cd "$ROOT"

OUT_DIR="$ROOT/fpga/zc702/build"
mkdir -p "$OUT_DIR"

RISCV_PREFIX=${RISCV_PREFIX:-riscv32-unknown-elf-}
CLK_HZ=${CLK_HZ:-50000000}
BAUD=${BAUD:-9600}

# Must match MemAddrBits in fpga/zc702/rtl/fpga_top.sv (2^14 words).
RAM_BYTES=65536

echo "[INFO] Assembling hello.S (CLK_HZ=$CLK_HZ, BAUD=$BAUD)..."
# tb/core/common/link.ld places .text.start at address 0 (RESET_PC), the same
# script the Linux boot stub is linked with.
"${RISCV_PREFIX}gcc" \
    -march=rv32ima_zicsr -mabi=ilp32 -mno-relax \
    -nostdlib -nostartfiles \
    -DCLK_HZ="$CLK_HZ" -DBAUD="$BAUD" \
    -T tb/core/common/link.ld \
    -o "$OUT_DIR/hello.elf" fpga/zc702/sw/hello/hello.S

"${RISCV_PREFIX}objdump" -d "$OUT_DIR/hello.elf" > "$OUT_DIR/hello.dis"

echo "[INFO] Converting to a word-wide \$readmemh image..."
"${RISCV_PREFIX}objcopy" -O binary "$OUT_DIR/hello.elf" "$OUT_DIR/hello.bin"
truncate -s %4 "$OUT_DIR/hello.bin"   # pad to a whole number of words

SIZE=$(stat -c %s "$OUT_DIR/hello.bin")
if [ "$SIZE" -gt "$RAM_BYTES" ]; then
    echo "[FAIL] program is $SIZE bytes, block RAM is $RAM_BYTES bytes" >&2
    exit 1
fi

# od prints each 4-byte group as one host-endian (little-endian) word, which
# is the value the core expects at that word address.
od -An -v -tx4 -w4 "$OUT_DIR/hello.bin" | tr -d ' ' > "$OUT_DIR/hello.mem"

echo "[PASS] $OUT_DIR/hello.mem ($SIZE bytes, $((SIZE / 4)) words)"
