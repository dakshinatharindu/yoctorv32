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

    // RV32A: AMO/LR/SC
    output logic             is_amo,
    output core_pkg::amo_op_e amo_op,

    // Operand usage hints (useful for hazard unit later)
    output logic uses_rs1,
    output logic uses_rs2,

    // SYSTEM: CSR ops / ECALL / EBREAK / MRET
    output logic            csr_en,
    output core_pkg::csr_op_e csr_op,
    output logic            csr_use_imm,
    output logic [11:0]     csr_addr,
    output logic            is_ecall,
    output logic            is_ebreak,
    output logic            is_mret,

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
  localparam logic [6:0] OPCODE_AMO = 7'b0101111;  // RV32A: AMO*.W / LR.W / SC.W

  // RV32M sub-opcode: OP (0110011) with funct7 == OPCODE_OP_MULDIV_F7
  localparam logic [6:0] OP_MULDIV_F7 = 7'b0000001;

  // RV32A funct5 (instr[31:27]) encodings.
  localparam logic [4:0] AMOF5_ADD = 5'b00000;
  localparam logic [4:0] AMOF5_SWAP = 5'b00001;
  localparam logic [4:0] AMOF5_LR = 5'b00010;
  localparam logic [4:0] AMOF5_SC = 5'b00011;
  localparam logic [4:0] AMOF5_XOR = 5'b00100;
  localparam logic [4:0] AMOF5_OR = 5'b01000;
  localparam logic [4:0] AMOF5_AND = 5'b01100;
  localparam logic [4:0] AMOF5_MIN = 5'b10000;
  localparam logic [4:0] AMOF5_MAX = 5'b10100;
  localparam logic [4:0] AMOF5_MINU = 5'b11000;
  localparam logic [4:0] AMOF5_MAXU = 5'b11100;

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

    is_amo          = 1'b0;
    amo_op          = AMO_LR;

    uses_rs1        = 1'b0;
    uses_rs2        = 1'b0;

    csr_en          = 1'b0;
    csr_op          = CSR_RW;
    csr_use_imm     = 1'b0;
    csr_addr        = '0;
    is_ecall        = 1'b0;
    is_ebreak       = 1'b0;
    is_mret         = 1'b0;

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

        if (funct7 == OP_MULDIV_F7) begin
          // ---------------------------------------------------------------
          // RV32M: MUL/MULH/MULHSU/MULHU/DIV/DIVU/REM/REMU
          // ---------------------------------------------------------------
          unique case (funct3)
            3'b000:  alu_op = ALU_MUL;
            3'b001:  alu_op = ALU_MULH;
            3'b010:  alu_op = ALU_MULHSU;
            3'b011:  alu_op = ALU_MULHU;
            3'b100:  alu_op = ALU_DIV;
            3'b101:  alu_op = ALU_DIVU;
            3'b110:  alu_op = ALU_REM;
            3'b111:  alu_op = ALU_REMU;
            default: illegal_instr = 1'b1;
          endcase
        end else begin
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
      end

      // -----------------------------------------------------------------------
      // AMO (RV32A): LR.W / SC.W / AMO*.W
      // Address is rs1 only (ALU_COPY_A — no immediate, and importantly not
      // ALU_ADD, since alu_src2_is_imm stays 0 and would otherwise feed rs2
      // as the ALU's b-operand, computing the wrong address rs1+rs2).
      // funct5 = instr[31:27] selects the operation; funct3 must be 010
      // (word) since RV32A defines no .D forms; aq/rl (instr[26:25]) are
      // decoded implicitly-ignored — a single in-order hart with no
      // reordering satisfies acquire/release trivially.
      // -----------------------------------------------------------------------
      OPCODE_AMO: begin
        if (funct3 != 3'b010) begin
          illegal_instr = 1'b1;
        end else begin
          is_amo         = 1'b1;
          alu_op         = ALU_COPY_A;
          mem_size       = MSZ_W;
          rd_we          = 1'b1;
          wb_from_mem    = 1'b1;
          mem_rd         = 1'b1;
          uses_rs1       = 1'b1;

          unique case (instr[31:27])
            AMOF5_ADD:  amo_op = AMO_ADD;
            AMOF5_SWAP: amo_op = AMO_SWAP;
            AMOF5_LR:   amo_op = AMO_LR;
            AMOF5_SC:   amo_op = AMO_SC;
            AMOF5_XOR:  amo_op = AMO_XOR;
            AMOF5_OR:   amo_op = AMO_OR;
            AMOF5_AND:  amo_op = AMO_AND;
            AMOF5_MIN:  amo_op = AMO_MIN;
            AMOF5_MAX:  amo_op = AMO_MAX;
            AMOF5_MINU: amo_op = AMO_MINU;
            AMOF5_MAXU: amo_op = AMO_MAXU;
            default:    illegal_instr = 1'b1;
          endcase

          if (!illegal_instr) begin
            if (amo_op == AMO_LR) begin
              // rs2 field must be 0 for LR.W.
              if (rs2_addr != '0) illegal_instr = 1'b1;
            end else begin
              mem_wr   = 1'b1;
              uses_rs2 = 1'b1;
            end
          end
        end
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
      // funct3=000 is ECALL/EBREAK/MRET/WFI, selected by the funct12
      // (instr[31:20]) field; any other funct3 is a CSR instruction, with
      // csr_op taken
      // directly from funct3[1:0] (CSR_RW=01/CSR_RS=10/CSR_RC=11) and
      // csr_use_imm = funct3[2] selecting the *I variants, whose rs1_addr
      // field (already generically extracted above) is actually a 5-bit
      // unsigned immediate rather than a register index.
      // Whether a given csr_addr is actually implemented/writable is not
      // decided here — that is resolved later by the csr module in MEM.
      // -----------------------------------------------------------------------
      OPCODE_SYSTEM: begin
        unique case (funct3)
          3'b000: begin
            unique case (instr[31:20])
              12'h000: is_ecall  = 1'b1;
              12'h001: is_ebreak = 1'b1;
              12'h302: is_mret   = 1'b1;
              12'h105: ;  // WFI: legal NOP (no low-power stall-until-interrupt
              // implemented — correctness only, matches an in-order core
              // with no idle state to actually suspend).
              default: illegal_instr = 1'b1;
            endcase
          end

          3'b001, 3'b010, 3'b011, 3'b101, 3'b110, 3'b111: begin
            csr_en      = 1'b1;
            csr_addr    = instr[31:20];
            csr_op      = csr_op_e'(funct3[1:0]);
            csr_use_imm = funct3[2];
            rd_we       = 1'b1;
            uses_rs1    = !funct3[2];
          end

          default: illegal_instr = 1'b1;  // funct3=100: reserved
        endcase
      end

      default: begin
        illegal_instr = 1'b1;
      end
    endcase
  end

endmodule
