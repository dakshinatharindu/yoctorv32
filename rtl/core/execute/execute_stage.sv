// =============================================================================
// rtl/core/execute/execute_stage.sv
// =============================================================================
// EX stage: operand forwarding muxes, ALU, branch/jump resolution, and
// packing of the EX/MEM pipeline struct.
// =============================================================================

`timescale 1ns / 1ps

module execute_stage (
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

  always_comb begin
    ex_mem_d             = '0;
    ex_mem_d.pc4         = id_ex.pc4;
    ex_mem_d.alu_result  = alu_y;
    ex_mem_d.store_data  = rs2_val_fwd;
    ex_mem_d.rd          = id_ex.rd;
    ex_mem_d.rd_we       = id_ex.rd_we;
    ex_mem_d.mem_rd      = id_ex.mem_rd;
    ex_mem_d.mem_wr      = id_ex.mem_wr;
    ex_mem_d.mem_size    = id_ex.mem_size;
    ex_mem_d.mem_signext = id_ex.mem_signext;
    ex_mem_d.wb_from_mem = id_ex.wb_from_mem;
    ex_mem_d.wb_from_pc4 = id_ex.wb_from_pc4;
    ex_mem_d.valid       = id_ex.valid;
  end

endmodule
