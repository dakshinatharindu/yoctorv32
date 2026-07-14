#!/usr/bin/env bash
# ==========================================================
# sim/verilator/run_riscv_tests.sh
# Build the Verilator model for tb/core/core_tb.sv (core_top +
# behavioral memory) and run the official riscv-tests ISA suite
# (vendored under tb/riscv-tests-env/riscv-tests) against it.
#
# RTL source list is read straight out of sim/verilator/rtl.f, same
# as sim/verilator/run_core_tests.sh (no core RTL is specific to
# this suite). Kept as a separate script since the source tree,
# include paths, and -march flags differ from the hand-written
# directed tests in tb/core/programs.
#
# See tb/riscv-tests-env/riscv-tests/NOTICE.md for exactly what's
# vendored, the pinned upstream commit, and why 6 tests are excluded
# below.
#
# Usage:
#   sim/verilator/run_riscv_tests.sh                # run every manifested test
#
# Run from the project root.
# ==========================================================

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

BUILD_DIR="$ROOT/sim/verilator/obj_dir"
PROG_OUT="$ROOT/sim/verilator/riscv-tests-progs"
mkdir -p "$PROG_OUT"

RISCV_PREFIX=${RISCV_PREFIX:-riscv32-unknown-elf-}
ENV_DIR="$ROOT/tb/riscv-tests-env"
TESTS_DIR="$ENV_DIR/riscv-tests"

# tb/riscv-tests-env/link.ld places .tohost at 0x3000; core_tb.sv's
# TOHOST_ADDR defaults to 0x1000, so this suite must override it.
TOHOST_ADDR=3000

# ----------------------------------------------------------
# Test manifest: extension dir -> test names.
#
# rv32ui: all of upstream's rv32ui_sc_tests except ma_data (this core
#   traps on misaligned load/store by design instead of supporting it
#   transparently -- see tb/riscv-tests-env/riscv-tests/NOTICE.md).
# rv32um: all 8.
# rv32ua: all 10.
# rv32mi: 11 of upstream's 16 -- excluded: breakpoint, zicntr,
#   instret_overflow, ma_fetch, pmpaddr (each needs a feature this core
#   doesn't implement: debug/trigger module, cycle/instret counters,
#   misaligned-instruction-fetch trap, or real PMP enforcement --
#   see tb/riscv-tests-env/riscv-tests/NOTICE.md for the full rationale).
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
# Build the Verilator model (same RTL file list as run_core_tests.sh).
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

echo "[INFO] Building Verilator model (${#RTL_FILES[@]} RTL files)..."
verilator --binary --timing -Wno-fatal \
    -Mdir "$BUILD_DIR" \
    --top-module core_tb \
    "${RTL_FILES[@]}" \
    tb/core/core_tb.sv

BIN="$BUILD_DIR/Vcore_tb"

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
    if ! "$BIN" +HEXFILE="$hex" +TOHOST_ADDR=$TOHOST_ADDR; then
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
