#!/usr/bin/env bash
# ==========================================================
# sim/verilator/build_prog.sh
# Assemble one directed RV32I test program (.S) into a
# Verilog $readmemh hex file core_tb.sv can load via +HEXFILE.
#
# Usage:
#   sim/verilator/build_prog.sh tb/core/programs/foo.S [out_dir]
#
# Run from the project root.
# ==========================================================

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Usage: $0 <prog.S> [out_dir]"
    exit 1
fi

SRC=$1
OUT_DIR=${2:-sim/verilator/progs}
mkdir -p "$OUT_DIR"

NAME=$(basename "$SRC" .S)
ELF="$OUT_DIR/$NAME.elf"
HEX="$OUT_DIR/$NAME.vh"

RISCV_PREFIX=${RISCV_PREFIX:-riscv32-unknown-elf-}

"${RISCV_PREFIX}gcc" \
    -march=rv32i -mabi=ilp32 -mno-relax \
    -nostdlib -nostartfiles \
    -T tb/core/common/link.ld \
    -I tb/core/common \
    -o "$ELF" "$SRC"

"${RISCV_PREFIX}objcopy" -O verilog "$ELF" "$HEX"

echo "$HEX"
