#!/usr/bin/env bash
# ==========================================================
# sim/verilator/run_soc_tests.sh
# Build the Verilator model for tb/soc/soc_tb.sv (soc_top +
# behavioral RAM) and run every directed program under
# tb/soc/programs against it. soc_top wires core_top through
# the real data_bus interconnect to an actual clint peripheral,
# so these tests exercise the CLINT/interrupt path end-to-end
# (as opposed to tb/core/core_tb.sv's core-only tests, which
# always tie mtip=0).
#
# RTL source list is read straight out of sim/verilator/rtl.f
# (skipping vlog-only switches), same as run_core_tests.sh.
#
# Usage:
#   sim/verilator/run_soc_tests.sh                # run everything
#   sim/verilator/run_soc_tests.sh prog1.S prog2.S # run a subset
#
# Run from the project root.
# ==========================================================

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

BUILD_DIR="$ROOT/sim/verilator/obj_dir_soc"
PROG_OUT="$ROOT/sim/verilator/soc_progs"
mkdir -p "$PROG_OUT"

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
    --top-module soc_tb \
    "${RTL_FILES[@]}" \
    tb/soc/soc_tb.sv

BIN="$BUILD_DIR/Vsoc_tb"

if [ "$#" -gt 0 ]; then
    PROGS=("$@")
else
    PROGS=(tb/soc/programs/*.S)
fi

FAIL=0
for SRC in "${PROGS[@]}"; do
    HEX=$(sim/verilator/build_prog.sh "$SRC" "$PROG_OUT")
    echo "---- $SRC ----"
    if ! "$BIN" +HEXFILE="$HEX"; then
        FAIL=1
    fi
done

if [ "$FAIL" -ne 0 ]; then
    echo "[FAIL] one or more soc tests failed"
    exit 1
fi
echo "[PASS] all soc tests passed"
