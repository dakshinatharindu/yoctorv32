// =============================================================================
// rtl/core/core_top.sv
// =============================================================================

// yoctorv32 core: classic 5-stage in-order RV32I pipeline (IF/ID/EX/MEM/WB).
// - Bare-minimal M-mode-only CSR/trap machinery: ECALL/EBREAK/illegal
//   instruction/misaligned load-store traps, MRET, CSRRW/S/C/WI/SI/CI.
//   No interrupts yet (mie/mip are plain storage with no hardware consumer).
// - Instruction and data memories are external, zero-wait-state, combinational
//   read ports (same style as regfile's async reads) — see imem_*/dmem_* ports.
// - Load-use hazards stall one cycle; EX/MEM and MEM/WB forwarding cover the
//   rest; branches/jumps resolve in EX (2-cycle penalty when taken).
// =============================================================================

`timescale 1ns / 1ps

module core_top (
    input logic clk,
    input logic rst_n,

    // Instruction memory port
    output core_pkg::xlen_t imem_addr,
    input  core_pkg::xlen_t imem_rdata,

    // Data memory port
    output core_pkg::xlen_t dmem_addr,
    output core_pkg::xlen_t dmem_wdata,
    output logic      [3:0] dmem_wstrb,
    output logic             dmem_re,
    input  core_pkg::xlen_t dmem_rdata
);

  import core_pkg::*;

  // ---------------------------------------------------------------------------
  // IF stage
  // ---------------------------------------------------------------------------
  xlen_t if_pc, if_instr;
  logic  pc_stall;
  logic  branch_taken;
  xlen_t branch_target;
  logic  sys_redirect;
  xlen_t sys_redirect_target;

  ifetch u_ifetch (
      .clk                 (clk),
      .rst_n               (rst_n),
      .stall               (pc_stall),
      .branch_taken        (branch_taken),
      .branch_target       (branch_target),
      .sys_redirect        (sys_redirect),
      .sys_redirect_target (sys_redirect_target),
      .imem_addr           (imem_addr),
      .imem_rdata          (imem_rdata),
      .pc                  (if_pc),
      .instr               (if_instr)
  );

  if_id_t if_id_d, if_id_q;
  logic   if_id_stall, if_id_flush;

  assign if_id_d.pc    = if_pc;
  assign if_id_d.instr = if_instr;
  assign if_id_d.valid = 1'b1;

  if_id_reg u_if_id_reg (
      .clk  (clk),
      .rst_n(rst_n),
      .stall(if_id_stall),
      .flush(if_id_flush),
      .d    (if_id_d),
      .q    (if_id_q)
  );

  // ---------------------------------------------------------------------------
  // ID stage
  // ---------------------------------------------------------------------------
  reg_addr_t rs1_addr, rs2_addr, rd_addr;
  imm_type_e imm_type;
  alu_op_e   alu_op;
  logic      alu_src1_is_pc, alu_src2_is_imm;
  logic      rd_we;
  logic      mem_rd, mem_wr;
  mem_size_e mem_size;
  logic      mem_signext;
  logic      wb_from_mem, wb_from_pc4;
  logic      is_branch, is_jal, is_jalr;
  branch_op_e br_op;
  logic      is_amo;
  amo_op_e   amo_op;
  logic      uses_rs1, uses_rs2;
  logic      csr_en;
  csr_op_e   csr_op;
  logic      csr_use_imm;
  logic [11:0] csr_addr;
  logic      is_ecall, is_ebreak, is_mret;
  logic      illegal_instr;

  decode u_decode (
      .instr          (if_id_q.instr),
      .rs1_addr       (rs1_addr),
      .rs2_addr       (rs2_addr),
      .rd_addr        (rd_addr),
      .imm_type       (imm_type),
      .alu_op         (alu_op),
      .alu_src1_is_pc (alu_src1_is_pc),
      .alu_src2_is_imm(alu_src2_is_imm),
      .rd_we          (rd_we),
      .mem_rd         (mem_rd),
      .mem_wr         (mem_wr),
      .mem_size       (mem_size),
      .mem_signext    (mem_signext),
      .wb_from_mem    (wb_from_mem),
      .wb_from_pc4    (wb_from_pc4),
      .is_branch      (is_branch),
      .is_jal         (is_jal),
      .is_jalr        (is_jalr),
      .br_op          (br_op),
      .is_amo         (is_amo),
      .amo_op         (amo_op),
      .uses_rs1       (uses_rs1),
      .uses_rs2       (uses_rs2),
      .csr_en         (csr_en),
      .csr_op         (csr_op),
      .csr_use_imm    (csr_use_imm),
      .csr_addr       (csr_addr),
      .is_ecall       (is_ecall),
      .is_ebreak      (is_ebreak),
      .is_mret        (is_mret),
      .illegal_instr  (illegal_instr)
  );

  xlen_t imm;

  imm_gen u_imm_gen (
      .instr   (if_id_q.instr),
      .imm_type(imm_type),
      .imm     (imm)
  );

  xlen_t rs1_rdata, rs2_rdata;
  xlen_t wb_data;
  mem_wb_t mem_wb_q;

  regfile u_regfile (
      .clk      (clk),
      .rst_n    (rst_n),
      .rs1_addr (rs1_addr),
      .rs1_rdata(rs1_rdata),
      .rs2_addr (rs2_addr),
      .rs2_rdata(rs2_rdata),
      .rd_we    (mem_wb_q.rd_we),
      .rd_addr  (mem_wb_q.rd),
      .rd_wdata (wb_data)
  );

  // ---------------------------------------------------------------------------
  // Hazard detection (uses current ID-stage decode + current EX-stage id_ex_q)
  // ---------------------------------------------------------------------------
  id_ex_t id_ex_d, id_ex_q;
  logic   id_ex_flush, id_ex_stall;
  logic   ex_div_stall;
  logic   ex_mem_flush;

  hazard_unit u_hazard_unit (
      .id_ex_mem_rd   (id_ex_q.mem_rd),
      .id_ex_csr_en   (id_ex_q.csr_en),
      .id_ex_rd       (id_ex_q.rd),
      .id_ex_valid    (id_ex_q.valid),
      .if_id_rs1_addr (rs1_addr),
      .if_id_rs2_addr (rs2_addr),
      .if_id_uses_rs1 (uses_rs1),
      .if_id_uses_rs2 (uses_rs2),
      .branch_taken   (branch_taken),
      .ex_div_stall   (ex_div_stall),
      .sys_redirect   (sys_redirect),
      .pc_stall       (pc_stall),
      .if_id_stall    (if_id_stall),
      .if_id_flush    (if_id_flush),
      .id_ex_flush    (id_ex_flush),
      .id_ex_stall    (id_ex_stall),
      .ex_mem_flush   (ex_mem_flush)
  );

  always_comb begin
    id_ex_d                 = '0;
    id_ex_d.pc              = if_id_q.pc;
    id_ex_d.pc4             = if_id_q.pc + 32'd4;
    id_ex_d.rs1_val         = rs1_rdata;
    id_ex_d.rs2_val         = rs2_rdata;
    id_ex_d.imm             = imm;
    id_ex_d.rs1_addr        = rs1_addr;
    id_ex_d.rs2_addr        = rs2_addr;
    id_ex_d.rd              = rd_addr;
    id_ex_d.rd_we           = rd_we;
    id_ex_d.alu_op          = alu_op;
    id_ex_d.alu_src1_is_pc  = alu_src1_is_pc;
    id_ex_d.alu_src2_is_imm = alu_src2_is_imm;
    id_ex_d.br_op           = br_op;
    id_ex_d.is_branch       = is_branch;
    id_ex_d.is_jal          = is_jal;
    id_ex_d.is_jalr         = is_jalr;
    id_ex_d.mem_rd          = mem_rd;
    id_ex_d.mem_wr          = mem_wr;
    id_ex_d.mem_size        = mem_size;
    id_ex_d.mem_signext     = mem_signext;
    id_ex_d.wb_from_mem     = wb_from_mem;
    id_ex_d.wb_from_pc4     = wb_from_pc4;
    id_ex_d.is_amo          = is_amo;
    id_ex_d.amo_op          = amo_op;
    id_ex_d.csr_en          = csr_en;
    id_ex_d.csr_op          = csr_op;
    id_ex_d.csr_use_imm     = csr_use_imm;
    id_ex_d.csr_addr        = csr_addr;
    id_ex_d.is_ecall        = is_ecall;
    id_ex_d.is_ebreak       = is_ebreak;
    id_ex_d.is_mret         = is_mret;
    id_ex_d.illegal_instr   = illegal_instr;
    id_ex_d.valid           = if_id_q.valid;
  end

  id_ex_reg u_id_ex_reg (
      .clk  (clk),
      .rst_n(rst_n),
      .stall(id_ex_stall),
      .flush(id_ex_flush),
      .d    (id_ex_d),
      .q    (id_ex_q)
  );

  // ---------------------------------------------------------------------------
  // EX stage
  // ---------------------------------------------------------------------------
  ex_mem_t ex_mem_d, ex_mem_q;
  fwd_sel_e fwd_a_sel, fwd_b_sel;

  forward_unit u_forward_unit (
      .id_ex_rs1_addr(id_ex_q.rs1_addr),
      .id_ex_rs2_addr(id_ex_q.rs2_addr),
      .ex_mem_rd     (ex_mem_q.rd),
      .ex_mem_rd_we  (ex_mem_q.rd_we),
      .ex_mem_valid  (ex_mem_q.valid),
      .mem_wb_rd     (mem_wb_q.rd),
      .mem_wb_rd_we  (mem_wb_q.rd_we),
      .mem_wb_valid  (mem_wb_q.valid),
      .fwd_a_sel     (fwd_a_sel),
      .fwd_b_sel     (fwd_b_sel)
  );

  execute_stage u_execute_stage (
      .clk           (clk),
      .rst_n         (rst_n),
      .id_ex         (id_ex_q),
      .id_ex_flush   (id_ex_flush),
      .ex_mem_fwd_val(ex_mem_q.alu_result),
      .mem_wb_fwd_val(wb_data),
      .fwd_a_sel     (fwd_a_sel),
      .fwd_b_sel     (fwd_b_sel),
      .branch_taken  (branch_taken),
      .branch_target (branch_target),
      .ex_div_stall  (ex_div_stall),
      .ex_mem_d      (ex_mem_d)
  );

  ex_mem_reg u_ex_mem_reg (
      .clk  (clk),
      .rst_n(rst_n),
      .flush(ex_mem_flush),
      .d    (ex_mem_d),
      .q    (ex_mem_q)
  );

  // ---------------------------------------------------------------------------
  // MEM stage
  // ---------------------------------------------------------------------------
  xlen_t lsu_rdata;
  logic  load_misaligned, store_misaligned;

  lsu u_lsu (
      .clk             (clk),
      .rst_n           (rst_n),
      .addr            (ex_mem_q.alu_result),
      .wdata_in        (ex_mem_q.store_data),
      .mem_rd          (ex_mem_q.mem_rd),
      .mem_wr          (ex_mem_q.mem_wr),
      .mem_size        (ex_mem_q.mem_size),
      .mem_signext     (ex_mem_q.mem_signext),
      .is_amo          (ex_mem_q.is_amo),
      .amo_op          (ex_mem_q.amo_op),
      .dmem_addr       (dmem_addr),
      .dmem_wdata      (dmem_wdata),
      .dmem_wstrb      (dmem_wstrb),
      .dmem_re         (dmem_re),
      .dmem_rdata      (dmem_rdata),
      .rdata           (lsu_rdata),
      .load_misaligned (load_misaligned),
      .store_misaligned(store_misaligned)
  );

  xlen_t csr_rdata_w;
  logic  trap_taken;

  csr u_csr (
      .clk                 (clk),
      .rst_n               (rst_n),
      .pc                  (ex_mem_q.pc),
      .illegal_instr_in    (ex_mem_q.illegal_instr),
      .csr_en              (ex_mem_q.csr_en),
      .csr_op              (ex_mem_q.csr_op),
      .csr_addr            (ex_mem_q.csr_addr),
      .csr_operand         (ex_mem_q.csr_operand),
      .is_ecall            (ex_mem_q.is_ecall),
      .is_ebreak           (ex_mem_q.is_ebreak),
      .is_mret             (ex_mem_q.is_mret),
      .load_misaligned     (load_misaligned),
      .store_misaligned    (store_misaligned),
      .mem_addr            (ex_mem_q.alu_result),
      .csr_rdata           (csr_rdata_w),
      .trap_taken          (trap_taken),
      .sys_redirect        (sys_redirect),
      .sys_redirect_target (sys_redirect_target)
  );

  mem_wb_t mem_wb_d;

  always_comb begin
    mem_wb_d             = '0;
    mem_wb_d.alu_result  = ex_mem_q.alu_result;
    mem_wb_d.mem_rdata   = lsu_rdata;
    mem_wb_d.pc4         = ex_mem_q.pc4;
    mem_wb_d.csr_rdata   = csr_rdata_w;
    mem_wb_d.rd          = ex_mem_q.rd;
    mem_wb_d.rd_we       = ex_mem_q.rd_we && !trap_taken;
    mem_wb_d.wb_from_mem = ex_mem_q.wb_from_mem;
    mem_wb_d.wb_from_pc4 = ex_mem_q.wb_from_pc4;
    mem_wb_d.wb_from_csr = ex_mem_q.csr_en;
    mem_wb_d.valid       = ex_mem_q.valid;
  end

  mem_wb_reg u_mem_wb_reg (
      .clk  (clk),
      .rst_n(rst_n),
      .d    (mem_wb_d),
      .q    (mem_wb_q)
  );

  // ---------------------------------------------------------------------------
  // WB stage
  // ---------------------------------------------------------------------------
  always_comb begin
    if (mem_wb_q.wb_from_mem) wb_data = mem_wb_q.mem_rdata;
    else if (mem_wb_q.wb_from_pc4) wb_data = mem_wb_q.pc4;
    else if (mem_wb_q.wb_from_csr) wb_data = mem_wb_q.csr_rdata;
    else wb_data = mem_wb_q.alu_result;
  end

endmodule
