// =============================================================================
// rtl/core/pipeline/ex_mem_reg.sv
// =============================================================================
// EX/MEM pipeline register. No stalls/flushes originate downstream of EX in
// this simple in-order core (single-cycle memory), so it just registers.
// =============================================================================

`timescale 1ns / 1ps

module ex_mem_reg (
    input logic clk,
    input logic rst_n,

    input  core_pkg::ex_mem_t d,
    output core_pkg::ex_mem_t q
);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) q <= '0;
    else q <= d;
  end

endmodule
