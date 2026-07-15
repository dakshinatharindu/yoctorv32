// =============================================================================
// rtl/core/ifetch/ifetch.sv
// =============================================================================
// IF stage: program counter + synchronous-read instruction memory port.
//
// Instruction memory is assumed to be synchronous-read (one cycle of
// latency between imem_addr and the matching imem_rdata — the same timing
// a real FPGA Block RAM presents, e.g. Xilinx BRAM/Intel M20K registered
// output). Because of that latency, the PC that pairs with the arriving
// imem_rdata is one cycle behind pc_q (whatever pc_q was when that fetch's
// address was actually driven) — fetch_pc_q tracks that delayed PC so
// if_id_reg latches a correctly time-aligned {pc, instr} pair.
//
// A branch/trap redirect discovered while a fetch is already in flight
// produces two wrong-path arrivals under 1-cycle memory latency (the one
// already in flight when the redirect is discovered, and the one issued
// the following cycle using the not-yet-updated pc_q) — both are squashed
// via the `valid` output rather than a separate flush signal, so
// hazard_unit/if_id_reg need no changes for this.
//
// PC update priority: trap/MRET redirect > branch/jump redirect >
// stall (load-use hazard) > pc+4. A trap/MRET redirect comes from an older
// instruction (MEM stage) than a branch mispredict (EX stage), and must
// also override a same-cycle stall.
//
// fetch_pc_q/redirect_q are UNCONDITIONAL 1-cycle delays of pc_q /
// (branch_taken||sys_redirect) — no stall gating of their own. The memory
// doesn't know or care whether the core considers itself "stalled": it
// simply returns data for whatever address was actually driven the
// previous cycle, every cycle, unconditionally. Gating fetch_pc_q by the
// stall condition (as an earlier version of this file did) desyncs it from
// imem_addr whenever a stall's own duration differs by even one cycle
// between when pc_q holds and when fetch_pc_q's gate evaluates — pc_q can
// end up presenting the same (held) address on two consecutive cycles
// while fetch_pc_q, having stopped updating, no longer reflects it,
// silently skipping the instruction at that address. An unconditional
// 1-cycle delay has no such gap: it always reflects pc_q exactly one cycle
// later, matching the memory's own timing exactly, regardless of stalls.
// =============================================================================

`timescale 1ns / 1ps

module ifetch (
    input logic clk,
    input logic rst_n,

    // Pipeline control
    input logic             stall,          // hold PC (load-use hazard)
    input logic             branch_taken,   // redirect from EX stage
    input core_pkg::xlen_t  branch_target,
    input logic             sys_redirect,        // trap/MRET redirect from csr.sv (MEM stage)
    input core_pkg::xlen_t  sys_redirect_target,

    // Instruction memory port (synchronous read: imem_rdata reflects the
    // imem_addr driven one cycle earlier)
    output core_pkg::xlen_t imem_addr,
    input  core_pkg::xlen_t imem_rdata,

    // To IF/ID register
    output core_pkg::xlen_t pc,
    output core_pkg::xlen_t instr,
    output logic            valid
);

  import core_pkg::*;

  xlen_t pc_q;
  xlen_t fetch_pc_q;  // pc_q, delayed 1 cycle -- pairs with imem_rdata
  logic  redirect_q;  // was a redirect taken on the previous cycle?

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) pc_q <= RESET_PC;
    else if (sys_redirect) pc_q <= sys_redirect_target;
    else if (branch_taken) pc_q <= branch_target;
    else if (!stall) pc_q <= pc_q + 32'd4;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      fetch_pc_q <= RESET_PC;
      redirect_q <= 1'b0;
    end else begin
      fetch_pc_q <= pc_q;
      redirect_q <= branch_taken || sys_redirect;
    end
  end

  assign valid     = !(branch_taken || sys_redirect || redirect_q);

  assign pc        = fetch_pc_q;
  assign imem_addr = pc_q;
  // A squashed (wrong-path) arrival must be a genuine NOP, not just
  // valid=0 — nothing downstream (decode.sv, execute_stage.sv's ex_mem_d
  // construction) actually gates mem_wr/rd_we/branch effects on .valid;
  // they act on whatever garbage instruction bits are present. Same
  // invariant if_id_reg's own flush path already relies on.
  assign instr     = valid ? imem_rdata : NOP_INSTR;

endmodule
