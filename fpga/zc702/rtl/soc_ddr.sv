// =============================================================================
// fpga/zc702/rtl/soc_ddr.sv
// =============================================================================
// soc_top running out of PS DDR: soc_top + mem_bridge + hp_axi_master, with
// the AXI3 master port left open at the top. Free of vendor primitives, so
// the board top (fpga_top_ddr.sv) connects the port to the Zynq PS and the
// simulation (tb/fpga/soc_ddr_tb.sv) connects it to axi_ram_model.
//
// Two levels of reset:
//   hard_rst_n  resets everything, including the AXI master. Asynchronous
//               assert, synchronous release. Only for power-up/configuration,
//               when no AXI transaction can be in flight.
//   rst_req     restarts the SoC and the bridge, and is safe at any moment:
//               the reset button and the PS's reset output go here. The AXI
//               master is left alone so that a transaction in flight still
//               completes, and the SoC is only let go again once the master
//               has been idle for a while. May be asynchronous to clk.
//
// uart_rx may be asynchronous to clk as well; it is synchronized here.
// =============================================================================

`timescale 1ns / 1ps

module soc_ddr #(
    parameter int unsigned BOOT_BYTES     = 4096,
    parameter              BOOT_INIT_FILE = "",
    parameter logic [31:0] RAM_BASE       = 32'h8000_0000,
    parameter logic [31:0] RAM_BYTES      = 32'h0400_0000,
    parameter logic [31:0] DDR_BASE       = 32'h1000_0000,
    parameter int          ID_WIDTH       = 6
) (
    input logic clk,
    input logic hard_rst_n,
    input logic rst_req,

    output logic uart_tx,
    input  logic uart_rx,

    output logic running,    // the SoC is out of reset
    output logic bus_error,  // sticky: an AXI access returned an error

    // AXI3 master, to the PS's S_AXI_HP port
    output logic [ID_WIDTH-1:0] m_axi_awid,
    output logic [        31:0] m_axi_awaddr,
    output logic [         3:0] m_axi_awlen,
    output logic [         2:0] m_axi_awsize,
    output logic [         1:0] m_axi_awburst,
    output logic [         1:0] m_axi_awlock,
    output logic [         3:0] m_axi_awcache,
    output logic [         2:0] m_axi_awprot,
    output logic [         3:0] m_axi_awqos,
    output logic                m_axi_awvalid,
    input  logic                m_axi_awready,
    output logic [ID_WIDTH-1:0] m_axi_wid,
    output logic [        31:0] m_axi_wdata,
    output logic [         3:0] m_axi_wstrb,
    output logic                m_axi_wlast,
    output logic                m_axi_wvalid,
    input  logic                m_axi_wready,
    input  logic [ID_WIDTH-1:0] m_axi_bid,
    input  logic [         1:0] m_axi_bresp,
    input  logic                m_axi_bvalid,
    output logic                m_axi_bready,
    output logic [ID_WIDTH-1:0] m_axi_arid,
    output logic [        31:0] m_axi_araddr,
    output logic [         3:0] m_axi_arlen,
    output logic [         2:0] m_axi_arsize,
    output logic [         1:0] m_axi_arburst,
    output logic [         1:0] m_axi_arlock,
    output logic [         3:0] m_axi_arcache,
    output logic [         2:0] m_axi_arprot,
    output logic [         3:0] m_axi_arqos,
    output logic                m_axi_arvalid,
    input  logic                m_axi_arready,
    input  logic [ID_WIDTH-1:0] m_axi_rid,
    input  logic [        31:0] m_axi_rdata,
    input  logic [         1:0] m_axi_rresp,
    input  logic                m_axi_rlast,
    input  logic                m_axi_rvalid,
    output logic                m_axi_rready
);

  import core_pkg::*;

  // ---------------------------------------------------------------------
  // SoC reset sequencing. A reset request takes effect at once; the release
  // waits until the request is gone and the AXI master has stayed idle for
  // 16 clocks, so the bridge never restarts against a transaction (or its
  // late req_done) left over from before the reset.
  // ---------------------------------------------------------------------
  logic       master_busy;
  logic [1:0] rst_req_sync_q;
  logic       in_reset_q;
  logic [3:0] quiet_q;
  logic       rst_n;

  always_ff @(posedge clk or negedge hard_rst_n) begin
    if (!hard_rst_n) begin
      rst_req_sync_q <= 2'b11;
      in_reset_q     <= 1'b1;
      quiet_q        <= 4'd0;
    end else begin
      rst_req_sync_q <= {rst_req_sync_q[0], rst_req};
      if (rst_req_sync_q[1]) begin
        in_reset_q <= 1'b1;
        quiet_q    <= 4'd0;
      end else if (in_reset_q) begin
        if (master_busy) quiet_q <= 4'd0;
        else if (quiet_q == 4'd15) in_reset_q <= 1'b0;
        else quiet_q <= quiet_q + 4'd1;
      end
    end
  end

  assign rst_n   = !in_reset_q;
  assign running = rst_n;

  // ---------------------------------------------------------------------
  // uart.sv samples rx through a single flop; synchronize it first. Idles
  // high, like the line itself.
  // ---------------------------------------------------------------------
  logic [1:0] rx_sync_q;

  always_ff @(posedge clk or negedge hard_rst_n) begin
    if (!hard_rst_n) rx_sync_q <= 2'b11;
    else rx_sync_q <= {rx_sync_q[0], uart_rx};
  end

  // ---------------------------------------------------------------------
  // SoC, bridge, AXI master.
  // ---------------------------------------------------------------------
  xlen_t imem_addr, imem_rdata;
  xlen_t dmem_addr, dmem_wdata, dmem_rdata;
  logic [3:0] dmem_wstrb;
  logic       dmem_re;
  logic       ce;

  soc_top u_soc_top (
      .clk       (clk),
      .rst_n     (rst_n),
      .ce        (ce),
      .imem_addr (imem_addr),
      .imem_rdata(imem_rdata),
      .dmem_addr (dmem_addr),
      .dmem_wdata(dmem_wdata),
      .dmem_wstrb(dmem_wstrb),
      .dmem_re   (dmem_re),
      .dmem_rdata(dmem_rdata),
      .uart_tx   (uart_tx),
      .uart_rx   (rx_sync_q[1])
  );

  logic        req_valid, req_write, req_done, req_error;
  logic [31:0] req_addr, req_wdata, req_rdata;
  logic [ 3:0] req_wstrb;

  mem_bridge #(
      .BOOT_BYTES    (BOOT_BYTES),
      .BOOT_INIT_FILE(BOOT_INIT_FILE),
      .RAM_BASE      (RAM_BASE),
      .RAM_BYTES     (RAM_BYTES),
      .DDR_BASE      (DDR_BASE)
  ) u_bridge (
      .clk       (clk),
      .rst_n     (rst_n),
      .imem_addr (imem_addr),
      .imem_rdata(imem_rdata),
      .dmem_addr (dmem_addr),
      .dmem_wdata(dmem_wdata),
      .dmem_wstrb(dmem_wstrb),
      .dmem_re   (dmem_re),
      .dmem_rdata(dmem_rdata),
      .ce        (ce),
      .req_valid (req_valid),
      .req_write (req_write),
      .req_addr  (req_addr),
      .req_wdata (req_wdata),
      .req_wstrb (req_wstrb),
      .req_done  (req_done),
      .req_rdata (req_rdata),
      .req_error (req_error),
      .bus_error (bus_error)
  );

  hp_axi_master #(
      .ID_WIDTH(ID_WIDTH)
  ) u_master (
      .clk          (clk),
      .rst_n        (hard_rst_n),
      .req_valid    (req_valid),
      .req_write    (req_write),
      .req_addr     (req_addr),
      .req_wdata    (req_wdata),
      .req_wstrb    (req_wstrb),
      .req_done     (req_done),
      .req_rdata    (req_rdata),
      .req_error    (req_error),
      .busy         (master_busy),
      .m_axi_awid   (m_axi_awid),
      .m_axi_awaddr (m_axi_awaddr),
      .m_axi_awlen  (m_axi_awlen),
      .m_axi_awsize (m_axi_awsize),
      .m_axi_awburst(m_axi_awburst),
      .m_axi_awlock (m_axi_awlock),
      .m_axi_awcache(m_axi_awcache),
      .m_axi_awprot (m_axi_awprot),
      .m_axi_awqos  (m_axi_awqos),
      .m_axi_awvalid(m_axi_awvalid),
      .m_axi_awready(m_axi_awready),
      .m_axi_wid    (m_axi_wid),
      .m_axi_wdata  (m_axi_wdata),
      .m_axi_wstrb  (m_axi_wstrb),
      .m_axi_wlast  (m_axi_wlast),
      .m_axi_wvalid (m_axi_wvalid),
      .m_axi_wready (m_axi_wready),
      .m_axi_bid    (m_axi_bid),
      .m_axi_bresp  (m_axi_bresp),
      .m_axi_bvalid (m_axi_bvalid),
      .m_axi_bready (m_axi_bready),
      .m_axi_arid   (m_axi_arid),
      .m_axi_araddr (m_axi_araddr),
      .m_axi_arlen  (m_axi_arlen),
      .m_axi_arsize (m_axi_arsize),
      .m_axi_arburst(m_axi_arburst),
      .m_axi_arlock (m_axi_arlock),
      .m_axi_arcache(m_axi_arcache),
      .m_axi_arprot (m_axi_arprot),
      .m_axi_arqos  (m_axi_arqos),
      .m_axi_arvalid(m_axi_arvalid),
      .m_axi_arready(m_axi_arready),
      .m_axi_rid    (m_axi_rid),
      .m_axi_rdata  (m_axi_rdata),
      .m_axi_rresp  (m_axi_rresp),
      .m_axi_rlast  (m_axi_rlast),
      .m_axi_rvalid (m_axi_rvalid),
      .m_axi_rready (m_axi_rready)
  );

endmodule
