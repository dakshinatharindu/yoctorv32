// =============================================================================
// rtl/core/lsu/lsu.sv
// =============================================================================
// Load/store unit: byte/halfword/word addressing on a 32-bit-wide,
// word-addressed data memory port. dmem_rdata is synchronous-read (one
// cycle of latency after dmem_addr — the same timing a real FPGA Block RAM
// presents); dmem_wstrb is a same-cycle synchronous write, applied at the
// next clock edge, same as any ordinary synchronous RAM.
//
// Load value decoding (byte/halfword extraction, sign-extension, SC's
// success/fail code) is NOT done here — dmem_rdata for the address this
// cycle's instruction just issued isn't valid yet. That's done one stage
// later by rtl/core/lsu/load_align.sv, fed by mem_wb_q's carried control
// bits + dmem_rdata once it has genuinely arrived; the natural MEM->WB
// pipeline register gap is exactly the memory's read latency, so plain
// loads need no stall at all.
//
// RV32A (LR.W/SC.W/AMO*.W): LR.W is a plain load plus a reservation set (no
// dependency on read timing). SC.W's success/failure and its write are
// decided purely from the reservation state, never from reading memory, so
// it also needs no extra cycle. AMO*.W (SWAP/ADD/XOR/AND/OR/MIN/MAX/MINU/
// MAXU) is a genuine read-modify-write and is the one operation that can't
// be single-cycle anymore once reads have latency: the old value needed to
// compute the write isn't available until the cycle after the read is
// issued. Handled as a 2-phase sequence (amo_phase_q) that asserts
// amo_stall for exactly the read-issue cycle, holding ex_mem_q (via the new
// stall port on ex_mem_reg) so the same address is still presented on the
// write-issue cycle, once dmem_rdata holds the pre-write value. Structurally
// the same idea as div_unit's multi-cycle stall, just living in MEM instead
// of EX.
// =============================================================================

