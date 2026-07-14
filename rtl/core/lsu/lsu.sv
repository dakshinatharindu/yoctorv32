// =============================================================================
// rtl/core/lsu/lsu.sv
// =============================================================================
// Load/store unit: byte/halfword/word addressing on a 32-bit-wide,
// word-addressed data memory port (combinational read, byte-strobed write,
// same zero-wait-state assumption as the instruction memory port).
//
// Assumes naturally aligned accesses (no misaligned-access support/trap,
// consistent with "no CSR / no exceptions yet" scope).
//
// RV32A (LR.W/SC.W/AMO*.W): completed in a single cycle by exploiting the
// same zero-wait-state model — dmem_rdata is a pure combinational read and
// the memory write is a same-edge non-blocking assignment (see core_tb.sv),
// so a combinational read and a same-edge write to the same address are
// guaranteed to see the pre-write ("old") value on the read side. This is
// exactly how the plain store path already works here; AMO just computes
// dmem_wdata from dmem_rdata instead of from wdata_in directly. This is
// fragile to the memory model: a real synchronous (1-cycle-latency) BRAM
// would need a genuine multi-cycle MEM stage for AMO, analogous to
// div_unit's stall.
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
    input logic                mem_signext,

    // RV32A
    input logic             is_amo,
    input core_pkg::amo_op_e amo_op,

    // Data memory port
    output core_pkg::xlen_t dmem_addr,
    output core_pkg::xlen_t dmem_wdata,
    output logic      [3:0] dmem_wstrb,
    output logic             dmem_re,
    input  core_pkg::xlen_t dmem_rdata,

    output core_pkg::xlen_t rdata,

    // Misalignment (feeds csr.sv's trap decision in the same MEM cycle)
    output logic load_misaligned,
    output logic store_misaligned
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

  logic amo_rmw_write;  // AMO ops that unconditionally read-modify-write
  assign amo_rmw_write = is_amo && (amo_op != AMO_LR) && (amo_op != AMO_SC);

  logic sc_success;
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
    end else if (resv_valid_q && (mem_wr || amo_rmw_write) && (dmem_addr == resv_addr_q)) begin
      resv_valid_q <= 1'b0;
    end
  end

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
          default: begin  // AMO*.W read-modify-write
            dmem_wdata = amo_new_data;
            dmem_wstrb = 4'b1111;
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

  // -------------------------------------------------------------------------
  // Read path: extract + sign/zero extend (AMO/LR/SC are always word-sized,
  // so they fall out of the existing MSZ_W path with rdata = dmem_rdata,
  // except SC which returns a success/fail code instead of a memory value).
  // -------------------------------------------------------------------------
  logic [ 7:0] rbyte;
  logic [15:0] rhalf;

  always_comb begin
    unique case (byte_off)
      2'b00:   rbyte = dmem_rdata[7:0];
      2'b01:   rbyte = dmem_rdata[15:8];
      2'b10:   rbyte = dmem_rdata[23:16];
      2'b11:   rbyte = dmem_rdata[31:24];
      default: rbyte = dmem_rdata[7:0];
    endcase

    rhalf = byte_off[1] ? dmem_rdata[31:16] : dmem_rdata[15:0];

    if (is_amo && amo_op == AMO_SC) begin
      rdata = sc_success ? xlen_t'(32'd0) : xlen_t'(32'd1);
    end else begin
      unique case (mem_size)
        MSZ_B: rdata = mem_signext ? xlen_t'({{24{rbyte[7]}}, rbyte}) : xlen_t'({24'b0, rbyte});
        MSZ_H: rdata = mem_signext ? xlen_t'({{16{rhalf[15]}}, rhalf}) : xlen_t'({16'b0, rhalf});
        default: rdata = dmem_rdata;  // MSZ_W (also covers LR/AMO-RMW: old value)
      endcase
    end
  end

endmodule
