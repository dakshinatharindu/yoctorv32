// =============================================================================
// rtl/core/core_pkg.sv
// =============================================================================
// Central package for core-wide types, enums, and (optionally) pipeline structs.
// Keep it stable so the rest of the RTL can grow without rewiring everything.
// =============================================================================

`timescale 1ns / 1ps

package core_pkg;

  // ---------------------------------------------------------------------------
  // Core constants / common typedefs
  // ---------------------------------------------------------------------------
  localparam int XLEN = 32;  // RV32 (fixed here on purpose)
  typedef logic [XLEN-1:0] xlen_t;

  typedef logic [4:0] reg_addr_t;  // x0..x31

  localparam xlen_t RESET_PC = 32'h0000_0000;

  // NOP encoding (ADDI x0, x0, 0) — used to fill pipeline bubbles.
  localparam logic [31:0] NOP_INSTR = 32'h0000_0013;

  // ---------------------------------------------------------------------------
  // Trap causes (mcause values; exceptions only this pass — the interrupt bit
  // is never set since no interrupt source is wired up yet).
  // ---------------------------------------------------------------------------
  localparam logic [31:0] CAUSE_ILLEGAL_INSTR = 32'd2;
  localparam logic [31:0] CAUSE_BREAKPOINT = 32'd3;
  localparam logic [31:0] CAUSE_LOAD_MISALIGNED = 32'd4;
  localparam logic [31:0] CAUSE_STORE_MISALIGNED = 32'd6;
  localparam logic [31:0] CAUSE_ECALL_M = 32'd11;

  // CSR opcode encoding — matches funct3[1:0] directly, so decode can cast
  // funct3 straight into this enum with no separate lookup.
  typedef enum logic [1:0] {
    CSR_RW = 2'b01,
    CSR_RS = 2'b10,
    CSR_RC = 2'b11
  } csr_op_e;

  // ---------------------------------------------------------------------------
  // ALU operation encoding
  // Keep this the single source of truth for ALU ops.
  // ---------------------------------------------------------------------------
  typedef enum logic [4:0] {
    ALU_ADD    = 5'd0,
    ALU_SUB    = 5'd1,
    ALU_AND    = 5'd2,
    ALU_OR     = 5'd3,
    ALU_XOR    = 5'd4,
    ALU_SLL    = 5'd5,
    ALU_SRL    = 5'd6,
    ALU_SRA    = 5'd7,
    ALU_SLT    = 5'd8,
    ALU_SLTU   = 5'd9,
    ALU_COPY_A = 5'd10,
    ALU_COPY_B = 5'd11,
    ALU_ZERO   = 5'd12,

    // RV32M: single-cycle combinational multiply, folded into the ALU.
    ALU_MUL    = 5'd13,
    ALU_MULH   = 5'd14,
    ALU_MULHSU = 5'd15,
    ALU_MULHU  = 5'd16,

    // RV32M: divide/remainder. The ALU itself has no state to host a
    // multi-cycle divider, so these are dead values here — execute_stage
    // muxes in the real result from div_unit. Kept as alu_op_e members so
    // decode/execute_stage can dispatch on a single enum.
    ALU_DIV    = 5'd17,
    ALU_DIVU   = 5'd18,
    ALU_REM    = 5'd19,
    ALU_REMU   = 5'd20
  } alu_op_e;

  typedef enum logic [2:0] {
    IMM_NONE = 3'd0,
    IMM_I    = 3'd1,
    IMM_S    = 3'd2,
    IMM_B    = 3'd3,
    IMM_U    = 3'd4,
    IMM_J    = 3'd5
  } imm_type_e;

  // ---------------------------------------------------------------------------
  // Optional: common enums you will likely want soon
  // ---------------------------------------------------------------------------
  typedef enum logic [2:0] {
    BR_NONE = 3'd0,
    BR_EQ   = 3'd1,
    BR_NE   = 3'd2,
    BR_LT   = 3'd3,
    BR_GE   = 3'd4,
    BR_LTU  = 3'd5,
    BR_GEU  = 3'd6
  } branch_op_e;

  typedef enum logic [1:0] {
    MSZ_B = 2'd0,  // byte
    MSZ_H = 2'd1,  // halfword
    MSZ_W = 2'd2   // word
  } mem_size_e;

  // ---------------------------------------------------------------------------
  // RV32A: AMO/LR/SC operation encoding (word-only, no aq/rl distinction —
  // a single in-order hart with no reordering satisfies acquire/release
  // vacuously, so aq/rl bits are decoded but otherwise ignored).
  // ---------------------------------------------------------------------------
  typedef enum logic [3:0] {
    AMO_LR    = 4'd0,
    AMO_SC    = 4'd1,
    AMO_SWAP  = 4'd2,
    AMO_ADD   = 4'd3,
    AMO_XOR   = 4'd4,
    AMO_AND   = 4'd5,
    AMO_OR    = 4'd6,
    AMO_MIN   = 4'd7,
    AMO_MAX   = 4'd8,
    AMO_MINU  = 4'd9,
    AMO_MAXU  = 4'd10
  } amo_op_e;

  // ---------------------------------------------------------------------------
  // Forwarding source select (EX stage operand muxes)
  // ---------------------------------------------------------------------------
  typedef enum logic [1:0] {
    FWD_NONE   = 2'd0,  // use value latched in ID/EX
    FWD_EX_MEM = 2'd1,  // forward from EX/MEM (ALU result)
    FWD_MEM_WB = 2'd2   // forward from MEM/WB (writeback value)
  } fwd_sel_e;

  // ---------------------------------------------------------------------------
  // Optional: pipeline bus structs (minimal examples)
  // You can expand these as your pipeline grows.
  // ---------------------------------------------------------------------------

  typedef struct packed {
    xlen_t       pc;
    logic [31:0] instr;
    logic        valid;
  } if_id_t;

  typedef struct packed {
    xlen_t pc;
    xlen_t pc4;
    xlen_t rs1_val;
    xlen_t rs2_val;
    xlen_t imm;

    reg_addr_t rs1_addr;
    reg_addr_t rs2_addr;
    reg_addr_t rd;
    logic      rd_we;

    alu_op_e alu_op;
    logic    alu_src1_is_pc;
    logic    alu_src2_is_imm;

    branch_op_e br_op;
    logic       is_branch;
    logic       is_jal;
    logic       is_jalr;

    logic      mem_rd;
    logic      mem_wr;
    mem_size_e mem_size;
    logic      mem_signext;

    logic wb_from_mem;
    logic wb_from_pc4;

    logic    is_amo;
    amo_op_e amo_op;

    // SYSTEM: CSR ops / ECALL / EBREAK / MRET
    logic        csr_en;
    csr_op_e     csr_op;
    logic        csr_use_imm;
    logic [11:0] csr_addr;
    logic        is_ecall;
    logic        is_ebreak;
    logic        is_mret;

    logic illegal_instr;
    logic valid;
  } id_ex_t;

  typedef struct packed {
    xlen_t pc;          // the instruction's own PC (for mepc on trap entry)
    xlen_t pc4;         // pc+4, for JAL/JALR writeback
    xlen_t alu_result;  // ALU result / memory address
    xlen_t store_data;  // forwarded rs2 value, for stores

    reg_addr_t rd;
    logic      rd_we;

    logic      mem_rd;
    logic      mem_wr;
    mem_size_e mem_size;
    logic      mem_signext;

    logic wb_from_mem;
    logic wb_from_pc4;

    logic    is_amo;
    amo_op_e amo_op;

    // SYSTEM: CSR ops / ECALL / EBREAK / MRET (pass-through from id_ex_t,
    // plus the operand resolved through EX-stage forwarding)
    logic        illegal_instr;
    logic        csr_en;
    csr_op_e     csr_op;
    logic [11:0] csr_addr;
    xlen_t       csr_operand;
    logic        is_ecall;
    logic        is_ebreak;
    logic        is_mret;

    logic valid;
  } ex_mem_t;

  typedef struct packed {
    xlen_t alu_result;
    xlen_t pc4;
    xlen_t csr_rdata;

    reg_addr_t rd;
    logic      rd_we;

    logic wb_from_mem;
    logic wb_from_pc4;
    logic wb_from_csr;

    // Carried forward for load_align (rtl/core/lsu/load_align.sv), which
    // decodes the load value one stage later than lsu.sv itself, once
    // dmem_rdata (synchronous-read) has actually arrived for this address.
    mem_size_e mem_size;
    logic      mem_signext;
    logic      is_amo;
    amo_op_e   amo_op;
    logic      sc_success;

    logic valid;
  } mem_wb_t;

endpackage : core_pkg
