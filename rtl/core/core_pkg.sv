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
    ALU_ZERO   = 5'd12
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

    logic illegal_instr;
    logic valid;
  } id_ex_t;

  typedef struct packed {
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

    logic valid;
  } ex_mem_t;

  typedef struct packed {
    xlen_t alu_result;
    xlen_t mem_rdata;
    xlen_t pc4;

    reg_addr_t rd;
    logic      rd_we;

    logic wb_from_mem;
    logic wb_from_pc4;

    logic valid;
  } mem_wb_t;

endpackage : core_pkg
