// =============================================================================
// tb/fpga/soc_ddr_tb.sv
// =============================================================================
// Simulation of the DDR-backed SoC that goes on the FPGA (fpga/zc702/rtl/
// soc_ddr.sv: soc_top + mem_bridge + hp_axi_master), with axi_ram_model
// standing in for the Zynq PS's AXI port and DDR. Whatever runs here runs
// through the same bridge, clock-enable pacing and AXI master as on the
// board; only the PS and the clocking primitives are missing.
//
// Program loading, the way the board does it:
//   +BOOT=<file>   boot RAM image at address 0: 32-bit words, one per line
//                  (the format the bitstream build loads with $readmemh)
//   +DDR0=<file>   images for main RAM, placed in the model's DDR: byte-wide
//   +DDR1=<file>   Verilog hex whose addresses are relative to RAM_BASE
//                  (objcopy -O verilog, as sim/verilator/run_linux_boot.sh
//                  produces for the kernel and device tree)
//
// Ending the run:
//   +TOHOST_ADDR=<hex>         watch for a store to this address and report
//                              PASS/FAIL like core_tb (riscv-tests)
//   +FINISH_UART_BYTES=<n>     stop successfully once n UART bytes were
//                              decoded since the last reset
//   +MAX_CYCLES=<n>            give up after n core cycles (ce pulses);
//                              a TIMEOUT failure if either option above was
//                              given, a normal stop otherwise
//
// Stimulus:
//   +INJECT_AT_BYTES=<n>       send +INJECT_BYTE=<hex> (default 5A) to the
//                              SoC's UART once n bytes were decoded
//   +RESET_COUNT=<k>           pulse the SoC's reset request k times at
//   +RESET_EVERY=<cycles>      random moments about <cycles> clocks apart,
//                              then let the program run to its normal end.
//                              Checks that reset is safe mid-transaction.
//
// Debug:
//   +TRACE_CORE=<n>            print addresses and data of the first n core
//                              cycles
//
// Decoded UART output streams to stdout. UART_BIT_CYCLES must match the baud
// rate the program sets up (16 = divisor 1); override it at build time with
// -GUART_BIT_CYCLES=<n>. AXI timing: see axi_ram_model.sv's plusargs.
// =============================================================================

