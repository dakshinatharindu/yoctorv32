// =============================================================================
// rtl/core/lsu/load_align.sv
// =============================================================================
// WB-stage load value formatter: byte/halfword extraction + sign/zero
// extension, and RV32A's special-cased results (SC.W's success/fail code;
// LR.W/AMO*.W just want the raw word, i.e. the pre-operation old value).
//
// Lives one pipeline stage later than lsu.sv on purpose: dmem_rdata is
// synchronous-read (one cycle of latency after dmem_addr), so the data for
// the instruction currently in mem_wb_q — one stage behind the instruction
// that drove dmem_addr from ex_mem_q — is exactly what's arriving on
// dmem_rdata this same cycle. That natural MEM->WB register gap is the
// memory's read latency, so this needs no stall of its own.
// =============================================================================

`timescale 1ns / 1ps

module load_align (
    input core_pkg::xlen_t     dmem_rdata,
    input logic [1:0]          byte_off,  // mem_wb_q.alu_result[1:0]
    input core_pkg::mem_size_e mem_size,
    input logic                mem_signext,
    input logic                is_amo,
    input core_pkg::amo_op_e   amo_op,
    input logic                sc_success,

    output core_pkg::xlen_t rdata
);

  import core_pkg::*;

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
