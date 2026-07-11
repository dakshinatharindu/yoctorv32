// =============================================================================
// rtl/core/hazard/hazard_unit.sv
// =============================================================================
// Detects load-use hazards and branch/jump mispredicts, and generates the
// stall/flush controls for the pipeline registers.
//
// Load-use hazard: the instruction currently in EX (ID/EX) is a load whose
// destination is needed (as rs1 or rs2) by the instruction currently being
// decoded (IF/ID). Resolved by stalling PC/IF-ID for one cycle and bubbling
// ID/EX; the value is then available via MEM/WB forwarding.
//
// Branch/jump mispredict: resolved combinationally in EX. Squashes the
// instruction currently in ID (about to enter ID/EX) and the one currently
// being fetched (about to enter IF/ID), and redirects the PC.
// =============================================================================

`timescale 1ns / 1ps

module hazard_unit (
    // State of the instruction currently in ID/EX (EX stage)
    input logic                id_ex_mem_rd,
    input core_pkg::reg_addr_t id_ex_rd,
    input logic                id_ex_valid,

    // State of the instruction currently in IF/ID (ID stage)
    input core_pkg::reg_addr_t if_id_rs1_addr,
    input core_pkg::reg_addr_t if_id_rs2_addr,
    input logic                if_id_uses_rs1,
    input logic                if_id_uses_rs2,

    // Branch/jump resolution from EX stage
    input logic branch_taken,

    output logic pc_stall,
    output logic if_id_stall,
    output logic if_id_flush,
    output logic id_ex_flush
);

  logic load_use_hazard;

  assign load_use_hazard = id_ex_valid && id_ex_mem_rd && (id_ex_rd != '0) &&
      ((if_id_uses_rs1 && (if_id_rs1_addr == id_ex_rd)) ||
       (if_id_uses_rs2 && (if_id_rs2_addr == id_ex_rd)));

  assign pc_stall    = load_use_hazard;
  assign if_id_stall = load_use_hazard;

  assign if_id_flush = branch_taken;
  assign id_ex_flush = load_use_hazard || branch_taken;

endmodule
