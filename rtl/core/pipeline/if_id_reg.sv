// =============================================================================
// rtl/core/pipeline/if_id_reg.sv
// =============================================================================
// IF/ID pipeline register.
// - stall : hold current contents (load-use hazard)
// - flush : replace with a bubble (NOP), e.g. on a taken branch/jump
// =============================================================================

`timescale 1ns / 1ps

module if_id_reg (
    input logic clk,
    input logic rst_n,

    input logic stall,
    input logic flush,

    input  core_pkg::if_id_t d,
    output core_pkg::if_id_t q
);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n || flush) begin
      q.pc    <= core_pkg::RESET_PC;
      q.instr <= core_pkg::NOP_INSTR;
      q.valid <= 1'b0;
    end else if (!stall) begin
      q <= d;
    end
  end

endmodule
