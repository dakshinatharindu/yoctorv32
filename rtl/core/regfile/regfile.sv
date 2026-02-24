// =============================================================================
// rtl/core/regfile/regfile.sv
// =============================================================================
// RV32 register file
// - 32 regs x 32-bit (x0..x31)
// - 2 async read ports (rs1, rs2)
// - 1 sync write port (rd) on rising clock
// - x0 is hard-wired to 0 (writes ignored, reads return 0)
//
// Recommended for a basic in-order pipeline.
// =============================================================================

`timescale 1ns / 1ps

module regfile (
    input logic clk,
    input logic rst_n,

    // Read port 1
    input  core_pkg::reg_addr_t rs1_addr,
    output core_pkg::xlen_t     rs1_rdata,

    // Read port 2
    input  core_pkg::reg_addr_t rs2_addr,
    output core_pkg::xlen_t     rs2_rdata,

    // Write port
    input logic                rd_we,
    input core_pkg::reg_addr_t rd_addr,
    input core_pkg::xlen_t     rd_wdata
);

  // 32 registers, x0 is special (kept as 0)
  core_pkg::xlen_t regs[32];

  // ---------------------------------------------------------------------------
  // Asynchronous reads
  // ---------------------------------------------------------------------------
  always_comb begin
    if (rs1_addr == '0) rs1_rdata = '0;
    else rs1_rdata = regs[rs1_addr];
  end

  always_comb begin
    if (rs2_addr == '0) rs2_rdata = '0;
    else rs2_rdata = regs[rs2_addr];
  end

  // ---------------------------------------------------------------------------
  // Synchronous write
  // ---------------------------------------------------------------------------
  integer i;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      // Optional: reset regs to 0 for nicer sim/debug (not required by RISC-V)
      for (i = 0; i < 32; i++) begin
        regs[i] <= '0;
      end
    end else begin
      // Enforce x0 hardwired to 0 (ignore writes to x0)
      if (rd_we && (rd_addr != '0)) begin
        regs[rd_addr] <= rd_wdata;
      end

      // Keep x0 at 0 even if something tries to mess with it in sim
      regs[0] <= '0;
    end
  end

endmodule
