// =============================================================================
// rtl/core/execute/alu.sv
// =============================================================================
// Combinational ALU for RV32I.
// - Uses core_pkg.sv for alu_op_e and common types.
// - Pure combinational (recommended for a basic 5-stage in-order core).
// =============================================================================

`timescale 1ns / 1ps

module alu (
    input core_pkg::xlen_t   a,
    input core_pkg::xlen_t   b,
    input core_pkg::alu_op_e op,

    output core_pkg::xlen_t y,

    // Optional compare flags (useful for branch unit)
    output logic eq,
    output logic lt,  // signed
    output logic ltu  // unsigned
);

  import core_pkg::XLEN;
  import core_pkg::xlen_t;

  // Signed views for comparisons / arithmetic shift
  logic signed [XLEN-1:0] a_s, b_s;
  assign a_s = signed'(a);
  assign b_s = signed'(b);

  // Compare flags
  always_comb begin
    eq  = (a == b);
    lt  = (a_s < b_s);
    ltu = (a < b);
  end

  // RV32 shifts use shamt[4:0]
  logic [4:0] shamt;
  always_comb shamt = b[4:0];

  // Result
  always_comb begin
    unique case (op)
      ALU_ADD:    y = a + b;
      ALU_SUB:    y = a - b;
      ALU_AND:    y = a & b;
      ALU_OR:     y = a | b;
      ALU_XOR:    y = a ^ b;
      ALU_SLL:    y = a << shamt;
      ALU_SRL:    y = a >> shamt;
      ALU_SRA:    y = xlen_t'(a_s >>> shamt);
      ALU_SLT:    y = xlen_t'({{(XLEN - 1) {1'b0}}, lt});
      ALU_SLTU:   y = xlen_t'({{(XLEN - 1) {1'b0}}, ltu});
      ALU_COPY_A: y = a;
      ALU_COPY_B: y = b;
      ALU_ZERO:   y = '0;
      default:    y = '0;
    endcase
  end

endmodule
