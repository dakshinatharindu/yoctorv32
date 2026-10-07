// =============================================================================
// tb/fpga/axi_ram_model.sv
// =============================================================================
// Simulation stand-in for the Zynq PS's S_AXI_HP port with DDR behind it: an
// AXI3 slave backed by a sparse 32-bit-word memory covering the whole 4 GiB
// address space (unwritten words read as zero). Used to exercise the FPGA-side
// logic under fpga/ without the real PS.
//
// It accepts what fpga/zc702/rtl/hp_axi_master.sv issues, single-beat 4-byte
// transfers, and reports anything else as an error. Every handshake is
// delayed by a random 0..MAX_DELAY cycles, independently per channel, so the
// master sees address and data accepted in either order and responses after
// a varying wait, as with the real port.
//
// Plusargs (all optional):
//   +AXI_MAX_DELAY=<n>  override MAX_DELAY at run time
//   +AXI_RD_DELAY=<n>   fixed timing instead of random: addresses and write
//   +AXI_WR_DELAY=<n>   data are accepted at once and the response follows
//                       after exactly n cycles. Use both together, to mimic
//                       a measured port (the ZC702's HP0 at 50 MHz behaves
//                       like RD=11, WR=8 as seen through hp_axi_master).
//
// Backdoor access for testbenches: peek() and poke() take byte addresses.
// fault_en/fault_addr flip one bit of the data read from one word, to check
// that a memory test really detects errors.
// =============================================================================

