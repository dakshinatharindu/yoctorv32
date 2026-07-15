#!/usr/bin/env bash
# ==========================================================
# sim/verilator/run_linux_boot.sh
# Exploratory Linux boot attempt: reuses remu's already-built kernel
# Image (remu/resources/kernel/Image) against our own core, through
# tb/linux_boot/linux_boot_tb.sv. Unlike the other run_*.sh scripts this
# is not a pass/fail regression check — it streams decoded UART output
# live so you can watch (or grep) the boot log as it happens.
#
# Requires `dtc` (device-tree-compiler) on PATH.
#
# Usage:
#   sim/verilator/run_linux_boot.sh [+MAX_CYCLES=20000000]
#
# Run from the project root.
# ==========================================================

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

BUILD_DIR="$ROOT/sim/verilator/obj_dir_linux_boot"
OUT_DIR="$ROOT/sim/verilator/linux_boot_out"
mkdir -p "$OUT_DIR"

RISCV_PREFIX=${RISCV_PREFIX:-riscv32-unknown-elf-}

echo "[INFO] Compiling device tree..."
dtc -I dts -O dtb tb/linux_boot/yoctorv32.dts -o "$OUT_DIR/yoctorv32.dtb"

# Addresses here are RAM-relative (main_ram in linux_boot_tb.sv is a
# 0-based array, indexed by addr-RamBase), not the absolute 0x8000_0000+
# addresses the core actually sees on its bus — Verilator's $readmemh
# bounds-checking did not accept 0x8000_0000-magnitude array bounds/
# addresses in practice. Kernel loads at RAM offset 0 (no shift needed);
# DTB loads at RAM offset 0x0100_0000 (== absolute 0x8100_0000, matching
# boot_stub.S's a1).
echo "[INFO] Converting kernel Image + DTB to addressed Verilog hex..."
"${RISCV_PREFIX}objcopy" -I binary -O verilog \
    remu/resources/kernel/Image "$OUT_DIR/kernel.vh"
"${RISCV_PREFIX}objcopy" -I binary -O verilog --change-addresses 0x01000000 \
    "$OUT_DIR/yoctorv32.dtb" "$OUT_DIR/dtb.vh"

echo "[INFO] Assembling boot stub..."
BOOT_ELF="$OUT_DIR/boot_stub.elf"
BOOT_HEX="$OUT_DIR/boot_stub.vh"
"${RISCV_PREFIX}gcc" \
    -march=rv32ima_zicsr -mabi=ilp32 -mno-relax \
    -nostdlib -nostartfiles \
    -T tb/core/common/link.ld \
    -o "$BOOT_ELF" tb/linux_boot/boot_stub.S
"${RISCV_PREFIX}objcopy" -O verilog "$BOOT_ELF" "$BOOT_HEX"

echo "[INFO] Pulling RTL file list from sim/verilator/rtl.f..."
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
    --top-module linux_boot_tb \
    "${RTL_FILES[@]}" \
    tb/soc/uart_rx_monitor.sv \
    tb/linux_boot/linux_boot_tb.sv

BIN="$BUILD_DIR/Vlinux_boot_tb"

echo "[INFO] Running (this can take a while — Linux boot is a lot of cycles)..."
"$BIN" +BOOT_STUB="$BOOT_HEX" +KERNEL="$OUT_DIR/kernel.vh" +DTB="$OUT_DIR/dtb.vh" "$@"
