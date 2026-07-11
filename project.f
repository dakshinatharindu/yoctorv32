// ============================================================
// project.f -- Master Filelist for RV32IMA Verilog Project
// Root-level filelist for extension discovery
// ============================================================

// Compile options
-sv
+acc
-timescale 1ns/1ps

// ============================================================
// PACKAGES (MUST COME FIRST)
// ============================================================
rtl/core/core_pkg.sv

// ============================================================
// CORE MODULES
// ============================================================

// Register File
rtl/core/regfile/regfile.sv

// Instruction Fetch
rtl/core/ifetch/ifetch.sv

// Decode Stage
rtl/core/decode/decode.sv
rtl/core/decode/imm_gen.sv

// Execute Stage
rtl/core/execute/alu.sv
rtl/core/execute/branch_unit.sv
rtl/core/execute/execute_stage.sv

// Memory Stage
rtl/core/lsu/lsu.sv

// Hazard / Forwarding
rtl/core/hazard/hazard_unit.sv
rtl/core/hazard/forward_unit.sv

// Pipeline Registers
rtl/core/pipeline/if_id_reg.sv
rtl/core/pipeline/id_ex_reg.sv
rtl/core/pipeline/ex_mem_reg.sv
rtl/core/pipeline/mem_wb_reg.sv

// Top-Level
rtl/core/core_top.sv