`timescale 1ns / 1ps

module axi_ram_model #(
    parameter int ID_WIDTH  = 6,
    parameter int MAX_DELAY = 6
) (
    input logic clk,
    input logic rst_n,

    input logic        fault_en,
    input logic [31:0] fault_addr,

    input  logic [ID_WIDTH-1:0] s_axi_awid,
    input  logic [        31:0] s_axi_awaddr,
    input  logic [         3:0] s_axi_awlen,
    input  logic [         2:0] s_axi_awsize,
    input  logic [         1:0] s_axi_awburst,
    input  logic                s_axi_awvalid,
    output logic                s_axi_awready,

    input  logic [ID_WIDTH-1:0] s_axi_wid,
    input  logic [        31:0] s_axi_wdata,
    input  logic [         3:0] s_axi_wstrb,
    input  logic                s_axi_wlast,
    input  logic                s_axi_wvalid,
    output logic                s_axi_wready,

    output logic [ID_WIDTH-1:0] s_axi_bid,
    output logic [         1:0] s_axi_bresp,
    output logic                s_axi_bvalid,
    input  logic                s_axi_bready,

    input  logic [ID_WIDTH-1:0] s_axi_arid,
    input  logic [        31:0] s_axi_araddr,
    input  logic [         3:0] s_axi_arlen,
    input  logic [         2:0] s_axi_arsize,
    input  logic [         1:0] s_axi_arburst,
    input  logic                s_axi_arvalid,
    output logic                s_axi_arready,

    output logic [ID_WIDTH-1:0] s_axi_rid,
    output logic [        31:0] s_axi_rdata,
    output logic [         1:0] s_axi_rresp,
    output logic                s_axi_rlast,
    output logic                s_axi_rvalid,
    input  logic                s_axi_rready
);

  // Sparse memory, indexed by word address.
  logic [31:0] mem[logic [29:0]];

  function automatic logic [31:0] peek(input logic [31:0] addr);
    return mem.exists(addr[31:2]) ? mem[addr[31:2]] : 32'h0;
  endfunction

  function automatic void poke(input logic [31:0] addr, input logic [31:0] data);
    mem[addr[31:2]] = data;
  endfunction

  int unsigned max_delay = MAX_DELAY;
  int          rd_delay_fixed = -1;
  int          wr_delay_fixed = -1;

  initial begin
    void'($value$plusargs("AXI_MAX_DELAY=%d", max_delay));
    void'($value$plusargs("AXI_RD_DELAY=%d", rd_delay_fixed));
    void'($value$plusargs("AXI_WR_DELAY=%d", wr_delay_fixed));
  end

  logic fixed_timing;
  assign fixed_timing = (rd_delay_fixed >= 0) && (wr_delay_fixed >= 0);

  // Delay before accepting an address or write data.
  function automatic int unsigned accept_delay();
    if (fixed_timing || max_delay == 0) return 0;
    return $urandom_range(max_delay);
  endfunction

  // Delay before answering.
  function automatic int unsigned response_delay(input logic is_write);
    if (fixed_timing) return is_write ? wr_delay_fixed : rd_delay_fixed;
    return (max_delay == 0) ? 0 : $urandom_range(max_delay);
  endfunction

  // ---------------------------------------------------------------------
  // Write: take AW and W in whichever order they are offered, then respond.
  // ---------------------------------------------------------------------
  logic aw_got_q, w_got_q;
  int unsigned aw_wait_q, w_wait_q, b_wait_q;
  logic [ID_WIDTH-1:0] aw_id_q;
  logic [31:0] aw_addr_q, w_data_q;
  logic [3:0] w_strb_q;

  assign s_axi_awready = !aw_got_q && (aw_wait_q == 0);
  assign s_axi_wready  = !w_got_q && (w_wait_q == 0);
  assign s_axi_bresp   = 2'b00;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      aw_got_q     <= 1'b0;
      w_got_q      <= 1'b0;
      aw_wait_q    <= 0;
      w_wait_q     <= 0;
      b_wait_q     <= (wr_delay_fixed >= 0) ? wr_delay_fixed : 0;
      s_axi_bvalid <= 1'b0;
      s_axi_bid    <= '0;
    end else begin
      if (s_axi_awvalid && !aw_got_q && aw_wait_q != 0) aw_wait_q <= aw_wait_q - 1;
      if (s_axi_wvalid && !w_got_q && w_wait_q != 0) w_wait_q <= w_wait_q - 1;

      if (s_axi_awvalid && s_axi_awready) begin
        aw_got_q  <= 1'b1;
        aw_id_q   <= s_axi_awid;
        aw_addr_q <= s_axi_awaddr;
        if (s_axi_awlen != 4'd0 || s_axi_awsize != 3'b010 || s_axi_awburst != 2'b01)
          $error("axi_ram_model: unsupported write burst len=%0d size=%0d", s_axi_awlen, s_axi_awsize);
      end
      if (s_axi_wvalid && s_axi_wready) begin
        w_got_q  <= 1'b1;
        w_data_q <= s_axi_wdata;
        w_strb_q <= s_axi_wstrb;
        if (!s_axi_wlast) $error("axi_ram_model: WLAST low on a single-beat write");
      end

      if (aw_got_q && w_got_q && !s_axi_bvalid) begin
        if (b_wait_q != 0) begin
          b_wait_q <= b_wait_q - 1;
        end else begin
          automatic logic [31:0] old = peek(aw_addr_q);
          for (int i = 0; i < 4; i++) if (w_strb_q[i]) old[8*i+:8] = w_data_q[8*i+:8];
          mem[aw_addr_q[31:2]] = old;
          s_axi_bvalid <= 1'b1;
          s_axi_bid    <= aw_id_q;
        end
      end

      if (s_axi_bvalid && s_axi_bready) begin
        s_axi_bvalid <= 1'b0;
        aw_got_q     <= 1'b0;
        w_got_q      <= 1'b0;
        aw_wait_q    <= accept_delay();
        w_wait_q     <= accept_delay();
        b_wait_q     <= response_delay(1'b1);
      end
    end
  end

  // ---------------------------------------------------------------------
  // Read.
  // ---------------------------------------------------------------------
  logic ar_got_q;
  int unsigned ar_wait_q, r_wait_q;
  logic [ID_WIDTH-1:0] ar_id_q;
  logic [31:0] ar_addr_q;

  assign s_axi_arready = !ar_got_q && (ar_wait_q == 0);
  assign s_axi_rresp   = 2'b00;
  assign s_axi_rlast   = s_axi_rvalid;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ar_got_q     <= 1'b0;
      ar_wait_q    <= 0;
      r_wait_q     <= (rd_delay_fixed >= 0) ? rd_delay_fixed : 0;
      s_axi_rvalid <= 1'b0;
      s_axi_rid    <= '0;
      s_axi_rdata  <= '0;
    end else begin
      if (s_axi_arvalid && !ar_got_q && ar_wait_q != 0) ar_wait_q <= ar_wait_q - 1;

      if (s_axi_arvalid && s_axi_arready) begin
        ar_got_q  <= 1'b1;
        ar_id_q   <= s_axi_arid;
        ar_addr_q <= s_axi_araddr;
        if (s_axi_arlen != 4'd0 || s_axi_arsize != 3'b010 || s_axi_arburst != 2'b01)
          $error("axi_ram_model: unsupported read burst len=%0d size=%0d", s_axi_arlen, s_axi_arsize);
      end

      if (ar_got_q && !s_axi_rvalid) begin
        if (r_wait_q != 0) begin
          r_wait_q <= r_wait_q - 1;
        end else begin
          s_axi_rvalid <= 1'b1;
          s_axi_rid    <= ar_id_q;
          s_axi_rdata  <= peek(ar_addr_q) ^
              ((fault_en && ar_addr_q[31:2] == fault_addr[31:2]) ? 32'h0000_0020 : 32'h0);
        end
      end

      if (s_axi_rvalid && s_axi_rready) begin
        s_axi_rvalid <= 1'b0;
        ar_got_q     <= 1'b0;
        ar_wait_q    <= accept_delay();
        r_wait_q     <= response_delay(1'b0);
      end
    end
  end

  // ---------------------------------------------------------------------
  // Protocol check: once VALID is raised it must stay up, with its payload
  // unchanged, until the handshake.
  // ---------------------------------------------------------------------
  logic aw_pend_q, w_pend_q, ar_pend_q;
  logic [31:0] aw_chk_q, w_chk_q, ar_chk_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      aw_pend_q <= 1'b0;
      w_pend_q  <= 1'b0;
      ar_pend_q <= 1'b0;
    end else begin
      if (aw_pend_q && (!s_axi_awvalid || s_axi_awaddr != aw_chk_q))
        $error("axi_ram_model: AWVALID/AWADDR changed before AWREADY");
      if (w_pend_q && (!s_axi_wvalid || s_axi_wdata != w_chk_q))
        $error("axi_ram_model: WVALID/WDATA changed before WREADY");
      if (ar_pend_q && (!s_axi_arvalid || s_axi_araddr != ar_chk_q))
        $error("axi_ram_model: ARVALID/ARADDR changed before ARREADY");

      aw_pend_q <= s_axi_awvalid && !s_axi_awready;
      w_pend_q  <= s_axi_wvalid && !s_axi_wready;
      ar_pend_q <= s_axi_arvalid && !s_axi_arready;
      aw_chk_q  <= s_axi_awaddr;
      w_chk_q   <= s_axi_wdata;
      ar_chk_q  <= s_axi_araddr;
    end
  end

endmodule
