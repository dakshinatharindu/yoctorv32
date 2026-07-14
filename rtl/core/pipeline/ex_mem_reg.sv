// =============================================================================
// rtl/core/pipeline/ex_mem_reg.sv
// =============================================================================
// EX/MEM pipeline register.
// - flush : replace with an all-zero bubble. Driven by a MEM-stage trap/MRET
//   redirect (sys_redirect) — the instruction currently in id_ex_q (this
//   cycle's EX instruction) is younger than the one causing the redirect and
//   must never reach MEM/WB.
// =============================================================================

`timescale 1ns / 1ps

module ex_mem_reg (
    input logic clk,
    input logic rst_n,

    input logic flush,

    input  core_pkg::ex_mem_t d,
    output core_pkg::ex_mem_t q
);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n || flush) q <= '0;
    else q <= d;
  end

endmodule
