#!/usr/bin/env bash
# ==========================================================
# sim/verilator/run_fpga_tests.sh
# Simulates the FPGA-side logic under fpga/ that does not need
# vendor primitives, against tb/fpga/axi_ram_model.sv standing in
# for the Zynq PS's AXI port and DDR.
#
#   1. DDR test (tb/fpga/ddr_test_tb.sv): once normally and once
#      with a corrupted word that the test must detect.
#   2. DDR-backed SoC (tb/fpga/soc_ddr_tb.sv: soc_top behind the
#      memory bridge and AXI master):
#        - the riscv-tests suite, relinked at 0x80000000 so every
#          instruction and data access goes through the bridge
#        - the FPGA boot program starting the DDR hello program,
#          with a byte typed at it
#        - the boot program with nothing loaded in DDR
#        - hello again, with resets fired at random moments
#
# Usage:
#   sim/verilator/run_fpga_tests.sh
#
# Extra simulator plusargs can be passed through SIM_ARGS, e.g. a
# different random seed or AXI timing (see tb/fpga/axi_ram_model.sv):
#   SIM_ARGS="+verilator+seed+7 +AXI_MAX_DELAY=12" sim/verilator/run_fpga_tests.sh
#
# Run from the project root.
# ==========================================================

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

BUILD_DIR="$ROOT/sim/verilator/obj_dir_fpga"
PROG_OUT="$ROOT/sim/verilator/fpga_progs"
mkdir -p "$BUILD_DIR" "$PROG_OUT"

RISCV_PREFIX=${RISCV_PREFIX:-riscv32-unknown-elf-}
ENV_DIR="$ROOT/tb/riscv-tests-env"
TESTS_DIR="$ENV_DIR/riscv-tests"

FAIL=0

# ----------------------------------------------------------
# 1. DDR test
# ----------------------------------------------------------
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

echo "---- ddr_test: clean memory ----"
if ! "$BIN" ${SIM_ARGS:-}; then
    FAIL=1
fi
echo "---- ddr_test: injected fault ----"
if ! "$BIN" +FAULT ${SIM_ARGS:-}; then
    FAIL=1
fi

# ----------------------------------------------------------
# 2. DDR-backed SoC
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

echo "[INFO] Building Verilator model for soc_ddr_tb (${#RTL_FILES[@]} RTL files)..."
verilator --binary --timing -Wno-fatal \
    -Mdir "$BUILD_DIR/soc_ddr" \
    --top-module soc_ddr_tb \
    "${RTL_FILES[@]}" \
    fpga/zc702/rtl/hp_axi_master.sv \
    fpga/zc702/rtl/mem_bridge.sv \
    fpga/zc702/rtl/soc_ddr.sv \
    tb/fpga/axi_ram_model.sv \
    tb/soc/uart_rx_monitor.sv \
    tb/soc/uart_tx_injector.sv \
    tb/fpga/soc_ddr_tb.sv

BIN="$BUILD_DIR/soc_ddr/Vsoc_ddr_tb"

# Boot-RAM images are 32-bit words, one per line, like the bitstream build's.
to_word_mem() {
    local elf="$1" mem="$2"
    "${RISCV_PREFIX}objcopy" -O binary "$elf" "$mem.bin"
    truncate -s %4 "$mem.bin"
    od -An -v -tx4 -w4 "$mem.bin" | tr -d ' ' > "$mem"
}

# ---- riscv-tests through the bridge ----
"${RISCV_PREFIX}gcc" -march=rv32ima_zicsr -mabi=ilp32 -mno-relax \
    -nostdlib -nostartfiles -T tb/core/common/link.ld \
    -o "$PROG_OUT/jump_to_ram.elf" tb/fpga/jump_to_ram.S
to_word_mem "$PROG_OUT/jump_to_ram.elf" "$PROG_OUT/jump_to_ram.mem"

# Same manifest as run_riscv_tests.sh, read from it so the two cannot drift.
eval "$(awk '/^RV32(UI|UM|UA|MI)_TESTS=/{p=1} p{print} p&&/"$/{p=0}' sim/verilator/run_riscv_tests.sh)"
if [ -z "${RV32UI_TESTS:-}" ] || [ -z "${RV32MI_TESTS:-}" ]; then
    echo "[FAIL] could not read the test manifest from run_riscv_tests.sh" >&2
    exit 1
