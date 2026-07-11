// =============================================================================
// rtl/core/pipeline/mem_wb_reg.sv
// =============================================================================
// MEM/WB pipeline register.
// =============================================================================

`timescale 1ns / 1ps

module mem_wb_reg (
    input logic clk,
    input logic rst_n,

    input  core_pkg::mem_wb_t d,
    output core_pkg::mem_wb_t q
);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) q <= '0;
    else q <= d;
  end

endmodule
