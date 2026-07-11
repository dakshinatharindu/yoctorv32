// =============================================================================
// rtl/core/decode/decode.sv
// =============================================================================
// Minimal RV32I decoder
//
// Responsibilities:
//   - Extract rs1/rs2/rd
//   - Select immediate format
//   - Generate ALU op
//   - Generate branch/jump/memory/writeback controls
//   - Flag illegal/unsupported instructions
//
// Intended use:
//   - Feed regfile read addresses
//   - Feed imm_gen
//   - Feed ID/EX pipeline register
// =============================================================================

`timescale 1ns / 1ps

module decode (
    input logic [31:0] instr,

    // Register specifiers
    output core_pkg::reg_addr_t rs1_addr,
    output core_pkg::reg_addr_t rs2_addr,
    output core_pkg::reg_addr_t rd_addr,

    // Immediate decode
    output core_pkg::imm_type_e imm_type,

    // ALU control
    output core_pkg::alu_op_e alu_op,
    output logic              alu_src1_is_pc,
    output logic              alu_src2_is_imm,

    // Register file writeback
    output logic rd_we,

    // Memory controls
    output logic                mem_rd,
    output logic                mem_wr,
    output core_pkg::mem_size_e mem_size,
    output logic                mem_signext,

    // Writeback source
    output logic wb_from_mem,
    output logic wb_from_pc4,

    // Control flow
    output logic                 is_branch,
    output logic                 is_jal,
    output logic                 is_jalr,
    output core_pkg::branch_op_e br_op,

    // Operand usage hints (useful for hazard unit later)
    output logic uses_rs1,
    output logic uses_rs2,

    // Status
    output logic illegal_instr
);

  import core_pkg::*;

  // ---------------------------------------------------------------------------
  // Instruction fields
  // ---------------------------------------------------------------------------
  logic [6:0] opcode;
  logic [2:0] funct3;
  logic [6:0] funct7;

  assign opcode   = instr[6:0];
  assign rd_addr  = instr[11:7];
  assign funct3   = instr[14:12];
  assign rs1_addr = instr[19:15];
  assign rs2_addr = instr[24:20];
  assign funct7   = instr[31:25];

  // ---------------------------------------------------------------------------
  // RISC-V base opcodes used here
  // ---------------------------------------------------------------------------
  localparam logic [6:0] OPCODE_LUI = 7'b0110111;
  localparam logic [6:0] OPCODE_AUIPC = 7'b0010111;
  localparam logic [6:0] OPCODE_JAL = 7'b1101111;
  localparam logic [6:0] OPCODE_JALR = 7'b1100111;
  localparam logic [6:0] OPCODE_BRANCH = 7'b1100011;
  localparam logic [6:0] OPCODE_LOAD = 7'b0000011;
  localparam logic [6:0] OPCODE_STORE = 7'b0100011;
  localparam logic [6:0] OPCODE_OP_IMM = 7'b0010011;
  localparam logic [6:0] OPCODE_OP = 7'b0110011;
  localparam logic [6:0] OPCODE_MISC_MEM = 7'b0001111;  // fence, fence.i
  localparam logic [6:0] OPCODE_SYSTEM = 7'b1110011;  // ecall/ebreak/csr*

  // ---------------------------------------------------------------------------
  // Main decode
  // ---------------------------------------------------------------------------
  always_comb begin
    // -------------------------
    // Safe defaults
    // -------------------------
    imm_type        = IMM_NONE;

    alu_op          = ALU_ADD;
    alu_src1_is_pc  = 1'b0;
    alu_src2_is_imm = 1'b0;

    rd_we           = 1'b0;

    mem_rd          = 1'b0;
    mem_wr          = 1'b0;
    mem_size        = MSZ_W;
    mem_signext     = 1'b1;

    wb_from_mem     = 1'b0;
    wb_from_pc4     = 1'b0;

    is_branch       = 1'b0;
    is_jal          = 1'b0;
    is_jalr         = 1'b0;
    br_op           = BR_NONE;

    uses_rs1        = 1'b0;
    uses_rs2        = 1'b0;

    illegal_instr   = 1'b0;

    unique case (opcode)

      // -----------------------------------------------------------------------
      // LUI
      // rd = imm_u
      // -----------------------------------------------------------------------
      OPCODE_LUI: begin
        imm_type        = IMM_U;
        alu_op          = ALU_COPY_B;
        alu_src2_is_imm = 1'b1;
        rd_we           = 1'b1;
      end

      // -----------------------------------------------------------------------
      // AUIPC
      // rd = pc + imm_u
      // -----------------------------------------------------------------------
      OPCODE_AUIPC: begin
        imm_type        = IMM_U;
        alu_op          = ALU_ADD;
        alu_src1_is_pc  = 1'b1;
        alu_src2_is_imm = 1'b1;
        rd_we           = 1'b1;
      end

      // -----------------------------------------------------------------------
      // JAL
      // rd = pc + 4 ; pc = pc + imm_j
      // -----------------------------------------------------------------------
      OPCODE_JAL: begin
        imm_type    = IMM_J;
        is_jal      = 1'b1;
        rd_we       = 1'b1;
        wb_from_pc4 = 1'b1;
      end

      // -----------------------------------------------------------------------
      // JALR
      // rd = pc + 4 ; pc = rs1 + imm_i
      // -----------------------------------------------------------------------
      OPCODE_JALR: begin
        if (funct3 != 3'b000) begin
          illegal_instr = 1'b1;
        end else begin
          imm_type    = IMM_I;
          is_jalr     = 1'b1;
          rd_we       = 1'b1;
          wb_from_pc4 = 1'b1;
          uses_rs1    = 1'b1;
        end
      end

      // -----------------------------------------------------------------------
      // BRANCH
      // -----------------------------------------------------------------------
      OPCODE_BRANCH: begin
        imm_type  = IMM_B;
        is_branch = 1'b1;
        uses_rs1  = 1'b1;
        uses_rs2  = 1'b1;

        unique case (funct3)
          3'b000:  br_op = BR_EQ;  // BEQ
          3'b001:  br_op = BR_NE;  // BNE
          3'b100:  br_op = BR_LT;  // BLT
          3'b101:  br_op = BR_GE;  // BGE
          3'b110:  br_op = BR_LTU;  // BLTU
          3'b111:  br_op = BR_GEU;  // BGEU
          default: illegal_instr = 1'b1;
        endcase
      end

      // -----------------------------------------------------------------------
      // LOAD
      // rd = mem[rs1 + imm_i]
      // -----------------------------------------------------------------------
      OPCODE_LOAD: begin
        imm_type        = IMM_I;
        alu_op          = ALU_ADD;
        alu_src2_is_imm = 1'b1;
        rd_we           = 1'b1;
        mem_rd          = 1'b1;
        wb_from_mem     = 1'b1;
        uses_rs1        = 1'b1;

        unique case (funct3)
          3'b000: begin
            mem_size = MSZ_B;
            mem_signext = 1'b1;
          end  // LB
          3'b001: begin
            mem_size = MSZ_H;
            mem_signext = 1'b1;
          end  // LH
          3'b010: begin
            mem_size = MSZ_W;
            mem_signext = 1'b1;
          end  // LW
          3'b100: begin
            mem_size = MSZ_B;
            mem_signext = 1'b0;
          end  // LBU
          3'b101: begin
            mem_size = MSZ_H;
            mem_signext = 1'b0;
          end  // LHU
          default: illegal_instr = 1'b1;
        endcase
      end

      // -----------------------------------------------------------------------
      // STORE
      // mem[rs1 + imm_s] = rs2
      // -----------------------------------------------------------------------
      OPCODE_STORE: begin
        imm_type        = IMM_S;
        alu_op          = ALU_ADD;
        alu_src2_is_imm = 1'b1;
        mem_wr          = 1'b1;
        uses_rs1        = 1'b1;
        uses_rs2        = 1'b1;

        unique case (funct3)
          3'b000:  mem_size = MSZ_B;  // SB
          3'b001:  mem_size = MSZ_H;  // SH
          3'b010:  mem_size = MSZ_W;  // SW
          default: illegal_instr = 1'b1;
        endcase
      end

      // -----------------------------------------------------------------------
      // OP-IMM
      // rd = rs1 op imm_i
      // -----------------------------------------------------------------------
      OPCODE_OP_IMM: begin
        imm_type        = IMM_I;
        alu_src2_is_imm = 1'b1;
        rd_we           = 1'b1;
        uses_rs1        = 1'b1;

        unique case (funct3)
          3'b000: alu_op = ALU_ADD;  // ADDI
          3'b010: alu_op = ALU_SLT;  // SLTI
          3'b011: alu_op = ALU_SLTU;  // SLTIU
          3'b100: alu_op = ALU_XOR;  // XORI
          3'b110: alu_op = ALU_OR;  // ORI
          3'b111: alu_op = ALU_AND;  // ANDI

          3'b001: begin  // SLLI
            if (funct7 == 7'b0000000) alu_op = ALU_SLL;
            else illegal_instr = 1'b1;
          end

          3'b101: begin  // SRLI / SRAI
            if (funct7 == 7'b0000000) alu_op = ALU_SRL;
            else if (funct7 == 7'b0100000) alu_op = ALU_SRA;
            else illegal_instr = 1'b1;
          end

          default: illegal_instr = 1'b1;
        endcase
      end

      // -----------------------------------------------------------------------
      // OP
      // rd = rs1 op rs2
      // -----------------------------------------------------------------------
      OPCODE_OP: begin
        rd_we    = 1'b1;
        uses_rs1 = 1'b1;
        uses_rs2 = 1'b1;

        unique case (funct3)
          3'b000: begin
            if (funct7 == 7'b0000000) alu_op = ALU_ADD;  // ADD
            else if (funct7 == 7'b0100000) alu_op = ALU_SUB;  // SUB
            else illegal_instr = 1'b1;
          end

          3'b001: begin
            if (funct7 == 7'b0000000) alu_op = ALU_SLL;  // SLL
            else illegal_instr = 1'b1;
          end

          3'b010: begin
            if (funct7 == 7'b0000000) alu_op = ALU_SLT;  // SLT
            else illegal_instr = 1'b1;
          end

          3'b011: begin
            if (funct7 == 7'b0000000) alu_op = ALU_SLTU;  // SLTU
            else illegal_instr = 1'b1;
          end

          3'b100: begin
            if (funct7 == 7'b0000000) alu_op = ALU_XOR;  // XOR
            else illegal_instr = 1'b1;
          end

          3'b101: begin
            if (funct7 == 7'b0000000) alu_op = ALU_SRL;  // SRL
            else if (funct7 == 7'b0100000) alu_op = ALU_SRA;  // SRA
            else illegal_instr = 1'b1;
          end

          3'b110: begin
            if (funct7 == 7'b0000000) alu_op = ALU_OR;  // OR
            else illegal_instr = 1'b1;
          end

          3'b111: begin
            if (funct7 == 7'b0000000) alu_op = ALU_AND;  // AND
            else illegal_instr = 1'b1;
          end

          default: illegal_instr = 1'b1;
        endcase
      end

      // -----------------------------------------------------------------------
      // FENCE / FENCE.I
      // Safe to treat as NOP in a simple in-order no-cache core initially
      // -----------------------------------------------------------------------
      OPCODE_MISC_MEM: begin
        // No side effect for now.
        // Later you can distinguish fence.i if you add I-cache.
      end

      // -----------------------------------------------------------------------
      // SYSTEM
      // For now, mark illegal. Later extend for ECALL/EBREAK/MRET/CSR ops.
      // -----------------------------------------------------------------------
      OPCODE_SYSTEM: begin
        illegal_instr = 1'b1;
      end

      default: begin
        illegal_instr = 1'b1;
      end
    endcase
  end

endmodule