fi

RUN_COUNT=0
run_riscv() {
    local ext="$1" name="$2"
    local src="$TESTS_DIR/isa/$ext/$name.S"
    local elf="$PROG_OUT/${ext}-p-${name}.elf"
    local hex="$PROG_OUT/${ext}-p-${name}.vh"

    "${RISCV_PREFIX}gcc" \
        -march=rv32ima_zicsr_zifencei -mabi=ilp32 -mno-relax \
        -nostdlib -nostartfiles \
        -T tb/fpga/riscv-tests-ram.ld \
        -I "$TESTS_DIR/env/p" \
        -I "$TESTS_DIR/isa/macros/scalar" \
        -o "$elf" "$src"
    "${RISCV_PREFIX}objcopy" -O verilog --change-addresses -0x80000000 "$elf" "$hex"

    echo "---- soc_ddr: ${ext}-p-${name} ----"
    RUN_COUNT=$((RUN_COUNT + 1))
    if ! "$BIN" +BOOT="$PROG_OUT/jump_to_ram.mem" +DDR0="$hex" +TOHOST_ADDR=80003000 ${SIM_ARGS:-}; then
        FAIL=1
    fi
}

for name in $RV32UI_TESTS; do run_riscv rv32ui "$name"; done
for name in $RV32UM_TESTS; do run_riscv rv32um "$name"; done
for name in $RV32UA_TESTS; do run_riscv rv32ua "$name"; done
for name in $RV32MI_TESTS; do run_riscv rv32mi "$name"; done
echo "[INFO] ran $RUN_COUNT riscv-tests through the bridge"

# ---- boot program + hello, built for the simulation's fast UART ----
# CLK_HZ = 16 * BAUD gives divisor 1 = 16 clocks per bit, which is what the
# testbench's UART monitor expects by default.
OUT_DIR="$PROG_OUT" CLK_HZ=153600 BAUD=9600 fpga/zc702/sw/boot/build.sh > /dev/null
OUT_DIR="$PROG_OUT" CLK_HZ=153600 BAUD=9600 fpga/zc702/sw/hello/build.sh > /dev/null

# check_run <label> <expected text> <simulator args...>: run and require the
# simulator to succeed and the decoded UART output to contain the text.
check_run() {
    local label="$1" expect="$2"
    shift 2
    echo "---- soc_ddr: $label ----"
    local out
    if ! out=$("$BIN" "$@" ${SIM_ARGS:-} 2>&1); then
        echo "$out"
        FAIL=1
        return
    fi
    echo "$out" | tr -d '\r' | grep -av '^- '
    if ! echo "$out" | grep -aqF "$expect"; then
        echo "soc_ddr: FAIL expected UART output not found: $expect"
        FAIL=1
    fi
}

# Boot banner (18 bytes) + "image found" line (34) + hello banner (88) = 140,
# then one typed byte echoed back.
check_run "boot + hello from DDR, with echo" "it will be echoed:" \
    +BOOT="$PROG_OUT/boot.mem" +DDR0="$PROG_OUT/hello_ddr.vh" \
    +INJECT_AT_BYTES=140 +INJECT_BYTE=5A +FINISH_UART_BYTES=141

# Nothing in DDR: banner (18) + message (56) + found word (8) + hint (41) = 123.
check_run "boot with no image loaded" "found 00000000" \
    +BOOT="$PROG_OUT/boot.mem" +FINISH_UART_BYTES=123

check_run "hello from DDR, resets at random moments" "it will be echoed:" \
    +BOOT="$PROG_OUT/boot.mem" +DDR0="$PROG_OUT/hello_ddr.vh" \
    +RESET_COUNT=12 +RESET_EVERY=3000 \
    +INJECT_AT_BYTES=140 +INJECT_BYTE=5A +FINISH_UART_BYTES=141 +MAX_CYCLES=20000000

if [ "$FAIL" -ne 0 ]; then
    echo "[FAIL] one or more FPGA-logic tests failed"
    exit 1
fi
echo "[PASS] all FPGA-logic tests passed"
