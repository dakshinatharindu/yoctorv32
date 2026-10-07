// =============================================================================
// tb/fpga/ddr_test_tb.sv
// =============================================================================
// Simulation of the FPGA DDR test logic (fpga/zc702/ddr_test/ddr_test_core.sv
// + fpga/zc702/rtl/hp_axi_master.sv) against axi_ram_model, which stands in
// for the Zynq PS's S_AXI_HP port and DDR. The test region is shrunk and the
// UART sped up so a pass takes milliseconds of simulated time.
//
// The testbench plays the JTAG debugger's part of the mailbox exchange
// through the model's backdoor, decodes the report lines off the real
// uart_tx waveform, and checks them along with the mailbox words the test
// logic wrote.
//
// Plusargs:
//   +FAULT   corrupt one word on read: the test logic must report exactly
//            that word as failing, and this testbench passes only if it does
// =============================================================================

`timescale 1ns / 1ps

module ddr_test_tb;

  localparam int unsigned TestWords = 1024;
  localparam logic [31:0] TestBase = 32'h1000_0000;
  localparam logic [31:0] MboxBase = 32'h1400_0000;
  localparam logic [31:0] MboxValue = 32'hCAFE_F00D;
  localparam logic [31:0] FaultAddr = TestBase + 32'h0000_0A30;
  localparam int BitPeriod = 16;
  localparam int PassesToCheck = 2;

  logic clk = 1'b0;
  logic rst_n = 1'b0;

  always #5 clk = ~clk;

  logic        req_valid, req_write, req_done, req_error;
  logic [31:0] req_addr, req_wdata, req_rdata;
  logic [ 3:0] req_wstrb;
  logic        uart_tx, fail_sticky;
  logic        fault_en;

  ddr_test_core #(
      .CLK_HZ    (BitPeriod * 9600),
      .BAUD      (9600),
      .TEST_BASE (TestBase),
      .TEST_WORDS(TestWords),
      .MBOX_BASE (MboxBase)
  ) dut (
      .clk        (clk),
      .rst_n      (rst_n),
      .req_valid  (req_valid),
      .req_write  (req_write),
      .req_addr   (req_addr),
      .req_wdata  (req_wdata),
      .req_wstrb  (req_wstrb),
      .req_done   (req_done),
      .req_rdata  (req_rdata),
      .req_error  (req_error),
      .uart_tx    (uart_tx),
      .fail_sticky(fail_sticky)
  );

  logic [5:0] awid, wid, bid, arid, rid;
  logic [31:0] awaddr, wdata, araddr, rdata;
  logic [3:0] awlen, arlen, wstrb, awcache, arcache, awqos, arqos;
  logic [2:0] awsize, arsize, awprot, arprot;
  logic [1:0] awburst, arburst, awlock, arlock, bresp, rresp;
  logic awvalid, awready, wlast, wvalid, wready, bvalid, bready;
  logic arvalid, arready, rlast, rvalid, rready;

  hp_axi_master u_master (
      .clk          (clk),
      .rst_n        (rst_n),
      .req_valid    (req_valid),
      .req_write    (req_write),
      .req_addr     (req_addr),
      .req_wdata    (req_wdata),
      .req_wstrb    (req_wstrb),
      .req_done     (req_done),
      .req_rdata    (req_rdata),
      .req_error    (req_error),
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
      .rst_n        (rst_n),
      .fault_en     (fault_en),
      .fault_addr   (FaultAddr),
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
  // UART monitor: decode bytes off the wire and assemble them into lines.
  // ---------------------------------------------------------------------
  localparam int UartMaxBytes = 4096;
  logic [7:0] uart_bytes[UartMaxBytes];
  int unsigned uart_byte_count;

  uart_rx_monitor #(
      .BIT_PERIOD_CYCLES(BitPeriod),
      .MAX_BYTES(UartMaxBytes)
  ) u_uart_monitor (
      .clk       (clk),
      .rst_n     (rst_n),
      .tx        (uart_tx),
      .bytes_q   (uart_bytes),
      .byte_count(uart_byte_count)
  );

  int unsigned shown;
  string       line;
  int          reports;
  int          failures;

  task automatic check_report(input string l);
    int unsigned pass, err, at, got, rd_min, rd_max, wr_min, wr_max, mbox;
    string strb;
    int n;
    logic expect_fail;
    n = $sscanf(
        l,
        "#%h err=%h at=%h got=%h strb=%s rd=%h-%h wr=%h-%h mbox=%h",
        pass,
        err,
        at,
        got,
        strb,
        rd_min,
        rd_max,
        wr_min,
        wr_max,
        mbox
    );
    if (n != 10) begin
      $display("ddr_test_tb: FAIL could not parse report line (%0d fields): %s", n, l);
      failures++;
      return;
    end

    expect_fail = fault_en;
    if (pass != reports) begin
      $display("ddr_test_tb: FAIL pass number %0d, expected %0d", pass, reports);
      failures++;
    end
    if (mbox != MboxValue) begin
      $display("ddr_test_tb: FAIL mailbox read %08h, expected %08h", mbox, MboxValue);
      failures++;
    end
    if (strb != "OK") begin
      $display("ddr_test_tb: FAIL byte-strobe check reported %s", strb);
      failures++;
    end
    if (rd_min < 2 || rd_max < rd_min || wr_min < 2 || wr_max < wr_min) begin
      $display("ddr_test_tb: FAIL implausible latency rd=%0d-%0d wr=%0d-%0d", rd_min, rd_max, wr_min,
               wr_max);
      failures++;
    end
    if (!expect_fail && err != 0) begin
      $display("ddr_test_tb: FAIL %0d mismatches reported, first at %08h got %08h", err, at, got);
      failures++;
    end
    if (expect_fail && (err != 1 || at != FaultAddr)) begin
      $display("ddr_test_tb: FAIL injected fault at %08h not reported correctly (err=%0d at=%08h)",
               FaultAddr, err, at);
      failures++;
    end

    // What the debugger would read back through DDR.
    if (u_ram.peek(MboxBase + 32'h4) != ~MboxValue) begin
      $display("ddr_test_tb: FAIL mailbox echo word is %08h", u_ram.peek(MboxBase + 32'h4));
      failures++;
    end
    if (u_ram.peek(MboxBase + 32'h8) != pass) begin
      $display("ddr_test_tb: FAIL pass-number word is %08h", u_ram.peek(MboxBase + 32'h8));
      failures++;
    end
    if (u_ram.peek(MboxBase + 32'hC) != {expect_fail ? 16'hBAD0 : 16'h600D, pass[15:0]}) begin
      $display("ddr_test_tb: FAIL status word is %08h", u_ram.peek(MboxBase + 32'hC));
      failures++;
    end
  endtask

  always @(posedge clk) begin
    if (rst_n && shown != uart_byte_count) begin
      automatic logic [7:0] c = uart_bytes[shown];
      shown <= shown + 1;
      if (c == 8'h0A) begin
        $display("uart> %s", line);
        if (line.len() > 0 && line[0] == "#") begin
          check_report(line);
          reports++;
        end
        line = "";
      end else if (c != 8'h0D) begin
        line = {line, string'(c)};
      end
    end
  end

  initial begin
    shown    = 0;
    line     = "";
    reports  = 0;
    failures = 0;
    fault_en = $test$plusargs("FAULT");

    u_ram.poke(MboxBase, MboxValue);

    repeat (3) @(posedge clk);
    rst_n = 1'b1;

    while (reports < PassesToCheck) @(posedge clk);

    // fail_sticky updates once the report line has fully left the UART.
    repeat (4 * BitPeriod) @(posedge clk);
    if (fail_sticky != fault_en) begin
      $display("ddr_test_tb: FAIL fail_sticky=%0b", fail_sticky);
      failures++;
    end

    if (failures == 0) begin
      if (fault_en) $display("ddr_test_tb: PASS (%0d report lines checked, injected fault detected)", reports);
      else $display("ddr_test_tb: PASS (%0d report lines checked)", reports);
      $finish;
    end else begin
      $display("ddr_test_tb: FAIL (%0d problems)", failures);
      $fatal(1, "FAIL");
    end
  end

  initial begin
    repeat (20_000_000) @(posedge clk);
    $display("ddr_test_tb: TIMEOUT (%0d report lines seen)", reports);
    $fatal(1, "TIMEOUT");
  end

  initial begin
    if ($test$plusargs("VCD")) begin
      $dumpfile("ddr_test_tb.vcd");
      $dumpvars(0, ddr_test_tb);
    end
  end

endmodule
