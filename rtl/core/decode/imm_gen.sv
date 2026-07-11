// =============================================================================
// rtl/core/decode/imm_gen.sv
// =============================================================================
// RISC-V RV32 immediate generator
//
// Generates sign-extended immediates for:
//   - I-type  (loads, OP-IMM, JALR, CSR imm form can be handled separately)
//   - S-type  (stores)
//   - B-type  (branches)
//   - U-type  (LUI, AUIPC)
//   - J-type  (JAL)
//
// Notes:
// - Output is always XLEN-wide (RV32 => 32 bits).
// - For shifts (SLLI/SRLI/SRAI), decode can still use IMM_I and only consume
//   shamt[4:0] later in ALU/execute.
// - CSR zimm is usually better handled directly in decode, not here.
//
// =============================================================================

`timescale 1ns / 1ps

module imm_gen (
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic                [31:0] instr,  // opcode bits [6:0] intentionally unused here
    /* verilator lint_on UNUSEDSIGNAL */
    input  core_pkg::imm_type_e        imm_type,
    output core_pkg::xlen_t            imm
);

  import core_pkg::*;

  always_comb begin
    unique case (imm_type)

      // I-type: imm[11:0] = instr[31:20]
      IMM_I: begin
        imm = xlen_t'({{20{instr[31]}}, instr[31:20]});
      end

      // S-type: imm[11:5|4:0] = instr[31:25|11:7]
      IMM_S: begin
        imm = xlen_t'({{20{instr[31]}}, instr[31:25], instr[11:7]});
      end

      // B-type: imm[12|10:5|4:1|11|0] = instr[31|30:25|11:8|7|0]
      // Branch offset is sign-extended and bit[0] is always 0.
      IMM_B: begin
        imm = xlen_t'({
          {19{instr[31]}},  // sign extension above imm[12]
          instr[31],  // imm[12]
          instr[7],  // imm[11]
          instr[30:25],  // imm[10:5]
          instr[11:8],  // imm[4:1]
          1'b0  // imm[0]
        });
      end

      // U-type: imm[31:12] = instr[31:12], low 12 bits are zero
      IMM_U: begin
        imm = xlen_t'({instr[31:12], 12'b0});
      end

      // J-type: imm[20|10:1|11|19:12|0] = instr[31|30:21|20|19:12|0]
      // Jump offset is sign-extended and bit[0] is always 0.
      IMM_J: begin
        imm = xlen_t'({
          {11{instr[31]}},  // sign extension above imm[20]
          instr[31],  // imm[20]
          instr[19:12],  // imm[19:12]
          instr[20],  // imm[11]
          instr[30:21],  // imm[10:1]
          1'b0  // imm[0]
        });
      end

      // No immediate / default safe value
      IMM_NONE: begin
        imm = '0;
      end

      default: begin
        imm = '0;
      end
    endcase
  end

endmodule
