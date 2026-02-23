#!/usr/bin/env bash
# ==========================================================
# run_tb.sh
# Compile full RTL + given testbench and simulate
#
# Usage:
#   ./sim/run_tb.sh tb/alu/tb_alu.sv
#
# Assumptions:
#   - rtl filelist at sim/questa/rtl.f
#   - Questa installed and in PATH
#   - Run from project root
# ==========================================================

set -e

if [ $# -ne 1 ]; then
    echo "Usage: $0 <testbench_file.sv>"
    exit 1
fi

TB_FILE=$1

if [ ! -f "$TB_FILE" ]; then
    echo "Error: Testbench file '$TB_FILE' not found."
    exit 1
fi

# ----------------------------------------------------------
# Extract top module name from TB file
# ----------------------------------------------------------
TB_TOP=$(grep -Eo 'module[[:space:]]+[a-zA-Z0-9_]+' "$TB_FILE" | head -1 | awk '{print $2}')

if [ -z "$TB_TOP" ]; then
    echo "Error: Could not detect top module name."
    exit 1
fi

echo "=============================================="
echo "Testbench file : $TB_FILE"
echo "Top module     : $TB_TOP"
echo "=============================================="

# ----------------------------------------------------------
# Clean previous work
# ----------------------------------------------------------
rm -rf work
vlib work

# ----------------------------------------------------------
# Compile RTL
# ----------------------------------------------------------
echo "[INFO] Compiling RTL..."
vlog -f sim/questa/rtl.f

# ----------------------------------------------------------
# Compile Testbench
# ----------------------------------------------------------
echo "[INFO] Compiling Testbench..."
vlog -sv "$TB_FILE"

# ----------------------------------------------------------
# Run Simulation
# ----------------------------------------------------------
echo "[INFO] Running Simulation..."
vsim -c "$TB_TOP" -do "run -all; quit -f"

echo "=============================================="
echo "Simulation completed successfully."
echo "=============================================="
