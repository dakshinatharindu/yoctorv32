// =============================================================================
// rtl/core/execute/execute_stage.sv
// =============================================================================
// EX stage: operand forwarding muxes, ALU, branch/jump resolution, and
// packing of the EX/MEM pipeline struct.
// =============================================================================

`timescale 1ns / 1ps

module execute_stage (
    input logic clk,
    input logic rst_n,

    /* verilator lint_off UNUSEDSIGNAL */
    input core_pkg::id_ex_t id_ex,  // rs1_addr/rs2_addr/illegal_instr consumed outside this stage
    /* verilator lint_on UNUSEDSIGNAL */

    // Forwarding
    input core_pkg::xlen_t    ex_mem_fwd_val,  // EX/MEM alu_result
    input core_pkg::xlen_t    mem_wb_fwd_val,  // WB-stage writeback value
    input core_pkg::fwd_sel_e fwd_a_sel,
    input core_pkg::fwd_sel_e fwd_b_sel,

    // Branch/jump resolution (to hazard unit / PC redirect)
    output logic             branch_taken,
    output core_pkg::xlen_t  branch_target,

    // RV32M: multi-cycle divide/remainder busy — structural stall request to
    // the hazard unit (holds PC/IF-ID/ID-EX while the divider runs).
    output logic ex_div_stall,

    output core_pkg::ex_mem_t ex_mem_d
);

  import core_pkg::*;

  xlen_t rs1_val_fwd, rs2_val_fwd;
  xlen_t alu_a, alu_b, alu_y;
  logic  alu_eq, alu_lt, alu_ltu;

  always_comb begin
    unique case (fwd_a_sel)
      FWD_EX_MEM: rs1_val_fwd = ex_mem_fwd_val;
      FWD_MEM_WB: rs1_val_fwd = mem_wb_fwd_val;
      default:    rs1_val_fwd = id_ex.rs1_val;
    endcase

    unique case (fwd_b_sel)
      FWD_EX_MEM: rs2_val_fwd = ex_mem_fwd_val;
      FWD_MEM_WB: rs2_val_fwd = mem_wb_fwd_val;
      default:    rs2_val_fwd = id_ex.rs2_val;
    endcase
  end

  assign alu_a = id_ex.alu_src1_is_pc ? id_ex.pc : rs1_val_fwd;
  assign alu_b = id_ex.alu_src2_is_imm ? id_ex.imm : rs2_val_fwd;

  alu u_alu (
      .a  (alu_a),
      .b  (alu_b),
      .op (id_ex.alu_op),
      .y  (alu_y),
      .eq (alu_eq),
      .lt (alu_lt),
      .ltu(alu_ltu)
  );

  branch_unit u_branch_unit (
      .pc(id_ex.pc),
      .rs1_val(rs1_val_fwd),
      .imm(id_ex.imm),
      .br_op(id_ex.br_op),
      .is_branch(id_ex.is_branch),
      .is_jal(id_ex.is_jal),
      .is_jalr(id_ex.is_jalr),
      .eq(alu_eq),
      .lt(alu_lt),
      .ltu(alu_ltu),
      .taken(branch_taken),
      .target(branch_target)
  );

  // ---------------------------------------------------------------------------
  // RV32M: multi-cycle divide/remainder.
  // div_unit latches rs1_val_fwd/rs2_val_fwd once on `div_start` and iterates
  // internally afterward — see div_unit.sv header for why it must not
  // re-sample the forwarding muxes mid-division.
  // ---------------------------------------------------------------------------
  logic is_div_op;
  assign is_div_op = (id_ex.alu_op == ALU_DIV) || (id_ex.alu_op == ALU_DIVU) ||
      (id_ex.alu_op == ALU_REM) || (id_ex.alu_op == ALU_REMU);

  logic  div_busy, div_done, div_start;
  xlen_t div_result;

  assign div_start    = id_ex.valid && is_div_op && !div_busy;
  assign ex_div_stall = id_ex.valid && is_div_op && !div_done;

  div_unit u_div_unit (
      .clk        (clk),
      .rst_n      (rst_n),
      .start      (div_start),
      .op         (id_ex.alu_op),
      .dividend_in(rs1_val_fwd),
      .divisor_in (rs2_val_fwd),
      .busy       (div_busy),
      .done       (div_done),
      .result     (div_result)
  );

  // While the divider is busy, ex_mem_d must be a genuine all-zero bubble —
  // not just .valid=0 — since core_top wires the regfile's rd_we straight
  // from mem_wb_q.rd_we with no valid gating; a partial bubble that left
  // rd_we/alu_result as a passthrough of the frozen (stale) id_ex_q would
  // corrupt the destination register on every stall cycle.
  always_comb begin
    if (ex_div_stall) begin
      ex_mem_d = '0;
    end else begin
      ex_mem_d             = '0;
      ex_mem_d.pc4         = id_ex.pc4;
      ex_mem_d.alu_result  = (is_div_op && div_done) ? div_result : alu_y;
      ex_mem_d.store_data  = rs2_val_fwd;
      ex_mem_d.rd          = id_ex.rd;
      ex_mem_d.rd_we       = id_ex.rd_we;
      ex_mem_d.mem_rd      = id_ex.mem_rd;
      ex_mem_d.mem_wr      = id_ex.mem_wr;
      ex_mem_d.mem_size    = id_ex.mem_size;
      ex_mem_d.mem_signext = id_ex.mem_signext;
      ex_mem_d.wb_from_mem = id_ex.wb_from_mem;
      ex_mem_d.wb_from_pc4 = id_ex.wb_from_pc4;
      ex_mem_d.is_amo      = id_ex.is_amo;
      ex_mem_d.amo_op      = id_ex.amo_op;
      ex_mem_d.valid       = id_ex.valid;
    end
  end

endmodule
