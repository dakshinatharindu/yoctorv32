// =============================================================================
// rtl/top/soc_top.sv
// =============================================================================
// SoC-level wrapper: core_top (pure CPU) + data_bus (interconnect) + clint
// (peripheral). core_top itself stays untouched/CPU-only — this is the
// module a future FPGA top or Linux-boot testbench instantiates instead of
// core_top directly. Instructions never execute from CLINT, so imem is
// wired straight to external RAM with no decode; only the data-memory port
// needs routing between RAM and CLINT.
// =============================================================================

`timescale 1ns / 1ps

module soc_top (
    input logic clk,
    input logic rst_n,

    // Instruction memory port (straight through to external RAM)
    output core_pkg::xlen_t imem_addr,
    input  core_pkg::xlen_t imem_rdata,

    // Data memory port (RAM side, post address-decode)
    output core_pkg::xlen_t dmem_addr,
    output core_pkg::xlen_t dmem_wdata,
    output logic      [3:0] dmem_wstrb,
    output logic             dmem_re,
    input  core_pkg::xlen_t dmem_rdata
);

  import core_pkg::*;

  xlen_t cpu_dmem_addr, cpu_dmem_wdata, cpu_dmem_rdata;
  logic  [3:0] cpu_dmem_wstrb;
  logic  cpu_dmem_re;

  xlen_t clint_addr, clint_wdata, clint_rdata;
  logic  [3:0] clint_wstrb;
  logic  clint_re;
  logic  mtip;

  core_top u_core_top (
      .clk       (clk),
      .rst_n     (rst_n),
      .imem_addr (imem_addr),
      .imem_rdata(imem_rdata),
      .dmem_addr (cpu_dmem_addr),
      .dmem_wdata(cpu_dmem_wdata),
      .dmem_wstrb(cpu_dmem_wstrb),
      .dmem_re   (cpu_dmem_re),
      .dmem_rdata(cpu_dmem_rdata),
      .mtip      (mtip)
  );

  data_bus u_data_bus (
      .clk        (clk),
      .rst_n      (rst_n),
      .cpu_addr   (cpu_dmem_addr),
      .cpu_wdata  (cpu_dmem_wdata),
      .cpu_wstrb  (cpu_dmem_wstrb),
      .cpu_re     (cpu_dmem_re),
      .cpu_rdata  (cpu_dmem_rdata),
      .ram_addr   (dmem_addr),
      .ram_wdata  (dmem_wdata),
      .ram_wstrb  (dmem_wstrb),
      .ram_re     (dmem_re),
      .ram_rdata  (dmem_rdata),
      .clint_addr (clint_addr),
      .clint_wdata(clint_wdata),
      .clint_wstrb(clint_wstrb),
      .clint_re   (clint_re),
      .clint_rdata(clint_rdata)
  );

  clint u_clint (
      .clk  (clk),
      .rst_n(rst_n),
      .addr (clint_addr),
      .wdata(clint_wdata),
      .wstrb(clint_wstrb),
      .re   (clint_re),
      .rdata(clint_rdata),
      .mtip (mtip)
  );

endmodule
