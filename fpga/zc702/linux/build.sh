#!/usr/bin/env bash
# ==========================================================
# fpga/zc702/linux/build.sh
# Compiles the ZC702 device tree (yoctorv32_zc702.dts) to the blob the
# kernel is given on the board. The kernel itself is remu's prebuilt
# remu/resources/kernel/Image, the same one the simulation boots.
#
# Needs `dtc` (device-tree-compiler) on PATH.
#
# Usage (from anywhere):
#   fpga/zc702/linux/build.sh
#   OUT_DIR=/some/dir fpga/zc702/linux/build.sh   # default: fpga/zc702/build
#
# Outputs, in OUT_DIR:
#   yoctorv32_zc702.dtb   device tree blob, loaded at 0x81000000
# ==========================================================

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT"

OUT_DIR=${OUT_DIR:-$ROOT/fpga/zc702/build}
mkdir -p "$OUT_DIR"

dtc -I dts -O dtb fpga/zc702/linux/yoctorv32_zc702.dts -o "$OUT_DIR/yoctorv32_zc702.dtb"

echo "[PASS] $OUT_DIR/yoctorv32_zc702.dtb ($(stat -c %s "$OUT_DIR/yoctorv32_zc702.dtb") bytes)"
