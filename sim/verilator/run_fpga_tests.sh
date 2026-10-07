#!/usr/bin/env bash
# ==========================================================
# sim/verilator/run_fpga_tests.sh
# Simulates the FPGA-side logic under fpga/ that does not need
# vendor primitives, against tb/fpga/axi_ram_model.sv standing in
# for the Zynq PS's AXI port and DDR.
#
# Currently: the DDR test (tb/fpga/ddr_test_tb.sv), once normally
# and once with a corrupted word that the test must detect.
#
# Usage:
#   sim/verilator/run_fpga_tests.sh
#
# Run from the project root.
# ==========================================================

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

BUILD_DIR="$ROOT/sim/verilator/obj_dir_fpga"
mkdir -p "$BUILD_DIR"

echo "[INFO] Building Verilator model for ddr_test_tb..."
verilator --binary --timing -Wno-fatal \
    -Mdir "$BUILD_DIR/ddr_test" \
    --top-module ddr_test_tb \
    fpga/zc702/rtl/hp_axi_master.sv \
    fpga/zc702/ddr_test/ddr_test_core.sv \
    tb/fpga/axi_ram_model.sv \
    tb/soc/uart_rx_monitor.sv \
    tb/fpga/ddr_test_tb.sv

BIN="$BUILD_DIR/ddr_test/Vddr_test_tb"

FAIL=0
echo "---- ddr_test: clean memory ----"
if ! "$BIN" ${SIM_ARGS:-}; then
    FAIL=1
fi
echo "---- ddr_test: injected fault ----"
if ! "$BIN" +FAULT ${SIM_ARGS:-}; then
    FAIL=1
fi

if [ "$FAIL" -ne 0 ]; then
    echo "[FAIL] one or more FPGA-logic tests failed"
    exit 1
fi
echo "[PASS] all FPGA-logic tests passed"