`timescale 1ns / 1ps

module lsu (
    input logic clk,
    input logic rst_n,

    input core_pkg::xlen_t     addr,      // byte address (alu_result)
    input core_pkg::xlen_t     wdata_in,  // store data (rs2, forwarded)
    input logic                mem_rd,
    input logic                mem_wr,
    input core_pkg::mem_size_e mem_size,

    // RV32A
    input logic             is_amo,
    input core_pkg::amo_op_e amo_op,

    // Data memory port
    output core_pkg::xlen_t dmem_addr,
    output core_pkg::xlen_t dmem_wdata,
    output logic      [3:0] dmem_wstrb,
    output logic             dmem_re,
    input  core_pkg::xlen_t dmem_rdata,

    // Misalignment (feeds csr.sv's trap decision in the same MEM cycle)
    output logic load_misaligned,
    output logic store_misaligned,

    // RV32A: SC.W success/failure, known immediately (no dmem_rdata
    // dependency) -- carried forward for load_align to produce SC's result.
    output logic sc_success,

    // RV32A: structural stall for AMO*.W's deferred read-modify-write.
    output logic amo_stall
);

  import core_pkg::*;

  logic [1:0] byte_off;
  assign byte_off  = addr[1:0];
  assign dmem_addr = {addr[31:2], 2'b00};
  assign dmem_re    = mem_rd;

  // -------------------------------------------------------------------------
  // Misalignment detection. Byte accesses are never misaligned. mem_size is
  // already forced to MSZ_W for every AMO/LR/SC by decode.sv, so this single
  // case also covers AMO alignment with no extra is_amo plumbing. SC.W/
  // AMO*.W read-modify-write have mem_rd=1 AND mem_wr=1 (decode.sv), so both
  // outputs fire together on those, which correctly resolves to the
  // conventional Store/AMO trap cause once csr.sv checks store_misaligned
  // before load_misaligned; LR.W has mem_wr=0 so only load_misaligned fires.
  // -------------------------------------------------------------------------
  logic misaligned;
  always_comb begin
    unique case (mem_size)
      MSZ_B:   misaligned = 1'b0;
      MSZ_H:   misaligned = addr[0];
      MSZ_W:   misaligned = |addr[1:0];
      default: misaligned = 1'b0;
    endcase
  end

  assign load_misaligned  = mem_rd && misaligned;
  assign store_misaligned = mem_wr && misaligned;

  // -------------------------------------------------------------------------
  // RV32A: LR/SC reservation (single global reservation set, word
  // granularity). SC always invalidates the reservation, success or fail.
  // A plain store or AMO write that hits the reserved address also
  // invalidates it — required even for a single hart, since the spec's
  // invalidation rule is written in terms of "any write to the reservation
  // set," not "any write by another hart."
  // -------------------------------------------------------------------------
  logic  resv_valid_q;
  xlen_t resv_addr_q;

  logic amo_rmw_pending;  // AMO ops that unconditionally read-modify-write
  assign amo_rmw_pending = is_amo && (amo_op != AMO_LR) && (amo_op != AMO_SC);

  assign sc_success = resv_valid_q && (resv_addr_q == dmem_addr);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      resv_valid_q <= 1'b0;
      resv_addr_q  <= '0;
    end else if (is_amo && amo_op == AMO_LR) begin
      resv_valid_q <= 1'b1;
      resv_addr_q  <= dmem_addr;
    end else if (is_amo && amo_op == AMO_SC) begin
      resv_valid_q <= 1'b0;
    end else if (resv_valid_q && (mem_wr || amo_rmw_pending) && (dmem_addr == resv_addr_q)) begin
      resv_valid_q <= 1'b0;
    end
  end

  // -------------------------------------------------------------------------
  // AMO*.W 2-phase read-modify-write.
  // Phase 0 (amo_phase_q=0): address+read issued this cycle (same as any
  // load); amo_stall=1 holds ex_mem_q (and everything upstream) so the same
  // instruction — and hence the same dmem_addr — is still present next
  // cycle. The write must not fire yet: dmem_rdata this cycle is stale
  // (reflects whatever was addressed last cycle, not this AMO).
  // Phase 1 (amo_phase_q=1): ex_mem_q held constant, so dmem_addr is
  // unchanged; dmem_rdata now holds the genuine pre-write value for this
  // address, so amo_alu's result is written this cycle. amo_stall
  // deasserts, letting the pipeline advance normally starting next cycle.
  // -------------------------------------------------------------------------
  logic amo_phase_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) amo_phase_q <= 1'b0;
    else if (amo_rmw_pending && !amo_phase_q) amo_phase_q <= 1'b1;
    else amo_phase_q <= 1'b0;
  end

  assign amo_stall = amo_rmw_pending && !amo_phase_q;

  xlen_t amo_new_data;

  amo_alu u_amo_alu (
      .old_data(dmem_rdata),
      .rs2_data(wdata_in),
      .amo_op  (amo_op),
      .new_data(amo_new_data)
  );

  // -------------------------------------------------------------------------
  // Write path: replicate + position store data, generate byte strobes.
  // -------------------------------------------------------------------------
  always_comb begin
    dmem_wdata = '0;
    dmem_wstrb = 4'b0000;

    if (!misaligned) begin
      if (is_amo) begin
        unique case (amo_op)
          AMO_LR: begin
            // Read-only: no write.
          end
          AMO_SC: begin
            dmem_wdata = wdata_in;
            dmem_wstrb = sc_success ? 4'b1111 : 4'b0000;
          end
          default: begin  // AMO*.W read-modify-write: only write on phase 1,
                          // once dmem_rdata genuinely holds the old value.
            if (amo_phase_q) begin
              dmem_wdata = amo_new_data;
              dmem_wstrb = 4'b1111;
            end
          end
        endcase
      end else if (mem_wr) begin
        unique case (mem_size)
          MSZ_B: begin
            dmem_wdata = {4{wdata_in[7:0]}};
            dmem_wstrb = 4'b0001 << byte_off;
          end
          MSZ_H: begin
            dmem_wdata = {2{wdata_in[15:0]}};
            dmem_wstrb = byte_off[1] ? 4'b1100 : 4'b0011;
          end
          default: begin  // MSZ_W
            dmem_wdata = wdata_in;
            dmem_wstrb = 4'b1111;
          end
        endcase
      end
    end
  end

endmodule
