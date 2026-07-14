#!/usr/bin/env bash
# ==========================================================
# sim/icarus/run_core_tests.sh
# Compile tb/core/core_tb.sv (core_top + behavioral memory) with
# Icarus Verilog and run every directed program under
# tb/core/programs against it.
#
# RTL source list is read straight out of sim/verilator/rtl.f
# (skipping vlog-only switches) so there's a single place that
# defines "what's in the core" shared across simulators.
#
# Usage:
#   sim/icarus/run_core_tests.sh                # run everything
#   sim/icarus/run_core_tests.sh prog1.S prog2.S # run a subset
#
# Run from the project root.
# ==========================================================

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

BUILD_DIR="$ROOT/sim/icarus/obj_dir"
PROG_OUT="$ROOT/sim/icarus/progs"
mkdir -p "$BUILD_DIR" "$PROG_OUT"

# ----------------------------------------------------------
# Pull RTL file list out of sim/verilator/rtl.f (lines starting
# with rtl/, glob-expanded), so it can't drift from the
# Verilator/Questa file lists.
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

if [ "$#" -gt 0 ]; then
    PROGS=("$@")
else
    PROGS=(tb/core/programs/*.S)
fi

FAIL=0
for SRC in "${PROGS[@]}"; do
    HEX=$(sim/verilator/build_prog.sh "$SRC" "$PROG_OUT")
    echo "---- $SRC ----"
    if ! vvp "$BIN" +HEXFILE="$HEX"; then
        FAIL=1
    fi
done

if [ "$FAIL" -ne 0 ]; then
    echo "[FAIL] one or more core tests failed"
    exit 1
fi
echo "[PASS] all core tests passed"
