// =============================================================================
// rtl/core/pipeline/id_ex_reg.sv
// =============================================================================
// ID/EX pipeline register.
// - flush : replace with an all-zero bubble (rd_we/mem_rd/mem_wr/valid all 0,
//           i.e. a safe no-op). Used for load-use stalls and branch squash.
// - stall : hold current contents (RV32M multi-cycle divide/remainder in EX
//           — the DIV/REM instruction must stay put in id_ex_q while
//           div_unit iterates). Mirrors if_id_reg's stall/flush pattern.
// =============================================================================

`timescale 1ns / 1ps

module id_ex_reg (
    input logic clk,
    input logic rst_n,

    input logic stall,
    input logic flush,

    input  core_pkg::id_ex_t d,
    output core_pkg::id_ex_t q
);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n || flush) q <= '0;
    else if (!stall) q <= d;
  end

endmodule
