// =============================================================================
// rtl/core/lsu/lsu.sv
// =============================================================================
// Load/store unit: byte/halfword/word addressing on a 32-bit-wide,
// word-addressed data memory port (combinational read, byte-strobed write,
// same zero-wait-state assumption as the instruction memory port).
//
// Assumes naturally aligned accesses (no misaligned-access support/trap,
// consistent with "no CSR / no exceptions yet" scope).
// =============================================================================

`timescale 1ns / 1ps

module lsu (
    input core_pkg::xlen_t     addr,      // byte address (alu_result)
    input core_pkg::xlen_t     wdata_in,  // store data (rs2, forwarded)
    input logic                mem_rd,
    input logic                mem_wr,
    input core_pkg::mem_size_e mem_size,
    input logic                mem_signext,

    // Data memory port
    output core_pkg::xlen_t dmem_addr,
    output core_pkg::xlen_t dmem_wdata,
    output logic      [3:0] dmem_wstrb,
    output logic             dmem_re,
    input  core_pkg::xlen_t dmem_rdata,

    output core_pkg::xlen_t rdata
);

  import core_pkg::*;

  logic [1:0] byte_off;
  assign byte_off  = addr[1:0];
  assign dmem_addr = {addr[31:2], 2'b00};
  assign dmem_re    = mem_rd;

  // -------------------------------------------------------------------------
  // Write path: replicate + position store data, generate byte strobes.
  // -------------------------------------------------------------------------
  always_comb begin
    dmem_wdata = '0;
    dmem_wstrb = 4'b0000;

    if (mem_wr) begin
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

  // -------------------------------------------------------------------------
  // Read path: extract + sign/zero extend.
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

    unique case (mem_size)
      MSZ_B: rdata = mem_signext ? xlen_t'({{24{rbyte[7]}}, rbyte}) : xlen_t'({24'b0, rbyte});
      MSZ_H: rdata = mem_signext ? xlen_t'({{16{rhalf[15]}}, rhalf}) : xlen_t'({16'b0, rhalf});
      default: rdata = dmem_rdata;  // MSZ_W
    endcase
  end

endmodule
