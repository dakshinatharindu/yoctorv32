// =============================================================================
// rtl/core/ifetch/ifetch.sv
// =============================================================================
// IF stage: program counter + combinational instruction memory port.
//
// Instruction memory is assumed to be zero-wait-state / combinationally
// read (same style as regfile's async read ports): imem_addr is driven
// straight from the PC and imem_rdata is expected back the same cycle.
//
// PC update priority: branch/jump redirect > stall (load-use hazard) > pc+4.
// =============================================================================

`timescale 1ns / 1ps

module ifetch (
    input logic clk,
    input logic rst_n,

    // Pipeline control
    input logic             stall,          // hold PC (load-use hazard)
    input logic             branch_taken,   // redirect from EX stage
    input core_pkg::xlen_t  branch_target,

    // Instruction memory port
    output core_pkg::xlen_t imem_addr,
    input  core_pkg::xlen_t imem_rdata,

    // To IF/ID register
    output core_pkg::xlen_t pc,
    output core_pkg::xlen_t instr
);

  import core_pkg::*;

  xlen_t pc_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) pc_q <= RESET_PC;
    else if (branch_taken) pc_q <= branch_target;
    else if (!stall) pc_q <= pc_q + 32'd4;
  end

  assign pc        = pc_q;
  assign imem_addr = pc_q;
  assign instr     = imem_rdata;

endmodule
