// =============================================================================
// rtl/core/csr/csr.sv
// =============================================================================
// Bare-minimal M-mode-only CSR file and trap/MRET decision point.
//
// Instantiated in the MEM stage, alongside lsu, so that all synchronous trap
// sources for a given instruction (illegal instruction / ECALL / EBREAK /
// illegal-or-unimplemented CSR access, from decode/EX pass-through; load/
// store misalignment, from lsu in this same cycle) resolve in exactly one
// place. Since decode only ever produces one instruction category at a time
// (SYSTEM opcode xor LOAD/STORE/AMO opcode), these conditions are mutually
// exclusive per instruction — no cross-category priority encoder is needed,
// just an OR.
//
// No interrupt source is wired up yet: mie/mip are plain read/write storage
// with no hardware consumer. mstatus.MIE/MPIE save-restore is implemented
// now (required for MRET round-trip correctness) even though MIE has no
// effect yet — this is the natural hook point for a future interrupt pass.
// =============================================================================

`timescale 1ns / 1ps

module csr (
    input logic clk,
    input logic rst_n,

    // Current MEM-stage instruction (from ex_mem_q)
    input core_pkg::xlen_t    pc,                // faulting/retiring instr's own PC
    input logic                illegal_instr_in,  // decode/EX pass-through
    input logic                csr_en,
    input core_pkg::csr_op_e  csr_op,
    input logic [11:0]         csr_addr,
    input core_pkg::xlen_t    csr_operand,
    input logic                is_ecall,
    input logic                is_ebreak,
    input logic                is_mret,

    // From lsu, same MEM-stage cycle
    input logic                load_misaligned,
    input logic                store_misaligned,
    input core_pkg::xlen_t    mem_addr,  // = ex_mem_q.alu_result, for mtval

    // Outputs
    output core_pkg::xlen_t  csr_rdata,  // old value, for rd writeback
    output logic              trap_taken,
    output logic              sys_redirect,
    output core_pkg::xlen_t  sys_redirect_target
);

  import core_pkg::*;

  // ---------------------------------------------------------------------
  // CSR address map (only the implemented set; everything else illegal).
  // ---------------------------------------------------------------------
  localparam logic [11:0] CsrMstatus = 12'h300;
  localparam logic [11:0] CsrMisa = 12'h301;
  localparam logic [11:0] CsrMie = 12'h304;
  localparam logic [11:0] CsrMtvec = 12'h305;
  localparam logic [11:0] CsrMscratch = 12'h340;
  localparam logic [11:0] CsrMepc = 12'h341;
  localparam logic [11:0] CsrMcause = 12'h342;
  localparam logic [11:0] CsrMtval = 12'h343;
  localparam logic [11:0] CsrMip = 12'h344;
  localparam logic [11:0] CsrMvendorid = 12'hF11;
  localparam logic [11:0] CsrMarchid = 12'hF12;
  localparam logic [11:0] CsrMimpid = 12'hF13;
  localparam logic [11:0] CsrMhartid = 12'hF14;

  // misa = RV32IMA: MXL[31:30]=01 (RV32), Extensions A(0)|I(8)|M(12).
  localparam xlen_t MisaValue = 32'h4000_1101;

  // ---------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------
  logic  mstatus_mie_q, mstatus_mpie_q;
  xlen_t mie_q, mip_q;
  xlen_t mtvec_q, mscratch_q, mepc_q, mcause_q, mtval_q;

  xlen_t mstatus_rdata;
  // bit3=MIE, bit7=MPIE, bits[12:11]=MPP hardwired to 2'b11 (M-mode only,
  // no S/U mode ever entered), all other bits 0.
  // [31:13]=0(19) [12:11]=MPP(2) [10:8]=0(3) [7]=MPIE(1) [6:4]=0(3) [3]=MIE(1) [2:0]=0(3)
  assign mstatus_rdata = {19'b0, 2'b11, 3'b0, mstatus_mpie_q, 3'b0, mstatus_mie_q, 3'b0};

  // ---------------------------------------------------------------------
  // Address decode / read
  // ---------------------------------------------------------------------
  logic csr_addr_known;

  always_comb begin
    csr_addr_known = 1'b1;
    unique case (csr_addr)
      CsrMstatus:   csr_rdata = mstatus_rdata;
      CsrMisa:      csr_rdata = MisaValue;
      CsrMie:       csr_rdata = mie_q;
      CsrMtvec:     csr_rdata = mtvec_q;
      CsrMscratch:  csr_rdata = mscratch_q;
      CsrMepc:      csr_rdata = mepc_q;
      CsrMcause:    csr_rdata = mcause_q;
      CsrMtval:     csr_rdata = mtval_q;
      CsrMip:       csr_rdata = mip_q;
      CsrMvendorid: csr_rdata = 32'd0;
      CsrMarchid:   csr_rdata = 32'd0;
      CsrMimpid:    csr_rdata = 32'd0;
      CsrMhartid:   csr_rdata = 32'd0;
      default: begin
        csr_addr_known = 1'b0;
        csr_rdata      = '0;
      end
    endcase
  end

  // ---------------------------------------------------------------------
  // Illegal-CSR-access checks.
  //
  // csr_addr_readonly follows the architectural read-only-region encoding
  // (addr[11:10]==11) — this is why misa (0x301, addr[11:10]=00) is NOT
  // flagged here even though we implement it as a fixed value: misa is
  // WARL-collapsed-to-one-legal-value (writes are a silent no-op, per
  // spec), whereas mhartid/mvendorid/marchid/mimpid are read-only *by
  // address encoding* and any write attempt to them is architecturally
  // illegal, not just ineffective.
  //
  // csr_write_attempted excludes CSRRS/CSRRC with a zero operand (e.g. the
  // common `csrr rd, csr` pseudo-op, i.e. `csrrs rd, csr, x0`) — that is a
  // pure read with no write side effect, so it must not trip the
  // read-only-region check.
  // ---------------------------------------------------------------------
  logic csr_addr_readonly, csr_write_attempted, csr_illegal;

  assign csr_addr_readonly = (csr_addr[11:10] == 2'b11);
  assign csr_write_attempted = csr_en &&
      ((csr_op == CSR_RW) || (((csr_op == CSR_RS) || (csr_op == CSR_RC)) && (csr_operand != '0)));
  assign csr_illegal = csr_en && (!csr_addr_known || (csr_addr_readonly && csr_write_attempted));

  logic illegal_instr_final;
  assign illegal_instr_final = illegal_instr_in || csr_illegal;

  // ---------------------------------------------------------------------
  // Trap cause selection (mutually exclusive by instruction category — see
  // module header).
  // ---------------------------------------------------------------------
  xlen_t trap_cause, trap_val;
  always_comb begin
    trap_cause = '0;
    trap_val   = '0;
    if (illegal_instr_final) begin
      trap_cause = CAUSE_ILLEGAL_INSTR;
    end else if (is_ecall) begin
      trap_cause = CAUSE_ECALL_M;
    end else if (is_ebreak) begin
      trap_cause = CAUSE_BREAKPOINT;
    end else if (store_misaligned) begin
      trap_cause = CAUSE_STORE_MISALIGNED;
      trap_val   = mem_addr;
    end else if (load_misaligned) begin
      trap_cause = CAUSE_LOAD_MISALIGNED;
      trap_val   = mem_addr;
    end
  end

  assign trap_taken = illegal_instr_final || is_ecall || is_ebreak ||
      store_misaligned || load_misaligned;

  logic mret_taken;
  assign mret_taken = is_mret && !trap_taken;

  assign sys_redirect        = trap_taken || mret_taken;
  assign sys_redirect_target = trap_taken ? {mtvec_q[31:2], 2'b00} : mepc_q;

  // ---------------------------------------------------------------------
  // CSR write value (RW/RS/RC), computed from the pre-write csr_rdata.
  // ---------------------------------------------------------------------
  xlen_t csr_new_value;
  always_comb begin
    unique case (csr_op)
      CSR_RW:  csr_new_value = csr_operand;
      CSR_RS:  csr_new_value = csr_rdata | csr_operand;
      CSR_RC:  csr_new_value = csr_rdata & ~csr_operand;
      default: csr_new_value = csr_rdata;
    endcase
  end

  logic csr_write_en;
  assign csr_write_en = csr_en && !csr_illegal && csr_write_attempted;

  // ---------------------------------------------------------------------
  // Sequential state update.
  // ---------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      mstatus_mie_q  <= 1'b0;
      mstatus_mpie_q <= 1'b0;
      mie_q          <= '0;
      mip_q          <= '0;
      mtvec_q        <= '0;
      mscratch_q     <= '0;
      mepc_q         <= '0;
      mcause_q       <= '0;
      mtval_q        <= '0;
    end else if (trap_taken) begin
      mepc_q         <= {pc[31:2], 2'b00};
      mcause_q       <= trap_cause;
      mtval_q        <= trap_val;
      mstatus_mpie_q <= mstatus_mie_q;
      mstatus_mie_q  <= 1'b0;
    end else if (mret_taken) begin
      mstatus_mie_q  <= mstatus_mpie_q;
      mstatus_mpie_q <= 1'b1;
    end else if (csr_write_en) begin
      unique case (csr_addr)
        CsrMstatus: begin
          mstatus_mie_q  <= csr_new_value[3];
          mstatus_mpie_q <= csr_new_value[7];
        end
        CsrMie:      mie_q      <= csr_new_value;
        CsrMtvec:    mtvec_q    <= {csr_new_value[31:2], 2'b00};
        CsrMscratch: mscratch_q <= csr_new_value;
        CsrMepc:     mepc_q     <= {csr_new_value[31:2], 2'b00};
        CsrMcause:   mcause_q   <= csr_new_value;
        CsrMtval:    mtval_q    <= csr_new_value;
        CsrMip:      mip_q      <= csr_new_value;
        default:     ;  // misa/mvendorid/marchid/mimpid/mhartid: no storage, no-op
      endcase
    end
  end

endmodule
