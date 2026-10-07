// =============================================================================
// fpga/zc702/rtl/hp_axi_master.sv
// =============================================================================
// Minimal AXI3 master for the Zynq PS's S_AXI_HP port: one single-beat,
// 32-bit read or write at a time, no bursts and no overlapping transactions.
// This is all the PL needs to use PS DDR as a plain word-addressed memory.
//
// Request port:
//   - A request starts on a cycle where req_valid is 1 and the master is
//     idle. req_write/req_addr/req_wdata/req_wstrb are sampled in that cycle
//     only, so a transaction that has started always runs to completion on
//     the values it started with, even if the requester is reset meanwhile.
//   - req_done pulses for exactly one cycle when the transaction has
//     completed. req_rdata (reads) and req_error (SLVERR/DECERR response)
//     are valid in that cycle and hold until the next req_done.
//   - On the req_done cycle the requester must drop req_valid or present its
//     next request; a request still asserted on the following cycle starts a
//     new transaction.
//
// AW and W are issued together and complete independently, as AXI allows.
// All valid outputs and the response capture are registered, so nothing
// combinational connects the PS7's outputs back to its inputs.
//
// Reset this module only together with the AXI slave (or while idle): an
// AXI transaction cannot be abandoned half way. A requester that needs its
// own reset should instead wait out any transaction in flight, which the
// busy output shows.
// =============================================================================

`timescale 1ns / 1ps

module hp_axi_master #(
    parameter int ID_WIDTH = 6
) (
    input logic clk,
    input logic rst_n,

    input  logic        req_valid,
    input  logic        req_write,
    input  logic [31:0] req_addr,   // byte address, low 2 bits ignored
    input  logic [31:0] req_wdata,
    input  logic [ 3:0] req_wstrb,
    output logic        req_done,
    output logic [31:0] req_rdata,
    output logic        req_error,
    output logic        busy,       // a transaction is in flight

    // AXI3 write address channel
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

    // AXI3 write data channel
    output logic [ID_WIDTH-1:0] m_axi_wid,
    output logic [        31:0] m_axi_wdata,
    output logic [         3:0] m_axi_wstrb,
    output logic                m_axi_wlast,
    output logic                m_axi_wvalid,
    input  logic                m_axi_wready,

    // AXI3 write response channel
    input  logic [ID_WIDTH-1:0] m_axi_bid,
    input  logic [         1:0] m_axi_bresp,
    input  logic                m_axi_bvalid,
    output logic                m_axi_bready,

    // AXI3 read address channel
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

    // AXI3 read data channel
    input  logic [ID_WIDTH-1:0] m_axi_rid,
    input  logic [        31:0] m_axi_rdata,
    input  logic [         1:0] m_axi_rresp,
    input  logic                m_axi_rlast,
    input  logic                m_axi_rvalid,
    output logic                m_axi_rready
);

  typedef enum logic [1:0] {
    ST_IDLE,
    ST_WRITE,
    ST_READ
  } state_e;

  state_e state_q;
  logic awvalid_q, wvalid_q, arvalid_q;
  logic [31:0] addr_q, wdata_q;
  logic [3:0] wstrb_q;

  assign busy = (state_q != ST_IDLE);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q   <= ST_IDLE;
      awvalid_q <= 1'b0;
      wvalid_q  <= 1'b0;
      arvalid_q <= 1'b0;
      addr_q    <= '0;
      wdata_q   <= '0;
      wstrb_q   <= 4'b0000;
      req_done  <= 1'b0;
      req_rdata <= '0;
      req_error <= 1'b0;
    end else begin
      req_done <= 1'b0;

      unique case (state_q)
        ST_IDLE: begin
          // !req_done: the request on the bus during the done cycle is the
          // one that just finished, not a new one.
          if (req_valid && !req_done) begin
            addr_q  <= {req_addr[31:2], 2'b00};
            wdata_q <= req_wdata;
            wstrb_q <= req_wstrb;
            if (req_write) begin
              awvalid_q <= 1'b1;
              wvalid_q  <= 1'b1;
              state_q   <= ST_WRITE;
            end else begin
              arvalid_q <= 1'b1;
              state_q   <= ST_READ;
            end
          end
        end

        ST_WRITE: begin
          if (m_axi_awready) awvalid_q <= 1'b0;
          if (m_axi_wready) wvalid_q <= 1'b0;
          // The slave only responds once it has taken both AW and W.
          if (m_axi_bvalid) begin
            req_error <= m_axi_bresp[1];
            req_done  <= 1'b1;
            state_q   <= ST_IDLE;
          end
        end

        ST_READ: begin
          if (m_axi_arready) arvalid_q <= 1'b0;
          if (m_axi_rvalid) begin
            req_rdata <= m_axi_rdata;
            req_error <= m_axi_rresp[1];
            req_done  <= 1'b1;
            state_q   <= ST_IDLE;
          end
        end

        default: state_q <= ST_IDLE;
      endcase
    end
  end

  // Single-beat, 4-byte, normal non-secure access; "bufferable" only, like
  // the tools' own masters use for DDR.
  assign m_axi_awid    = '0;
  assign m_axi_awaddr  = addr_q;
  assign m_axi_awlen   = 4'd0;
  assign m_axi_awsize  = 3'b010;
  assign m_axi_awburst = 2'b01;
  assign m_axi_awlock  = 2'b00;
  assign m_axi_awcache = 4'b0011;
  assign m_axi_awprot  = 3'b000;
  assign m_axi_awqos   = 4'd0;
  assign m_axi_awvalid = awvalid_q;

  assign m_axi_wid     = '0;
  assign m_axi_wdata   = wdata_q;
  assign m_axi_wstrb   = wstrb_q;
  assign m_axi_wlast   = 1'b1;
  assign m_axi_wvalid  = wvalid_q;

  assign m_axi_bready  = (state_q == ST_WRITE);

  assign m_axi_arid    = '0;
  assign m_axi_araddr  = addr_q;
  assign m_axi_arlen   = 4'd0;
  assign m_axi_arsize  = 3'b010;
  assign m_axi_arburst = 2'b01;
  assign m_axi_arlock  = 2'b00;
  assign m_axi_arcache = 4'b0011;
  assign m_axi_arprot  = 3'b000;
  assign m_axi_arqos   = 4'd0;
  assign m_axi_arvalid = arvalid_q;

  assign m_axi_rready  = (state_q == ST_READ);

  // Unused response fields: only one transaction is ever outstanding, so
  // IDs and RLAST carry no information.
  logic unused;
  assign unused = &{1'b0, m_axi_bid, m_axi_rid, m_axi_rlast, m_axi_bresp[0], m_axi_rresp[0],
                    req_addr[1:0]};

endmodule