`timescale 1ns / 1ps

module soc_ddr_tb #(
    parameter int UART_BIT_CYCLES = 16
);

  localparam logic [31:0] RamBase = 32'h8000_0000;
  localparam int RamBytes = 32'h0400_0000;  // 64 MiB
  localparam logic [31:0] DdrBase = 32'h1000_0000;
  localparam int BootBytes = 4096;
  localparam longint MaxCyclesDefault = 2_000_000;

  logic clk = 1'b0;
  logic hard_rst_n = 1'b0;
  logic rst_req = 1'b0;

  always #5 clk = ~clk;

  logic uart_tx, uart_rx;
  logic running, bus_error;

  logic [5:0] awid, wid, bid, arid, rid;
  logic [31:0] awaddr, wdata, araddr, rdata;
  logic [3:0] awlen, arlen, wstrb, awcache, arcache, awqos, arqos;
  logic [2:0] awsize, arsize, awprot, arprot;
  logic [1:0] awburst, arburst, awlock, arlock, bresp, rresp;
  logic awvalid, awready, wlast, wvalid, wready, bvalid, bready;
  logic arvalid, arready, rlast, rvalid, rready;

  soc_ddr #(
      .BOOT_BYTES(BootBytes),
      .RAM_BASE  (RamBase),
      .RAM_BYTES (RamBytes),
      .DDR_BASE  (DdrBase)
  ) dut (
      .clk          (clk),
      .hard_rst_n   (hard_rst_n),
      .rst_req      (rst_req),
      .uart_tx      (uart_tx),
      .uart_rx      (uart_rx),
      .running      (running),
      .bus_error    (bus_error),
      .m_axi_awid   (awid),
      .m_axi_awaddr (awaddr),
      .m_axi_awlen  (awlen),
      .m_axi_awsize (awsize),
      .m_axi_awburst(awburst),
      .m_axi_awlock (awlock),
      .m_axi_awcache(awcache),
      .m_axi_awprot (awprot),
      .m_axi_awqos  (awqos),
      .m_axi_awvalid(awvalid),
      .m_axi_awready(awready),
      .m_axi_wid    (wid),
      .m_axi_wdata  (wdata),
      .m_axi_wstrb  (wstrb),
      .m_axi_wlast  (wlast),
      .m_axi_wvalid (wvalid),
      .m_axi_wready (wready),
      .m_axi_bid    (bid),
      .m_axi_bresp  (bresp),
      .m_axi_bvalid (bvalid),
      .m_axi_bready (bready),
      .m_axi_arid   (arid),
      .m_axi_araddr (araddr),
      .m_axi_arlen  (arlen),
      .m_axi_arsize (arsize),
      .m_axi_arburst(arburst),
      .m_axi_arlock (arlock),
      .m_axi_arcache(arcache),
      .m_axi_arprot (arprot),
      .m_axi_arqos  (arqos),
      .m_axi_arvalid(arvalid),
      .m_axi_arready(arready),
      .m_axi_rid    (rid),
      .m_axi_rdata  (rdata),
      .m_axi_rresp  (rresp),
      .m_axi_rlast  (rlast),
      .m_axi_rvalid (rvalid),
      .m_axi_rready (rready)
  );

  axi_ram_model u_ram (
      .clk          (clk),
      .rst_n        (hard_rst_n),
      .fault_en     (1'b0),
      .fault_addr   (32'h0),
      .s_axi_awid   (awid),
      .s_axi_awaddr (awaddr),
      .s_axi_awlen  (awlen),
      .s_axi_awsize (awsize),
      .s_axi_awburst(awburst),
      .s_axi_awvalid(awvalid),
      .s_axi_awready(awready),
      .s_axi_wid    (wid),
      .s_axi_wdata  (wdata),
      .s_axi_wstrb  (wstrb),
      .s_axi_wlast  (wlast),
      .s_axi_wvalid (wvalid),
      .s_axi_wready (wready),
      .s_axi_bid    (bid),
      .s_axi_bresp  (bresp),
      .s_axi_bvalid (bvalid),
      .s_axi_bready (bready),
      .s_axi_arid   (arid),
      .s_axi_araddr (araddr),
      .s_axi_arlen  (arlen),
      .s_axi_arsize (arsize),
      .s_axi_arburst(arburst),
      .s_axi_arvalid(arvalid),
      .s_axi_arready(arready),
      .s_axi_rid    (rid),
      .s_axi_rdata  (rdata),
      .s_axi_rresp  (rresp),
      .s_axi_rlast  (rlast),
      .s_axi_rvalid (rvalid),
      .s_axi_rready (rready)
  );

  // ---------------------------------------------------------------------
  // UART: monitor (streams to stdout) and injector.
  // ---------------------------------------------------------------------
  localparam int UartMaxBytes = 1 << 20;
  logic [7:0] uart_bytes[UartMaxBytes];
  int unsigned uart_byte_count;

  uart_rx_monitor #(
      .BIT_PERIOD_CYCLES(UART_BIT_CYCLES),
      .MAX_BYTES(UartMaxBytes)
  ) u_uart_monitor (
      .clk       (clk),
      .rst_n     (hard_rst_n),
      .tx        (uart_tx),
      .bytes_q   (uart_bytes),
      .byte_count(uart_byte_count)
  );

  logic       inject_send = 1'b0;
  logic [7:0] inject_byte = 8'h5A;
  logic       inject_busy;

  uart_tx_injector #(
      .BIT_PERIOD_CYCLES(UART_BIT_CYCLES)
  ) u_uart_injector (
      .clk      (clk),
      .rst_n    (hard_rst_n),
      .send     (inject_send),
      .send_byte(inject_byte),
      .busy     (inject_busy),
      .tx       (uart_rx)
  );

  int unsigned shown_count = 0;
  always_ff @(posedge clk) begin
    if (uart_byte_count != shown_count) begin
      $write("%c", uart_bytes[shown_count]);
      $fflush;
      shown_count <= shown_count + 1;
    end
  end

  // ---------------------------------------------------------------------
  // tohost snoop, on the SoC's own data port (one store per enabled cycle).
  // ---------------------------------------------------------------------
  logic        test_done = 1'b0;
  logic [31:0] test_result = '0;
  logic [31:0] tohost_addr;
  logic        use_tohost;

  always_ff @(posedge clk) begin
    if (use_tohost && running && dut.ce && (|dut.dmem_wstrb) && dut.dmem_addr == tohost_addr &&
        !test_done) begin
      test_done   <= 1'b1;
      test_result <= dut.dmem_wdata;
    end
  end

  // ---------------------------------------------------------------------
  // Cycle counters: clocks and core cycles (ce pulses) while running.
  // ---------------------------------------------------------------------
  longint unsigned clk_cycles = 0;
  longint unsigned core_cycles = 0;
  always_ff @(posedge clk) begin
    if (running) begin
      clk_cycles <= clk_cycles + 1;
      if (dut.ce) core_cycles <= core_cycles + 1;
    end
  end

  // +TRACE_CORE=<n>: print what the SoC is given on its first n core cycles.
  int trace_core;
  initial if (!$value$plusargs("TRACE_CORE=%d", trace_core)) trace_core = 0;
  always_ff @(posedge clk) begin
    if (running && dut.ce && core_cycles < longint'(trace_core)) begin
      $display("core %0d: imem[%08h]=%08h  dmem[%08h] re=%0b rdata=%08h wstrb=%04b wdata=%08h",
               core_cycles, dut.imem_addr, dut.imem_rdata, dut.dmem_addr, dut.dmem_re,
               dut.dmem_rdata, dut.dmem_wstrb, dut.dmem_wdata);
    end
  end

  // ---------------------------------------------------------------------
  // Load + run.
  // ---------------------------------------------------------------------
  logic [7:0] img[0:RamBytes-1];

  string boot_file, ddr_file;
  longint max_cycles;
  int finish_uart_bytes;
  int inject_at_bytes;
  int inject_byte_arg;
  int reset_count, reset_every;
  int unsigned bytes_at_reset;
  logic injected;
  int progress_fd;

  task automatic report_and_finish(input string verdict, input logic ok);
    $display("\nsoc_ddr_tb: %s after %0d core cycles, %0d clocks (%.1f clocks per core cycle), %0d UART bytes",
             verdict, core_cycles, clk_cycles,
             core_cycles == 0 ? 0.0 : real'(clk_cycles) / real'(core_cycles), uart_byte_count);
    if (bus_error) begin
      $display("soc_ddr_tb: FAIL the bridge saw an AXI error response");
      $fatal(1, "FAIL");
    end
    if (ok) $finish;
    else $fatal(1, "%s", verdict);
  endtask

  initial begin
    use_tohost = $value$plusargs("TOHOST_ADDR=%h", tohost_addr);
    if (!$value$plusargs("MAX_CYCLES=%d", max_cycles)) max_cycles = MaxCyclesDefault;
    if (!$value$plusargs("FINISH_UART_BYTES=%d", finish_uart_bytes)) finish_uart_bytes = 0;
    if (!$value$plusargs("INJECT_AT_BYTES=%d", inject_at_bytes)) inject_at_bytes = 0;
    if (!$value$plusargs("INJECT_BYTE=%h", inject_byte_arg)) inject_byte_arg = 32'h5A;
    if (!$value$plusargs("RESET_COUNT=%d", reset_count)) reset_count = 0;
    if (!$value$plusargs("RESET_EVERY=%d", reset_every)) reset_every = 2000;
    bytes_at_reset = 0;
    injected       = 1'b0;

    // Boot RAM.
    if ($value$plusargs("BOOT=%s", boot_file)) begin
      for (int i = 0; i < BootBytes / 4; i++) dut.u_bridge.boot_mem[i] = 32'h0;
      $readmemh(boot_file, dut.u_bridge.boot_mem);
    end else begin
      $fatal(1, "soc_ddr_tb: missing +BOOT=<file> plusarg");
    end

    // Main RAM images -> the model's DDR, as the JTAG download does.
    for (int i = 0; i < RamBytes; i++) img[i] = 8'h00;
    if ($value$plusargs("DDR0=%s", ddr_file)) $readmemh(ddr_file, img);
    if ($value$plusargs("DDR1=%s", ddr_file)) $readmemh(ddr_file, img);
    for (int i = 0; i < RamBytes; i += 4) begin
      if ({img[i+3], img[i+2], img[i+1], img[i]} != 32'h0)
        u_ram.poke(DdrBase + i, {img[i+3], img[i+2], img[i+1], img[i]});
    end

    progress_fd = $fopen("soc_ddr_progress.log", "w");

    repeat (3) @(posedge clk);
    hard_rst_n = 1'b1;

    forever begin
      @(posedge clk);

      // Reset storm: short reset requests at random moments.
      if (reset_count > 0 && clk_cycles != 0 &&
          (clk_cycles % longint'(reset_every)) == longint'($urandom_range(reset_every - 1))) begin
        reset_count--;
        rst_req <= 1'b1;
        repeat ($urandom_range(5, 1)) @(posedge clk);
        rst_req <= 1'b0;
        // A character cut off by the reset still reaches the monitor as one
        // garbage byte; let it land before counting bytes from this reset.
        repeat (11 * UART_BIT_CYCLES) @(posedge clk);
        bytes_at_reset = uart_byte_count;
        injected       = 1'b0;
        $display("\nsoc_ddr_tb: reset request (%0d left)", reset_count);
      end

      inject_send <= 1'b0;
      if (inject_at_bytes > 0 && !injected && reset_count == 0 &&
          (uart_byte_count - bytes_at_reset) >= inject_at_bytes && !inject_busy) begin
        inject_byte <= inject_byte_arg[7:0];
        inject_send <= 1'b1;
        injected = 1'b1;
      end

      if (core_cycles != 0 && (core_cycles % 5000000) == 0 && dut.ce) begin
        $fdisplay(progress_fd, "soc_ddr_tb: core=%0d clk=%0d imem_addr=%08h uart_bytes=%0d",
                  core_cycles, clk_cycles, dut.imem_addr, uart_byte_count);
        $fflush(progress_fd);
      end

      if (test_done) begin
        if (test_result == 32'h1) report_and_finish("PASS", 1'b1);
        else begin
          $display("soc_ddr_tb: tohost result=0x%08h", test_result);
          report_and_finish("FAIL", 1'b0);
        end
      end

      if (finish_uart_bytes > 0 && reset_count == 0 &&
          (uart_byte_count - bytes_at_reset) >= finish_uart_bytes) begin
        repeat (4 * UART_BIT_CYCLES) @(posedge clk);
        report_and_finish("PASS", 1'b1);
      end

      if (core_cycles >= max_cycles) begin
        if (use_tohost || finish_uart_bytes > 0) report_and_finish("TIMEOUT", 1'b0);
        else report_and_finish("stopped", 1'b1);
      end
    end
  end

  initial begin
    if ($test$plusargs("VCD")) begin
      $dumpfile("soc_ddr_tb.vcd");
      $dumpvars(0, soc_ddr_tb);
    end
  end

endmodule
