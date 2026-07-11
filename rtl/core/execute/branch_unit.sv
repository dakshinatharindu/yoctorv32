// =============================================================================
// rtl/core/execute/branch_unit.sv
// =============================================================================
// Resolves branch/jump taken + target in EX.
// - BRANCH: target = pc + imm_b, taken from br_op against ALU compare flags
//   (ALU a/b are rs1_val/rs2_val for branches, since decode leaves
//   alu_src1_is_pc and alu_src2_is_imm both clear).
// - JAL:    target = pc + imm_j, always taken.
// - JALR:   target = (rs1_val + imm_i) & ~1, always taken.
// =============================================================================

`timescale 1ns / 1ps

module branch_unit (
    input core_pkg::xlen_t pc,
    input core_pkg::xlen_t rs1_val,
    input core_pkg::xlen_t imm,

    input core_pkg::branch_op_e br_op,
    input logic                 is_branch,
    input logic                 is_jal,
    input logic                 is_jalr,

    input logic eq,
    input logic lt,
    input logic ltu,

    output logic             taken,
    output core_pkg::xlen_t  target
);

  import core_pkg::*;

  logic branch_cond;

  always_comb begin
    unique case (br_op)
      BR_EQ:   branch_cond = eq;
      BR_NE:   branch_cond = ~eq;
      BR_LT:   branch_cond = lt;
      BR_GE:   branch_cond = ~lt;
      BR_LTU:  branch_cond = ltu;
      BR_GEU:  branch_cond = ~ltu;
      default: branch_cond = 1'b0;
    endcase
  end

  assign taken  = is_jal || is_jalr || (is_branch && branch_cond);
  assign target = is_jalr ? ((rs1_val + imm) & ~xlen_t'(1)) : (pc + imm);

endmodule
