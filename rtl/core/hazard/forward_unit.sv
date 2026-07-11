// =============================================================================
// rtl/core/hazard/forward_unit.sv
// =============================================================================
// EX-stage operand forwarding select.
// - EX/MEM has priority over MEM/WB (most recent producer wins).
// - x0 never forwards (it is never actually written).
// =============================================================================

`timescale 1ns / 1ps

module forward_unit (
    input core_pkg::reg_addr_t id_ex_rs1_addr,
    input core_pkg::reg_addr_t id_ex_rs2_addr,

    input core_pkg::reg_addr_t ex_mem_rd,
    input logic                ex_mem_rd_we,
    input logic                ex_mem_valid,

    input core_pkg::reg_addr_t mem_wb_rd,
    input logic                mem_wb_rd_we,
    input logic                mem_wb_valid,

    output core_pkg::fwd_sel_e fwd_a_sel,
    output core_pkg::fwd_sel_e fwd_b_sel
);

  import core_pkg::*;

  always_comb begin
    if (ex_mem_valid && ex_mem_rd_we && (ex_mem_rd != '0) && (ex_mem_rd == id_ex_rs1_addr))
      fwd_a_sel = FWD_EX_MEM;
    else if (mem_wb_valid && mem_wb_rd_we && (mem_wb_rd != '0) && (mem_wb_rd == id_ex_rs1_addr))
      fwd_a_sel = FWD_MEM_WB;
    else fwd_a_sel = FWD_NONE;

    if (ex_mem_valid && ex_mem_rd_we && (ex_mem_rd != '0) && (ex_mem_rd == id_ex_rs2_addr))
      fwd_b_sel = FWD_EX_MEM;
    else if (mem_wb_valid && mem_wb_rd_we && (mem_wb_rd != '0) && (mem_wb_rd == id_ex_rs2_addr))
      fwd_b_sel = FWD_MEM_WB;
    else fwd_b_sel = FWD_NONE;
  end

endmodule
