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
// Timer (MTIP, from CLINT) and external (MEIP, from an external PLIC)
// interrupts are both wired up: mip is a read-only value derived from live
// hardware state (software bit tied to 0 — single hart has no inter-hart
// IPI use for it). An interrupt is taken by reusing the exact same
// trap-entry machinery as a synchronous exception (mepc/mcause/mstatus
// save-restore, sys_redirect to mtvec) — it just gets a new way to
// trigger, checked only when a valid, non-stalled instruction is retiring
// this cycle (so an interrupt never preempts mid-flight AMO
// read-modify-write or a pipeline bubble), with priority MEI > MTI. mie
// stays fully read/write software storage (masks which enabled sources can
// interrupt).
//
// PMP (pmpcfg0-3, pmpaddr0-15) is implemented as plain WARL storage with no
// enforcement — confirmed necessary, not speculative: tracing a real Linux
// boot showed the kernel's early M-mode setup unconditionally executing
// `csrw pmpaddr0, ...` / `csrw pmpcfg0, ...`, which would otherwise
// illegal-instruction-trap. This core DOES enter U-mode now (see priv_q
// below) but still does not enforce PMP range checks — a real gap for
// memory protection/security, but not for boot correctness (no legitimate
// userspace code depends on PMP faulting), so it's left as WARL storage
// only, same as before.
//
// Privilege mode (priv_q, M or U — no S-mode: this core/DTB never declare
// the S extension, and only M/U are needed for a NOMMU Linux port) is real,
// tracked state, not hardwired: mstatus.MPP is genuine read/write storage
// (mstatus_mpp_q), saved with the current privilege on every trap entry and
// restored (then reset to U, the least-privileged supported mode, per the
// xRET spec) on every mret. ECALL's cause is selected from priv_q
// (CAUSE_ECALL_U vs CAUSE_ECALL_M) — this matters because Linux's NOMMU
// M-mode port dispatches on it: cause 8 (ECALL_U) reaches the real syscall
// handler, while cause 11 (ECALL_M) is wired as a fatal error path. Before
// this, MPP was hardwired to M and every ECALL reported cause 11
// unconditionally, so a userspace process's very first syscall (already
// running "in userspace" only by the kernel's own bookkeeping, never
// actually lowered to U-mode in hardware) always looked like a fatal
// exception. Confirmed against remu's own source (not just its README):
// remu tracks a real PrivMode and does exactly this on ecall/mret.
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

    // Interrupt sources / gating
    input logic                mtip,         // from CLINT, live (not registered)
    input logic                meip,         // from PLIC, live (not registered)
    input logic                instr_valid,  // ex_mem_q.valid: a real instruction is retiring
    input logic                is_amo,       // ex_mem_q.is_amo: LR.W/SC.W/AMO*.W, see take_interrupt below

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

  // PMP: pmpcfg0..3 (0x3A0-0x3A3, 16 entries' worth of config bytes) and
  // pmpaddr0..15 (0x3B0-0x3BF) — plain WARL storage, checked by range
  // rather than enumerated individually (see is_pmpcfg/is_pmpaddr below).
  localparam logic [11:0] CsrPmpcfg0Base = 12'h3A0;
  localparam logic [11:0] CsrPmpaddr0Base = 12'h3B0;

  // misa = RV32IMA: MXL[31:30]=01 (RV32), Extensions A(0)|I(8)|M(12).
  localparam xlen_t MisaValue = 32'h4000_1101;

  // ---------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------
  logic  mstatus_mie_q, mstatus_mpie_q;
  logic [1:0] mstatus_mpp_q;
  xlen_t mie_q;
  xlen_t mtvec_q, mscratch_q, mepc_q, mcause_q, mtval_q;
  xlen_t pmpcfg_q[4];
  xlen_t pmpaddr_q[16];

  // Current privilege the core is executing at — 1=M, 0=U (no S-mode; see
  // module header). Reset value M matches the RISC-V spec's reset state.
  logic priv_m_q;

  xlen_t mstatus_rdata;
  // bit3=MIE, bit7=MPIE, bits[12:11]=MPP (real storage, mstatus_mpp_q), all
  // other bits 0.
  // [31:13]=0(19) [12:11]=MPP(2) [10:8]=0(3) [7]=MPIE(1) [6:4]=0(3) [3]=MIE(1) [2:0]=0(3)
  assign mstatus_rdata = {19'b0, mstatus_mpp_q, 3'b0, mstatus_mpie_q, 3'b0, mstatus_mie_q, 3'b0};

  // mip is read-only, derived live from hardware interrupt sources — never
  // software-writable (a real hart only ever lets software clear MTIP/MEIP
  // indirectly, by servicing the CLINT/PLIC directly). bit3=MSIP, bit7=
  // MTIP, bit11=MEIP; MSIP tied to 0 (single hart has no inter-hart IPI
  // use for software interrupts).
  xlen_t mip_rdata;
  assign mip_rdata = {20'b0, meip, 3'b0, mtip, 3'b0, 1'b0, 3'b0};

  // ---------------------------------------------------------------------
  // Address decode / read
  // ---------------------------------------------------------------------
  logic csr_addr_known;
  logic is_pmpcfg, is_pmpaddr;
  assign is_pmpcfg  = (csr_addr >= CsrPmpcfg0Base) && (csr_addr <= (CsrPmpcfg0Base + 12'd3));
  assign is_pmpaddr = (csr_addr >= CsrPmpaddr0Base) && (csr_addr <= (CsrPmpaddr0Base + 12'd15));

  always_comb begin
    csr_addr_known = 1'b1;
    if (is_pmpcfg) begin
      csr_rdata = pmpcfg_q[csr_addr[1:0]];
    end else if (is_pmpaddr) begin
      csr_rdata = pmpaddr_q[csr_addr[3:0]];
    end else begin
      unique case (csr_addr)
        CsrMstatus:   csr_rdata = mstatus_rdata;
        CsrMisa:      csr_rdata = MisaValue;
        CsrMie:       csr_rdata = mie_q;
        CsrMtvec:     csr_rdata = mtvec_q;
        CsrMscratch:  csr_rdata = mscratch_q;
        CsrMepc:      csr_rdata = mepc_q;
        CsrMcause:    csr_rdata = mcause_q;
        CsrMtval:     csr_rdata = mtval_q;
        CsrMip:       csr_rdata = mip_rdata;
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
  // Every CSR this core implements is M-mode-only by its architectural
  // address encoding (addr[9:8]==2'b11) — pmpcfg/pmpaddr, mstatus, and the
  // rest all fall in that range, and nothing U-mode-accessible (e.g. no
  // cycle/time/instret) is implemented. Now that priv_m_q is real tracked
  // state instead of hardwired M, any CSR instruction executed from U-mode
  // must trap illegal — no legitimate userspace code should ever execute
  // one, but this closes the gap per spec now that it's actually reachable.
  assign csr_illegal = csr_en &&
      (!csr_addr_known || (csr_addr_readonly && csr_write_attempted) || !priv_m_q);

  // mret is privileged (M-mode-only) same as every CSR above — executing it
  // from U-mode must trap illegal rather than actually returning, though in
  // practice Linux never issues mret from userspace, so this is spec
  // completeness rather than something boot correctness depends on.
  logic mret_priv_illegal;
  assign mret_priv_illegal = is_mret && !priv_m_q;

  logic illegal_instr_final;
  assign illegal_instr_final = illegal_instr_in || csr_illegal || mret_priv_illegal;

  // ---------------------------------------------------------------------
  // Interrupt-taken: reuses the exact same trap-entry machinery below
  // (mepc<=pc, mcause, mstatus save-restore, sys_redirect to mtvec) as a
  // synchronous exception — it's just a different way to set trap_cause.
  // Gated on instr_valid && !is_amo so an interrupt only ever preempts a
  // genuine, fully-retiring, non-AMO instruction (never a bubble, and
  // never any LR.W/SC.W/AMO*.W). This has to cover ALL of RV32A, not just
  // the read-modify-write AMOs that need lsu.sv's 2-phase amo_stall:
  // whichever of LR.W/SC.W/AMO*.W is in ex_mem_q this cycle has already
  // committed its side effect (reservation set, memory write, or
  // reservation clear) combinationally this same cycle, regardless of
  // what ex_mem_flush does to ex_mem_q next cycle. Taking an interrupt
  // anyway would set mepc to this instruction's own PC, and mret would
  // replay it -- for AMO*.W that means executing the read-modify-write a
  // second time (double-corrupting whatever counter it updates); for a
  // SUCCESSFUL SC.W it means the replay spuriously fails (the reservation
  // the first, real success already consumed is gone), so the calling
  // software never learns its store actually landed and treats an
  // already-acquired lock as still contended forever. Found via a real Linux
  // boot: a timer interrupt landing on a successful SC.W's own retire
  // cycle (inside down_write()'s fast-path cmpxchg) replayed it into a
  // spurious failure, sending a already-satisfied lock acquisition into
  // rwsem's slow path to sleep for a wakeup nobody would ever send —
  // system-wide deadlock. Blocking on the full is_amo (not just amo_stall,
  // which is phase-0-only and doesn't even cover LR.W/SC.W at all) closes
  // this for every RV32A instruction uniformly. Already mutually exclusive
  // with the synchronous causes below (trap_taken_sync), so no separate
  // priority encoder is needed between them.
  // ---------------------------------------------------------------------
  logic trap_taken_sync;
  assign trap_taken_sync = illegal_instr_final || is_ecall || is_ebreak ||
      store_misaligned || load_misaligned;

  // Priority MEI > MTI (MSI unimplemented — see mip_rdata comment above).
  logic mei_pending, mti_pending, interrupt_pending, take_interrupt;
  assign mei_pending      = meip && mie_q[11];
  assign mti_pending      = mtip && mie_q[7];
  assign interrupt_pending = mstatus_mie_q && (mei_pending || mti_pending);
  assign take_interrupt = instr_valid && !is_amo && !trap_taken_sync && interrupt_pending;

  // ---------------------------------------------------------------------
  // Trap cause selection (mutually exclusive by instruction category — see
  // module header — plus take_interrupt, itself mutually exclusive with
  // all synchronous causes by construction above).
  // ---------------------------------------------------------------------
  xlen_t trap_cause, trap_val;
  always_comb begin
    trap_cause = '0;
    trap_val   = '0;
    if (take_interrupt) begin
      trap_cause = mei_pending ? CAUSE_M_EXTERNAL_INT : CAUSE_M_TIMER_INT;
    end else if (illegal_instr_final) begin
      trap_cause = CAUSE_ILLEGAL_INSTR;
    end else if (is_ecall) begin
      trap_cause = priv_m_q ? CAUSE_ECALL_M : CAUSE_ECALL_U;
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

  assign trap_taken = trap_taken_sync || take_interrupt;

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
      mstatus_mpp_q  <= 2'b11;
      priv_m_q       <= 1'b1;
      mie_q          <= '0;
      mtvec_q        <= '0;
      mscratch_q     <= '0;
      mepc_q         <= '0;
      mcause_q       <= '0;
      mtval_q        <= '0;
      for (int i = 0; i < 4; i++) pmpcfg_q[i] <= '0;
      for (int i = 0; i < 16; i++) pmpaddr_q[i] <= '0;
    end else if (trap_taken) begin
      mepc_q         <= {pc[31:2], 2'b00};
      mcause_q       <= trap_cause;
      mtval_q        <= trap_val;
      mstatus_mpie_q <= mstatus_mie_q;
      mstatus_mie_q  <= 1'b0;
      // Save the privilege the trap interrupted, then traps always land in
      // M-mode (no S-mode to delegate to).
      mstatus_mpp_q  <= priv_m_q ? 2'b11 : 2'b00;
      priv_m_q       <= 1'b1;
    end else if (mret_taken) begin
      mstatus_mie_q  <= mstatus_mpie_q;
      mstatus_mpie_q <= 1'b1;
      // Restore the privilege mret is returning to, then per the xRET spec
      // MPP is reset to the least-privileged supported mode (U) — anything
      // other than 2'b11 is treated as U, a safe default for a reserved/
      // unsupported encoding (e.g. 2'b01/2'b10, S-mode/reserved, neither of
      // which this core implements).
      priv_m_q       <= (mstatus_mpp_q == 2'b11);
      mstatus_mpp_q  <= 2'b00;
    end else if (csr_write_en) begin
      if (is_pmpcfg) begin
        pmpcfg_q[csr_addr[1:0]] <= csr_new_value;
      end else if (is_pmpaddr) begin
        pmpaddr_q[csr_addr[3:0]] <= csr_new_value;
      end else begin
        unique case (csr_addr)
          CsrMstatus: begin
            mstatus_mie_q  <= csr_new_value[3];
            mstatus_mpie_q <= csr_new_value[7];
            // WARL: only M(2'b11)/U(2'b00) are legal MPP encodings on this
            // core (no S-mode) — any other attempted value (S=2'b01,
            // reserved=2'b10) must collapse to a supported one, not be
            // stored verbatim. This isn't just spec pedantry: riscv-tests'
            // own boilerplate (rv64mi/illegal.S) writes MPP=S and reads it
            // back specifically to detect "is S-mode present," expecting
            // the readback to NOT show S when it isn't — storing the raw
            // value verbatim made that probe wrongly conclude S-mode was
            // present and fall into test code exercising sstatus/satp/etc,
            // which this core doesn't implement.
            mstatus_mpp_q  <= (csr_new_value[12:11] == 2'b11) ? 2'b11 : 2'b00;
          end
          CsrMie:      mie_q      <= csr_new_value;
          CsrMtvec:    mtvec_q    <= {csr_new_value[31:2], 2'b00};
          CsrMscratch: mscratch_q <= csr_new_value;
          CsrMepc:     mepc_q     <= {csr_new_value[31:2], 2'b00};
          CsrMcause:   mcause_q   <= csr_new_value;
          CsrMtval:    mtval_q    <= csr_new_value;
          default:     ;  // misa/mip/mvendorid/marchid/mimpid/mhartid: no storage, no-op
        endcase
      end
    end
  end

endmodule
