#!/usr/bin/env bash
# ==========================================================
# sim/verilator/run_core_tests.sh
# Build the Verilator model for tb/core/core_tb.sv (core_top +
# behavioral memory) and run every directed program under
# tb/core/programs against it.
#
# RTL source list is read straight out of sim/questa/rtl.f
# (skipping vlog-only switches) so there's a single place that
# defines "what's in the core".
#
# Usage:
#   sim/verilator/run_core_tests.sh                # run everything
#   sim/verilator/run_core_tests.sh prog1.S prog2.S # run a subset
#
# Run from the project root.
# ==========================================================

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

BUILD_DIR="$ROOT/sim/verilator/obj_dir"
PROG_OUT="$ROOT/sim/verilator/progs"
mkdir -p "$PROG_OUT"

# ----------------------------------------------------------
# Pull RTL file list out of sim/questa/rtl.f (lines starting
# with rtl/, glob-expanded), so it can't drift from Questa's.
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
done < sim/questa/rtl.f

echo "[INFO] Building Verilator model (${#RTL_FILES[@]} RTL files)..."
verilator --binary --timing -Wno-fatal \
    -Mdir "$BUILD_DIR" \
    --top-module core_tb \
    "${RTL_FILES[@]}" \
    tb/core/core_tb.sv

BIN="$BUILD_DIR/Vcore_tb"

if [ "$#" -gt 0 ]; then
    PROGS=("$@")
else
    PROGS=(tb/core/programs/*.S)
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
    echo "[FAIL] one or more core tests failed"
    exit 1
fi
echo "[PASS] all core tests passed"
