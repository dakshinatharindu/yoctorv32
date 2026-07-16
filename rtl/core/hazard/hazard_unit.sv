// =============================================================================
// rtl/core/hazard/hazard_unit.sv
// =============================================================================
// Detects load-use hazards and branch/jump mispredicts, and generates the
// stall/flush controls for the pipeline registers.
//
// Load-use hazard: the instruction currently in EX (ID/EX) is a load or a
// CSR read whose destination is needed (as rs1 or rs2) by the instruction
// currently being decoded (IF/ID). Both loads and CSR reads produce their
// result in the MEM stage (lsu/csr), one stage later than a normal ALU op,
// so the EX/MEM forwarding path (which only carries alu_result) cannot
// supply it to an immediately-following consumer — resolved by stalling
// PC/IF-ID for one cycle and bubbling ID/EX; the value is then available
// via MEM/WB forwarding.
//
// Branch/jump mispredict: resolved combinationally in EX. Squashes the
// instruction currently in ID (about to enter ID/EX) and the one currently
// being fetched (about to enter IF/ID), and redirects the PC.
//
// pc_stall and if_id_stall share one cycle-for-cycle formula on purpose:
// the extra in-flight instruction that a synchronous-read imem's 1-cycle
// latency leaves stuck ahead of if_id_reg when a stall begins is preserved
// by a skid buffer in core_top.sv (see if_id_d there), not by stretching
// the stall itself — stretching it just discards a different instruction
// instead (verified the hard way; see core_top.sv's comment for the trace).
// =============================================================================

`timescale 1ns / 1ps

module hazard_unit (
    // State of the instruction currently in ID/EX (EX stage)
    input logic                id_ex_mem_rd,
    input logic                id_ex_csr_en,
    input core_pkg::reg_addr_t id_ex_rd,
    input logic                id_ex_valid,

    // State of the instruction currently in IF/ID (ID stage)
    input core_pkg::reg_addr_t if_id_rs1_addr,
    input core_pkg::reg_addr_t if_id_rs2_addr,
    input logic                if_id_uses_rs1,
    input logic                if_id_uses_rs2,

    // Branch/jump resolution from EX stage
    input logic branch_taken,

    // RV32M: divider busy in EX (structural hazard — id_ex_q must hold the
    // DIV/REM instruction in place, not advance to a bubble like a
    // load-use hazard does).
    input logic ex_div_stall,

    // RV32A: AMO*.W read-modify-write in MEM needs its address held for one
    // extra cycle so the deferred write can reuse it once dmem_rdata's old
    // value has arrived (lsu.sv). Structurally the same idea as
    // ex_div_stall, but the held instruction lives in ex_mem_q, not id_ex_q.
    input logic amo_stall,

    // Trap/MRET redirect from csr.sv (MEM stage) — an older instruction
    // than anything currently in IF/ID/EX, so it must squash all three.
    input logic sys_redirect,

    output logic pc_stall,
    output logic if_id_stall,
    output logic if_id_flush,
    output logic id_ex_flush,
    output logic id_ex_stall,
    output logic ex_mem_flush,
    output logic ex_mem_stall
);

  logic load_use_hazard;

  assign load_use_hazard = id_ex_valid && (id_ex_mem_rd || id_ex_csr_en) && (id_ex_rd != '0) &&
      ((if_id_uses_rs1 && (if_id_rs1_addr == id_ex_rd)) ||
       (if_id_uses_rs2 && (if_id_rs2_addr == id_ex_rd)));

  assign pc_stall    = load_use_hazard || ex_div_stall || amo_stall;
  assign if_id_stall = load_use_hazard || ex_div_stall || amo_stall;

  assign if_id_flush = branch_taken || sys_redirect;

  // load_use_hazard is gated on !ex_div_stall/!amo_stall: id_ex_q can be
  // BOTH a load-use hazard's producer (its own rd matches if_id's rs1/rs2)
  // AND the instruction a structural stall is holding in place there at the
  // same time (e.g. a load sitting behind an AMO's deferred write-back
  // cycle) — id_ex_reg gives flush priority over stall, so without this
  // gate the flush would win and zero out id_ex_q, silently discarding the
  // very instruction amo_stall/ex_div_stall was trying to preserve. Found
  // via a real Linux boot: an AMO immediately followed by a load whose
  // result fed another load one instruction later lost the first load
  // entirely. Once the structural stall clears, id_ex_q's content is
  // whatever amo_stall/ex_div_stall was holding — load_use_hazard gets
  // re-evaluated fresh against it next cycle, so nothing is skipped, just
  // deferred until it's safe to flush.
  //
  // branch_taken needs the exact same !amo_stall gate, for a different but
  // structurally identical reason: ex_mem_stall is driven solely by
  // amo_stall, so while an older AMO is being held in ex_mem_q, ex_mem_reg
  // will not accept id_ex_q's instruction no matter what it is. If id_ex_q
  // currently holds a taken branch/jump, flushing it here (unconditionally
  // on branch_taken) discards that instruction's own result a cycle before
  // ex_mem_q is ever able to receive it — id_ex_stall (which already
  // includes amo_stall) holds id_ex_q's *content* in place, but without
  // this gate the flush still wins and zeroes it anyway. Found via a real
  // Linux boot: a `jal` immediately behind an AMO-holding cycle never wrote
  // its return address, leaving `ra` stale; a later `ret` used that stale
  // address and jumped into the middle of an unrelated loop. Same recovery
  // as above — once amo_stall clears, branch_taken is re-evaluated fresh
  // against the still-held id_ex_q, so the flush merely happens one cycle
  // later, not never.
  assign id_ex_flush = (load_use_hazard && !ex_div_stall && !amo_stall) ||
      (branch_taken && !amo_stall) || sys_redirect;

  // Not OR'd with load_use_hazard: load-use needs id_ex_q to advance to a
  // bubble while the load proceeds into EX; div-stall/amo-stall need id_ex_q
  // to hold the instruction behind the multi-cycle op in place instead.
  assign id_ex_stall = ex_div_stall || amo_stall;

  // A MEM-stage trap/MRET redirect is strictly older than whatever is
  // currently in ex_mem_q's producing instruction (id_ex_q, this cycle's EX
  // instruction) — that instruction must never reach MEM/WB.
  assign ex_mem_flush = sys_redirect;

  // Hold ex_mem_q in place for the AMO*.W read-issue cycle (see amo_stall's
  // port comment) — flush still takes priority in ex_mem_reg, so a
  // misaligned/trapping AMO aborts via sys_redirect with no special-casing.
  assign ex_mem_stall = amo_stall;

endmodule
