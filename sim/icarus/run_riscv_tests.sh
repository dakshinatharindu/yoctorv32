#!/usr/bin/env bash
# ==========================================================
# sim/icarus/run_riscv_tests.sh
# Compile tb/core/core_tb.sv (core_top + behavioral memory) with
# Icarus Verilog and run the official riscv-tests ISA suite
# (vendored under tb/riscv-tests-env/riscv-tests) against it.
#
# RTL source list is read straight out of sim/verilator/rtl.f, same
# as sim/icarus/run_core_tests.sh (no core RTL is specific to
# this suite, and it must stay identical across simulators).
#
# See tb/riscv-tests-env/riscv-tests/NOTICE.md for exactly what's
# vendored, the pinned upstream commit, and why some tests are
# excluded below (same rationale as the Verilator runner).
#
# Usage:
#   sim/icarus/run_riscv_tests.sh                # run every manifested test
#
# Run from the project root.
# ==========================================================

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

BUILD_DIR="$ROOT/sim/icarus/obj_dir"
PROG_OUT="$ROOT/sim/icarus/riscv-tests-progs"
mkdir -p "$BUILD_DIR" "$PROG_OUT"

RISCV_PREFIX=${RISCV_PREFIX:-riscv32-unknown-elf-}
ENV_DIR="$ROOT/tb/riscv-tests-env"
TESTS_DIR="$ENV_DIR/riscv-tests"

# tb/riscv-tests-env/link.ld places .tohost at 0x3000; core_tb.sv's
# TOHOST_ADDR defaults to 0x1000, so this suite must override it.
TOHOST_ADDR=3000

# ----------------------------------------------------------
# Test manifest: extension dir -> test names. Kept identical to
# sim/verilator/run_riscv_tests.sh -- see that script for the
# per-exclusion rationale.
# ----------------------------------------------------------
RV32UI_TESTS="simple add addi and andi auipc beq bge bgeu blt bltu bne \
fence_i jal jalr lb lbu lh lhu lw ld_st lui or ori sb sh sw st_ld \
sll slli slt slti sltiu sltu sra srai srl srli sub xor xori"

RV32UM_TESTS="div divu mul mulh mulhsu mulhu rem remu"

RV32UA_TESTS="amoadd_w amoand_w amomax_w amomaxu_w amomin_w amominu_w \
amoor_w amoxor_w amoswap_w lrsc"

RV32MI_TESTS="csr mcsr illegal ma_addr scall sbreak shamt \
lw-misaligned lh-misaligned sh-misaligned sw-misaligned"

# ----------------------------------------------------------
# Build the Icarus model (same RTL file list as run_core_tests.sh).
# ----------------------------------------------------------
RTL_FILES=()
while IFS= read -r line; do
    line="${line%%#*}"
    line="$(echo "$line" | xargs || true)"
    [ -z "$line" ] && continue
    case "$line" in
        rtl/*)
            for f in $line; do
                RTL_FILES+=("$f")
            done
            ;;
    esac
done < sim/verilator/rtl.f

echo "[INFO] Building Icarus model (${#RTL_FILES[@]} RTL files)..."
BIN="$BUILD_DIR/core_tb.vvp"
iverilog -g2012 -Wall -Wno-timescale \
    -o "$BIN" \
    "${RTL_FILES[@]}" \
    tb/core/core_tb.sv

# ----------------------------------------------------------
# Compile + run each manifested test.
# ----------------------------------------------------------
FAIL=0
RUN_COUNT=0

run_one() {
    local ext="$1" name="$2"
    local src="$TESTS_DIR/isa/$ext/$name.S"
    local elf="$PROG_OUT/${ext}-p-${name}.elf"
    local hex="$PROG_OUT/${ext}-p-${name}.vh"

    "${RISCV_PREFIX}gcc" \
        -march=rv32ima_zicsr_zifencei -mabi=ilp32 -mno-relax \
        -nostdlib -nostartfiles \
        -T "$ENV_DIR/link.ld" \
        -I "$TESTS_DIR/env/p" \
        -I "$TESTS_DIR/isa/macros/scalar" \
        -o "$elf" "$src"
    "${RISCV_PREFIX}objcopy" -O verilog "$elf" "$hex"

    echo "---- ${ext}-p-${name} ----"
    RUN_COUNT=$((RUN_COUNT + 1))
    if ! vvp "$BIN" +HEXFILE="$hex" +TOHOST_ADDR=$TOHOST_ADDR; then
        FAIL=1
    fi
}

for name in $RV32UI_TESTS; do run_one rv32ui "$name"; done
for name in $RV32UM_TESTS; do run_one rv32um "$name"; done
for name in $RV32UA_TESTS; do run_one rv32ua "$name"; done
for name in $RV32MI_TESTS; do run_one rv32mi "$name"; done

echo "[INFO] ran $RUN_COUNT tests"
if [ "$FAIL" -ne 0 ]; then
    echo "[FAIL] one or more riscv-tests failed"
    exit 1
fi
echo "[PASS] all riscv-tests passed"
