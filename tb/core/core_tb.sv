// =============================================================================
// tb/core/core_tb.sv
// =============================================================================
// Core-level self-checking testbench for core_top.
//
// Loads a compiled directed test program (Verilog-hex, as produced by
// `objcopy -O verilog`) into a flat byte-addressable memory shared by the
// imem/dmem ports, runs the core, and watches for a store to TOHOST_ADDR
// (see tb/core/common/test_macros.h):
//   value == 1           -> PASS
//   value == (code<<1)|1 -> FAIL, reported with `code`
// A cycle watchdog reports TIMEOUT if the program never reaches tohost
// (e.g. the core hangs on a hazard bug instead of parking cleanly).
//
// Usage: +HEXFILE=path/to/prog.vh [+MAX_CYCLES=100000]
// =============================================================================

`timescale 1ns / 1ps

module core_tb;

  import core_pkg::*;

  localparam int MEM_BYTES = 32768;
  localparam xlen_t TOHOST_ADDR = 32'h0000_1000;
  localparam int MAX_CYCLES_DEFAULT = 100000;

  logic clk = 1'b0;
  logic rst_n = 1'b0;

  always #5 clk = ~clk;

  logic [7:0] mem[0:MEM_BYTES-1];

  xlen_t imem_addr, imem_rdata;
  xlen_t dmem_addr, dmem_wdata, dmem_rdata;
  logic [3:0] dmem_wstrb;
  logic dmem_re;

  core_top dut (
      .clk       (clk),
      .rst_n     (rst_n),
      .imem_addr (imem_addr),
      .imem_rdata(imem_rdata),
      .dmem_addr (dmem_addr),
      .dmem_wdata(dmem_wdata),
      .dmem_wstrb(dmem_wstrb),
      .dmem_re   (dmem_re),
      .dmem_rdata(dmem_rdata)
  );

  // Zero-wait-state combinational reads, same style as core_top expects.
  assign imem_rdata = {mem[imem_addr+3], mem[imem_addr+2], mem[imem_addr+1], mem[imem_addr+0]};
  assign dmem_rdata = {mem[dmem_addr+3], mem[dmem_addr+2], mem[dmem_addr+1], mem[dmem_addr+0]};

  logic test_done = 1'b0;
  logic [31:0] test_result = '0;

  // Synchronous byte-strobed write + tohost snoop.
  always_ff @(posedge clk) begin
    if (rst_n && (|dmem_wstrb)) begin
      if (dmem_wstrb[0]) mem[dmem_addr+0] <= dmem_wdata[7:0];
      if (dmem_wstrb[1]) mem[dmem_addr+1] <= dmem_wdata[15:8];
      if (dmem_wstrb[2]) mem[dmem_addr+2] <= dmem_wdata[23:16];
      if (dmem_wstrb[3]) mem[dmem_addr+3] <= dmem_wdata[31:24];

      if (dmem_addr == TOHOST_ADDR && !test_done) begin
        test_done   <= 1'b1;
        test_result <= dmem_wdata;
      end
    end
  end

  string hexfile;
  int max_cycles;
  int cyc;

  initial begin
    cyc = 0;

    for (int i = 0; i < MEM_BYTES; i++) mem[i] = 8'h00;

    if (!$value$plusargs("HEXFILE=%s", hexfile)) begin
      $fatal(1, "core_tb: missing +HEXFILE=<path> plusarg");
    end
    $readmemh(hexfile, mem);

    if (!$value$plusargs("MAX_CYCLES=%d", max_cycles)) begin
      max_cycles = MAX_CYCLES_DEFAULT;
    end

    $display("core_tb: loaded %s", hexfile);

    repeat (3) @(posedge clk);
    rst_n = 1'b1;

    while (!test_done && cyc < max_cycles) begin
      @(posedge clk);
      cyc++;
    end

    if (!test_done) begin
      $display("core_tb: TIMEOUT after %0d cycles (%s)", cyc, hexfile);
      $fatal(1, "TIMEOUT");
    end else if (test_result == 32'h1) begin
      $display("core_tb: PASS after %0d cycles (%s)", cyc, hexfile);
      $finish;
    end else begin
      $display("core_tb: FAIL result=0x%08h after %0d cycles (%s)", test_result, cyc, hexfile);
      $fatal(1, "FAIL");
    end
  end

endmodule
