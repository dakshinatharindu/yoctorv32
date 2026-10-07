#!/usr/bin/env bash
# ==========================================================
# fpga/zc702/scripts/boot_linux.sh
# Boots Linux on the ZC702: compiles the board device tree, then
# runs run_ddr.tcl to program the FPGA, initialize the Zynq PS
# and load the kernel and device tree into DDR over JTAG, and
# release the core.
#
#   kernel       remu/resources/kernel/Image       -> 0x80000000
#   device tree  fpga/zc702/linux/yoctorv32_zc702.dts -> 0x81000000
#
# Before running: the bitstream must have been built
# (sw/boot/build.sh, then scripts/build_ddr.tcl), the board must
# be in JTAG boot mode, and a serial terminal should be open on
# the USB-UART adapter at 9600 baud to see the console.
#
# Usage (from anywhere):
#   fpga/zc702/scripts/boot_linux.sh
#
# Log in as "root" (no password) at the "buildroot login:" prompt.
# To boot again, run this script again: a kernel that has run has
# modified its image in DDR, so the reset button alone is not enough.
# ==========================================================

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT"

KERNEL="$ROOT/remu/resources/kernel/Image"
DTB="$ROOT/fpga/zc702/build/yoctorv32_zc702.dtb"

if [ ! -f "$KERNEL" ]; then
    echo "[FAIL] $KERNEL not found: run 'git submodule update --init'" >&2
    exit 1
fi

fpga/zc702/linux/build.sh

exec xsdb fpga/zc702/scripts/run_ddr.tcl "$KERNEL" 0x80000000 "$DTB" 0x81000000
