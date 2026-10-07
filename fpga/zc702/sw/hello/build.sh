#!/usr/bin/env bash
# ==========================================================
# fpga/zc702/sw/hello/build.sh
# Builds the bare-metal hello program in both of its forms:
#
#   hello.mem       milestone 1 image for the block RAM in fpga_top.sv: one
#                   32-bit little-endian word per line, for $readmemh. Run
#                   this before fpga/zc702/scripts/build.tcl.
#   hello_ddr.bin   milestone 2 image linked at 0x80000000, to be loaded into
#                   PS DDR over JTAG (fpga/zc702/scripts/run_ddr.tcl).
#   hello_ddr.vh    the same as byte-wide Verilog hex with RAM-relative
#                   addresses, for simulation (tb/fpga/soc_ddr_tb.sv).
#
# Needs the RISC-V toolchain (riscv32-unknown-elf- on PATH, as in the dev
# container; override with RISCV_PREFIX).
#
# Usage (from anywhere):
#   fpga/zc702/sw/hello/build.sh
#   CLK_HZ=40000000 fpga/zc702/sw/hello/build.sh   # if the FPGA clock changes
#   OUT_DIR=/some/dir fpga/zc702/sw/hello/build.sh  # default: fpga/zc702/build
#
# Also written next to the images: .elf and .dis (disassembly) of each.
# ==========================================================

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
cd "$ROOT"

OUT_DIR=${OUT_DIR:-$ROOT/fpga/zc702/build}
mkdir -p "$OUT_DIR"

RISCV_PREFIX=${RISCV_PREFIX:-riscv32-unknown-elf-}
CLK_HZ=${CLK_HZ:-50000000}
BAUD=${BAUD:-9600}

# Must match MemAddrBits in fpga/zc702/rtl/fpga_top.sv (2^14 words).
RAM_BYTES=65536

CFLAGS=(-march=rv32ima_zicsr -mabi=ilp32 -mno-relax -nostdlib -nostartfiles
        -DCLK_HZ="$CLK_HZ" -DBAUD="$BAUD" -I fpga/zc702/sw/common)

# ---- block RAM build ---------------------------------------------------
echo "[INFO] Assembling hello.S for block RAM (CLK_HZ=$CLK_HZ, BAUD=$BAUD)..."
# tb/core/common/link.ld places .text.start at address 0 (RESET_PC), the same
# script the Linux boot stub is linked with.
"${RISCV_PREFIX}gcc" "${CFLAGS[@]}" \
    -T tb/core/common/link.ld \
    -o "$OUT_DIR/hello.elf" fpga/zc702/sw/hello/hello.S

"${RISCV_PREFIX}objdump" -d "$OUT_DIR/hello.elf" > "$OUT_DIR/hello.dis"
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

# ---- DDR build ---------------------------------------------------------
echo "[INFO] Assembling hello.S for DDR at 0x80000000..."
"${RISCV_PREFIX}gcc" "${CFLAGS[@]}" -DDDR_IMAGE \
    -T fpga/zc702/sw/common/ram.ld \
    -o "$OUT_DIR/hello_ddr.elf" fpga/zc702/sw/hello/hello.S

"${RISCV_PREFIX}objdump" -d "$OUT_DIR/hello_ddr.elf" > "$OUT_DIR/hello_ddr.dis"
"${RISCV_PREFIX}objcopy" -O binary "$OUT_DIR/hello_ddr.elf" "$OUT_DIR/hello_ddr.bin"
truncate -s %4 "$OUT_DIR/hello_ddr.bin"
# RAM-relative addresses: the simulation's image array starts at RAM_BASE.
"${RISCV_PREFIX}objcopy" -O verilog --change-addresses -0x80000000 \
    "$OUT_DIR/hello_ddr.elf" "$OUT_DIR/hello_ddr.vh"
echo "[PASS] $OUT_DIR/hello_ddr.bin ($(stat -c %s "$OUT_DIR/hello_ddr.bin") bytes)"
