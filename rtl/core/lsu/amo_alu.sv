// =============================================================================
// rtl/core/lsu/amo_alu.sv
// =============================================================================
// RV32A: combinational read-modify-write function for AMOSWAP/ADD/XOR/AND/
// OR/MIN/MAX/MINU/MAXU. LR.W and SC.W never reach this — they're handled
// directly in lsu.sv (LR is a plain read + reservation set, SC is a
// conditional plain store, neither combines old_data with rs2_data).
// =============================================================================

`timescale 1ns / 1ps

module amo_alu (
    input core_pkg::xlen_t   old_data,
    input core_pkg::xlen_t   rs2_data,
    input core_pkg::amo_op_e amo_op,

    output core_pkg::xlen_t new_data
);

  import core_pkg::*;

  logic signed [XLEN-1:0] old_s, rs2_s;
  assign old_s = signed'(old_data);
  assign rs2_s = signed'(rs2_data);

  always_comb begin
    unique case (amo_op)
      AMO_SWAP: new_data = rs2_data;
      AMO_ADD:  new_data = old_data + rs2_data;
      AMO_XOR:  new_data = old_data ^ rs2_data;
      AMO_AND:  new_data = old_data & rs2_data;
      AMO_OR:   new_data = old_data | rs2_data;
      AMO_MIN:  new_data = (old_s < rs2_s) ? old_data : rs2_data;
      AMO_MAX:  new_data = (old_s > rs2_s) ? old_data : rs2_data;
      AMO_MINU: new_data = (old_data < rs2_data) ? old_data : rs2_data;
      AMO_MAXU: new_data = (old_data > rs2_data) ? old_data : rs2_data;
      default:  new_data = old_data;  // LR/SC: unreachable in practice
    endcase
  end

endmodule
