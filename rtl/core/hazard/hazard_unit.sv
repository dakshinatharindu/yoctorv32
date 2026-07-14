// =============================================================================
// rtl/core/hazard/hazard_unit.sv
// =============================================================================
// Detects load-use hazards and branch/jump mispredicts, and generates the
// stall/flush controls for the pipeline registers.
//
// Load-use hazard: the instruction currently in EX (ID/EX) is a load or a
// CSR read whose destination is needed (as rs1 or rs2) by the instruction
// currently being decoded (IF/ID). Both loads and CSR reads produce their
// result in the MEM stage (lsu/csr), one stage later than a normal ALU op,
// so the EX/MEM forwarding path (which only carries alu_result) cannot
// supply it to an immediately-following consumer — resolved by stalling
// PC/IF-ID for one cycle and bubbling ID/EX; the value is then available
// via MEM/WB forwarding.
//
// Branch/jump mispredict: resolved combinationally in EX. Squashes the
// instruction currently in ID (about to enter ID/EX) and the one currently
// being fetched (about to enter IF/ID), and redirects the PC.
// =============================================================================

`timescale 1ns / 1ps

module hazard_unit (
    // State of the instruction currently in ID/EX (EX stage)
    input logic                id_ex_mem_rd,
    input logic                id_ex_csr_en,
    input core_pkg::reg_addr_t id_ex_rd,
    input logic                id_ex_valid,

    // State of the instruction currently in IF/ID (ID stage)
    input core_pkg::reg_addr_t if_id_rs1_addr,
    input core_pkg::reg_addr_t if_id_rs2_addr,
    input logic                if_id_uses_rs1,
    input logic                if_id_uses_rs2,

    // Branch/jump resolution from EX stage
    input logic branch_taken,

    // RV32M: divider busy in EX (structural hazard — id_ex_q must hold the
    // DIV/REM instruction in place, not advance to a bubble like a
    // load-use hazard does).
    input logic ex_div_stall,

    // Trap/MRET redirect from csr.sv (MEM stage) — an older instruction
    // than anything currently in IF/ID/EX, so it must squash all three.
    input logic sys_redirect,

    output logic pc_stall,
    output logic if_id_stall,
    output logic if_id_flush,
    output logic id_ex_flush,
    output logic id_ex_stall,
    output logic ex_mem_flush
);

  logic load_use_hazard;

  assign load_use_hazard = id_ex_valid && (id_ex_mem_rd || id_ex_csr_en) && (id_ex_rd != '0) &&
      ((if_id_uses_rs1 && (if_id_rs1_addr == id_ex_rd)) ||
       (if_id_uses_rs2 && (if_id_rs2_addr == id_ex_rd)));

  assign pc_stall    = load_use_hazard || ex_div_stall;
  assign if_id_stall = load_use_hazard || ex_div_stall;

  assign if_id_flush = branch_taken || sys_redirect;
  assign id_ex_flush = load_use_hazard || branch_taken || sys_redirect;

  // Not OR'd with load_use_hazard: load-use needs id_ex_q to advance to a
  // bubble while the load proceeds into EX; div-stall needs id_ex_q to hold
  // the same DIV/REM instruction in place. These are different remedies.
  assign id_ex_stall = ex_div_stall;

  // A MEM-stage trap/MRET redirect is strictly older than whatever is
  // currently in ex_mem_q's producing instruction (id_ex_q, this cycle's EX
  // instruction) — that instruction must never reach MEM/WB.
  assign ex_mem_flush = sys_redirect;

endmodule
