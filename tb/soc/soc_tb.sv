// =============================================================================
// tb/soc/soc_tb.sv
// =============================================================================
// SoC-level self-checking testbench for soc_top (core_top + data_bus +
// clint + uart). Mirrors tb/core/core_tb.sv exactly (same synchronous RAM
// model, same +HEXFILE/+MAX_CYCLES/+TOHOST_ADDR plusarg conventions, same
// tohost snoop), except it instantiates soc_top instead of core_top
// directly, so CLINT/UART are reachable at their real mapped addresses
// through the actual interconnect rather than being tested in isolation.
//
// A uart_rx_monitor independently decodes the bit-accurate uart_tx
// waveform (blind to the UART peripheral's internal registers) and
// $displays every received byte at test completion — a second, hardware-
// level confirmation alongside whatever the test program itself verified
// from the register/software side. A uart_tx_injector drives the DUT's
// uart_rx input, standing in for an external peer sending a byte, for
// interrupt-driven-RX tests. Both share BIT_PERIOD_CYCLES=16, which must
// match whatever divisor the UART test program under test actually
// configures (currently all such tests use divisor=1).
//
// Usage: +HEXFILE=path/to/prog.vh [+MAX_CYCLES=100000] [+TOHOST_ADDR=1000]
//        [+INJECT_BYTE=41] [+INJECT_CYCLE=2000]
// =============================================================================

`timescale 1ns / 1ps

module soc_tb;

  import core_pkg::*;

  localparam int MEM_BYTES = 32768;
  localparam xlen_t TOHOST_ADDR_DEFAULT = 32'h0000_1000;
  localparam int MAX_CYCLES_DEFAULT = 100000;

  logic clk = 1'b0;
  logic rst_n = 1'b0;

  always #5 clk = ~clk;

  logic [7:0] mem[0:MEM_BYTES-1];

  xlen_t imem_addr, imem_rdata;
  xlen_t dmem_addr, dmem_wdata, dmem_rdata;
  logic [3:0] dmem_wstrb;
  logic dmem_re;
  logic uart_tx, uart_rx;

  soc_top dut (
      .clk       (clk),
      .rst_n     (rst_n),
      .imem_addr (imem_addr),
      .imem_rdata(imem_rdata),
      .dmem_addr (dmem_addr),
      .dmem_wdata(dmem_wdata),
      .dmem_wstrb(dmem_wstrb),
      .dmem_re   (dmem_re),
      .dmem_rdata(dmem_rdata),
      .uart_tx   (uart_tx),
      .uart_rx   (uart_rx)
  );

  localparam int UartMaxBytes = 64;
  logic [7:0] uart_bytes[UartMaxBytes];
  int unsigned uart_byte_count;

  uart_rx_monitor #(
      .BIT_PERIOD_CYCLES(16),
      .MAX_BYTES(UartMaxBytes)
  ) u_uart_monitor (
      .clk       (clk),
      .rst_n     (rst_n),
      .tx        (uart_tx),
      .bytes_q   (uart_bytes),
      .byte_count(uart_byte_count)
  );

  logic inject_send;
  logic [7:0] inject_byte;
  logic inject_busy;

  uart_tx_injector #(
      .BIT_PERIOD_CYCLES(16)
  ) u_uart_injector (
      .clk      (clk),
      .rst_n    (rst_n),
      .send     (inject_send),
      .send_byte(inject_byte),
      .busy     (inject_busy),
      .tx       (uart_rx)
  );

  // Synchronous reads (registered output), matching real BRAM: data for the
  // address driven this cycle arrives on imem_rdata/dmem_rdata next cycle.
  // RAM only ever sees addresses the interconnect has decoded as non-CLINT.
  always_ff @(posedge clk) begin
    imem_rdata <= {mem[imem_addr+3], mem[imem_addr+2], mem[imem_addr+1], mem[imem_addr+0]};
    dmem_rdata <= {mem[dmem_addr+3], mem[dmem_addr+2], mem[dmem_addr+1], mem[dmem_addr+0]};
  end

  logic test_done = 1'b0;
  logic [31:0] test_result = '0;
  xlen_t tohost_addr;

  // Synchronous byte-strobed write + tohost snoop.
  always_ff @(posedge clk) begin
    if (rst_n && (|dmem_wstrb)) begin
      if (dmem_wstrb[0]) mem[dmem_addr+0] <= dmem_wdata[7:0];
      if (dmem_wstrb[1]) mem[dmem_addr+1] <= dmem_wdata[15:8];
      if (dmem_wstrb[2]) mem[dmem_addr+2] <= dmem_wdata[23:16];
      if (dmem_wstrb[3]) mem[dmem_addr+3] <= dmem_wdata[31:24];

      if (dmem_addr == tohost_addr && !test_done) begin
        test_done   <= 1'b1;
        test_result <= dmem_wdata;
      end
    end
  end

  string hexfile;
  int max_cycles;
  int cyc;
  int inject_cycle;
  int inject_byte_arg;

  initial begin
    cyc = 0;
    inject_send = 1'b0;
    inject_byte = 8'h00;

    for (int i = 0; i < MEM_BYTES; i++) mem[i] = 8'h00;

    if (!$value$plusargs("HEXFILE=%s", hexfile)) begin
      $fatal(1, "soc_tb: missing +HEXFILE=<path> plusarg");
    end
    $readmemh(hexfile, mem);

    if (!$value$plusargs("MAX_CYCLES=%d", max_cycles)) begin
      max_cycles = MAX_CYCLES_DEFAULT;
    end

    if (!$value$plusargs("TOHOST_ADDR=%h", tohost_addr)) begin
      tohost_addr = TOHOST_ADDR_DEFAULT;
    end

    if (!$value$plusargs("INJECT_CYCLE=%d", inject_cycle)) begin
      inject_cycle = 2000;
    end
    if (!$value$plusargs("INJECT_BYTE=%h", inject_byte_arg)) begin
      inject_byte_arg = 32'h41;
    end

    $display("soc_tb: loaded %s", hexfile);

    repeat (3) @(posedge clk);
    rst_n = 1'b1;

    while (!test_done && cyc < max_cycles) begin
      @(posedge clk);
      cyc++;
      inject_send <= 1'b0;
      if (cyc == inject_cycle) begin
        inject_byte <= inject_byte_arg[7:0];
        inject_send <= 1'b1;
      end
    end

    if (uart_byte_count > 0) begin
      $write("soc_tb: uart_tx decoded %0d byte(s): ", uart_byte_count);
      for (int i = 0; i < uart_byte_count; i++) begin
        $write("%02h('%c') ", uart_bytes[i], uart_bytes[i]);
      end
      $write("\n");
    end

    if (!test_done) begin
      $display("soc_tb: TIMEOUT after %0d cycles (%s)", cyc, hexfile);
      $fatal(1, "TIMEOUT");
    end else if (test_result == 32'h1) begin
      $display("soc_tb: PASS after %0d cycles (%s)", cyc, hexfile);
      $finish;
    end else begin
      $display("soc_tb: FAIL result=0x%08h after %0d cycles (%s)", test_result, cyc, hexfile);
      $fatal(1, "FAIL");
    end
  end

  initial begin
    if ($test$plusargs("VCD")) begin
      $dumpfile("soc_tb.vcd");
      $dumpvars(0, soc_tb);
    end
  end

endmodule
