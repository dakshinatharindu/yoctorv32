// =============================================================================
// fpga/zc702/ddr_test/ddr_test_top.sv
// =============================================================================
// Milestone 2, step 2 board top for the ZC702: the DDR test logic
// (ddr_test_core) driving the Zynq PS's S_AXI_HP0 port through hp_axi_master.
// No CPU. Proves the PL can use PS DDR as memory and measures how long each
// access takes, before the core is put on top of it.
//
// The PL clock, reset synchronizer and UART TX pin are the ones proven by the
// earlier milestones. New here is the PS, instantiated through the generated
// block-design wrapper (see fpga/zc702/bd/ps7.tcl):
//   - DDR and MIO pins pass straight through to the top level.
//   - fclk_reset0_n stays low until the PS has been initialized over JTAG
//     (ps7_init + ps7_post_config). The test logic is held in reset until
//     then, because before that the DDR controller is not running and the
//     PL-PS level shifters are off, so no AXI access could complete.
//
// LEDs: DS15 heartbeat (PL clock alive), DS16 on while the test is running
// (PS initialized), DS17 on once any pass has failed.
// =============================================================================

`timescale 1ns / 1ps

module ddr_test_top (
    input  logic sys_clk_p,    // 200 MHz LVDS system clock (U43)
    input  logic sys_clk_n,
    input  logic btn_rst,      // SW5 (left pushbutton), active high
    output logic uart_tx_pin,  // to USB-UART RXD (J63.1)
    output logic led_alive,    // DS15
    output logic led_running,  // DS16
    output logic led_fail,     // DS17

    // Zynq PS pins (fixed locations, handled by the PS7 block)
    inout wire [14:0] DDR_addr,
    inout wire [ 2:0] DDR_ba,
    inout wire        DDR_cas_n,
    inout wire        DDR_ck_n,
    inout wire        DDR_ck_p,
    inout wire        DDR_cke,
    inout wire        DDR_cs_n,
    inout wire [ 3:0] DDR_dm,
    inout wire [31:0] DDR_dq,
    inout wire [ 3:0] DDR_dqs_n,
    inout wire [ 3:0] DDR_dqs_p,
    inout wire        DDR_odt,
    inout wire        DDR_ras_n,
    inout wire        DDR_reset_n,
    inout wire        DDR_we_n,
    inout wire        FIXED_IO_ddr_vrn,
    inout wire        FIXED_IO_ddr_vrp,
    inout wire [53:0] FIXED_IO_mio,
    inout wire        FIXED_IO_ps_clk,
    inout wire        FIXED_IO_ps_porb,
    inout wire        FIXED_IO_ps_srstb
);

  // ---------------------------------------------------------------------
  // Clock: 200 MHz -> 50 MHz (VCO = 200 MHz * 5 = 1000 MHz, / 20).
  // ---------------------------------------------------------------------
  logic sys_clk, clk_mmcm, clk, clkfb, locked;

  IBUFDS u_ibufds (
      .I (sys_clk_p),
      .IB(sys_clk_n),
      .O (sys_clk)
  );

  MMCME2_BASE #(
      .CLKIN1_PERIOD   (5.0),
      .CLKFBOUT_MULT_F (5.0),
      .CLKOUT0_DIVIDE_F(20.0),
      .DIVCLK_DIVIDE   (1)
  ) u_mmcm (
      .CLKIN1  (sys_clk),
      .CLKFBIN (clkfb),
      .CLKFBOUT(clkfb),
      .CLKOUT0 (clk_mmcm),
      .LOCKED  (locked),
      .PWRDWN  (1'b0),
      .RST     (1'b0)
  );

  BUFG u_bufg (
      .I(clk_mmcm),
      .O(clk)
  );

  // ---------------------------------------------------------------------
  // Reset: asynchronous assert (button, MMCM unlock, or PS not initialized),
  // synchronous release.
  // ---------------------------------------------------------------------
  logic       fclk_reset0_n;
  logic [3:0] rst_sr;
  logic       arst_n;
  logic       rst_n;

  assign arst_n = locked & ~btn_rst & fclk_reset0_n;

  always_ff @(posedge clk or negedge arst_n) begin
    if (!arst_n) rst_sr <= '0;
    else rst_sr <= {rst_sr[2:0], 1'b1};
  end

  assign rst_n = rst_sr[3];

  // ---------------------------------------------------------------------
  // Test logic and AXI master.
  // ---------------------------------------------------------------------
  logic        req_valid, req_write, req_done, req_error;
  logic [31:0] req_addr, req_wdata, req_rdata;
  logic [ 3:0] req_wstrb;

  ddr_test_core u_core (
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
      .uart_tx    (uart_tx_pin),
      .fail_sticky(led_fail)
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

  // ---------------------------------------------------------------------
  // Zynq processing system (generated block-design wrapper).
  // ---------------------------------------------------------------------
  ps7_bd_wrapper u_ps7 (
      .DDR_addr         (DDR_addr),
      .DDR_ba           (DDR_ba),
      .DDR_cas_n        (DDR_cas_n),
      .DDR_ck_n         (DDR_ck_n),
      .DDR_ck_p         (DDR_ck_p),
      .DDR_cke          (DDR_cke),
      .DDR_cs_n         (DDR_cs_n),
      .DDR_dm           (DDR_dm),
      .DDR_dq           (DDR_dq),
      .DDR_dqs_n        (DDR_dqs_n),
      .DDR_dqs_p        (DDR_dqs_p),
      .DDR_odt          (DDR_odt),
      .DDR_ras_n        (DDR_ras_n),
      .DDR_reset_n      (DDR_reset_n),
      .DDR_we_n         (DDR_we_n),
      .FIXED_IO_ddr_vrn (FIXED_IO_ddr_vrn),
      .FIXED_IO_ddr_vrp (FIXED_IO_ddr_vrp),
      .FIXED_IO_mio     (FIXED_IO_mio),
      .FIXED_IO_ps_clk  (FIXED_IO_ps_clk),
      .FIXED_IO_ps_porb (FIXED_IO_ps_porb),
      .FIXED_IO_ps_srstb(FIXED_IO_ps_srstb),
      .hp0_aclk         (clk),
      .fclk_reset0_n    (fclk_reset0_n),
      .S_AXI_HP0_awid   (awid),
      .S_AXI_HP0_awaddr (awaddr),
      .S_AXI_HP0_awlen  (awlen),
      .S_AXI_HP0_awsize (awsize),
      .S_AXI_HP0_awburst(awburst),
      .S_AXI_HP0_awlock (awlock),
      .S_AXI_HP0_awcache(awcache),
      .S_AXI_HP0_awprot (awprot),
      .S_AXI_HP0_awqos  (awqos),
      .S_AXI_HP0_awvalid(awvalid),
      .S_AXI_HP0_awready(awready),
      .S_AXI_HP0_wid    (wid),
      .S_AXI_HP0_wdata  (wdata),
      .S_AXI_HP0_wstrb  (wstrb),
      .S_AXI_HP0_wlast  (wlast),
      .S_AXI_HP0_wvalid (wvalid),
      .S_AXI_HP0_wready (wready),
      .S_AXI_HP0_bid    (bid),
      .S_AXI_HP0_bresp  (bresp),
      .S_AXI_HP0_bvalid (bvalid),
      .S_AXI_HP0_bready (bready),
      .S_AXI_HP0_arid   (arid),
      .S_AXI_HP0_araddr (araddr),
      .S_AXI_HP0_arlen  (arlen),
      .S_AXI_HP0_arsize (arsize),
      .S_AXI_HP0_arburst(arburst),
      .S_AXI_HP0_arlock (arlock),
      .S_AXI_HP0_arcache(arcache),
      .S_AXI_HP0_arprot (arprot),
      .S_AXI_HP0_arqos  (arqos),
      .S_AXI_HP0_arvalid(arvalid),
      .S_AXI_HP0_arready(arready),
      .S_AXI_HP0_rid    (rid),
      .S_AXI_HP0_rdata  (rdata),
      .S_AXI_HP0_rresp  (rresp),
      .S_AXI_HP0_rlast  (rlast),
      .S_AXI_HP0_rvalid (rvalid),
      .S_AXI_HP0_rready (rready)
  );

  // ---------------------------------------------------------------------
  // LEDs.
  // ---------------------------------------------------------------------
  logic [25:0] hb_q = '0;

  always_ff @(posedge clk) hb_q <= hb_q + 26'd1;

  assign led_alive   = hb_q[25];
  assign led_running = rst_n;

endmodule
