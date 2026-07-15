// =============================================================================
// rtl/core/pipeline/ex_mem_reg.sv
// =============================================================================
// EX/MEM pipeline register.
// - flush : replace with an all-zero bubble. Driven by a MEM-stage trap/MRET
//   redirect (sys_redirect) — the instruction currently in id_ex_q (this
//   cycle's EX instruction) is younger than the one causing the redirect and
//   must never reach MEM/WB.
// - stall : hold current contents. Driven by lsu.sv's amo_stall — an AMO*.W
//   read-modify-write needs its address held for one extra cycle so the
//   deferred write (once dmem_rdata's old value has arrived) reuses the
//   same address, analogous to id_ex_reg holding a DIV/REM in place.
// =============================================================================

`timescale 1ns / 1ps

module ex_mem_reg (
    input logic clk,
    input logic rst_n,

    input logic stall,
    input logic flush,

    input  core_pkg::ex_mem_t d,
    output core_pkg::ex_mem_t q
);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n || flush) q <= '0;
    else if (!stall) q <= d;
  end

endmodule
