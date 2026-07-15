// =============================================================================
// rtl/interconnect/data_bus.sv
// =============================================================================
// Minimal 2-way address-range decoder/mux for the CPU's data-memory port,
// routing between external RAM and the CLINT peripheral. Both targets are
// synchronous-read (1-cycle latency, matching core_top's existing dmem
// assumption), so the decode itself adds no extra latency — only the
// returning read-data mux needs a registered select, since the data for the
// address issued this cycle only arrives next cycle, by which point the CPU
// may already be driving a different address.
//
// core_top's addr/wdata/wstrb passthrough to whichever target is selected;
// the other target sees re/wstrb held low that cycle so it neither reads
// nor writes on an access that isn't addressed to it.
// =============================================================================

`timescale 1ns / 1ps

module data_bus #(
    parameter core_pkg::xlen_t CLINT_BASE = 32'h1100_0000,
    parameter core_pkg::xlen_t CLINT_SIZE = 32'h0001_0000
) (
    input logic clk,
    input logic rst_n,

    // CPU side (from core_top's dmem port)
    input  core_pkg::xlen_t cpu_addr,
    input  core_pkg::xlen_t cpu_wdata,
    input  logic      [3:0] cpu_wstrb,
    input  logic             cpu_re,
    output core_pkg::xlen_t cpu_rdata,

    // RAM side
    output core_pkg::xlen_t ram_addr,
    output core_pkg::xlen_t ram_wdata,
    output logic      [3:0] ram_wstrb,
    output logic             ram_re,
    input  core_pkg::xlen_t ram_rdata,

    // CLINT side
    output core_pkg::xlen_t clint_addr,
    output core_pkg::xlen_t clint_wdata,
    output logic      [3:0] clint_wstrb,
    output logic             clint_re,
    input  core_pkg::xlen_t clint_rdata
);

  import core_pkg::*;

  logic is_clint;
  assign is_clint = (cpu_addr >= CLINT_BASE) && (cpu_addr < (CLINT_BASE + CLINT_SIZE));

  assign ram_addr  = cpu_addr;
  assign ram_wdata = cpu_wdata;
  assign ram_wstrb = is_clint ? 4'b0000 : cpu_wstrb;
  assign ram_re    = cpu_re && !is_clint;

  assign clint_addr  = cpu_addr;
  assign clint_wdata = cpu_wdata;
  assign clint_wstrb = is_clint ? cpu_wstrb : 4'b0000;
  assign clint_re    = cpu_re && is_clint;

  // Registered select: the read data for this cycle's address/is_clint
  // decision arrives next cycle, so the mux needs the decision delayed by
  // exactly the same one cycle.
  logic sel_clint_q;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) sel_clint_q <= 1'b0;
    else sel_clint_q <= is_clint;
  end

  assign cpu_rdata = sel_clint_q ? clint_rdata : ram_rdata;

endmodule
