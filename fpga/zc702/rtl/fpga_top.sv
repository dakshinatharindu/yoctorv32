// =============================================================================
// fpga/zc702/rtl/fpga_top.sv
// =============================================================================
// Milestone 1 board top for the ZC702 (xc7z020clg484-1): soc_top running a
// bare-metal program out of block RAM, with its UART on Pmod header J63.
//
// The clock (200 MHz LVDS -> 50 MHz MMCM), reset synchronizer and pinout are
// the ones proven on hardware by fpga/zc702/uart_test/.
//
// Memory: one 64 KiB true-dual-port block RAM, initialized from hello.mem
// (see fpga/zc702/sw/hello/build.sh). Port A serves instruction fetch, port B
// serves the data port. Both are synchronous-read with NO output register,
// which is exactly the 1-cycle latency core_top assumes. Only the low address
// bits are decoded, so the RAM aliases across the whole address space: it
// answers at 0x0000_0000 (core_pkg::RESET_PC, where the program is linked)
// and would equally answer at 0x8000_0000. soc_top's data_bus has already
// removed CLINT/UART/PLIC accesses before they reach this level.
//
// The clock frequency here must match CLK_HZ in sw/hello/build.sh, because
// the program derives the UART baud divisor from it.
// =============================================================================

`timescale 1ns / 1ps

module fpga_top #(
    // Resolved relative to the directory Vivado synthesis runs in; build.tcl
    // changes into fpga/zc702/build/ before synth_design.
    parameter MEM_INIT_FILE = "hello.mem"
) (
    input  logic sys_clk_p,    // 200 MHz LVDS system clock (U43)
    input  logic sys_clk_n,
    input  logic btn_rst,      // SW5 (left pushbutton), active high
    input  logic uart_rx_pin,  // from USB-UART TXD (J63.3)
    output logic uart_tx_pin,  // to USB-UART RXD (J63.1)
    output logic led_alive     // heartbeat, LED DS15
);

  import core_pkg::*;

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
  // Reset: asynchronous assert (button or MMCM unlock), synchronous release.
  // ---------------------------------------------------------------------
  logic [3:0] rst_sr;
  logic       arst_n;
  logic       rst_n;

  assign arst_n = locked & ~btn_rst;

  always_ff @(posedge clk or negedge arst_n) begin
    if (!arst_n) rst_sr <= '0;
    else rst_sr <= {rst_sr[2:0], 1'b1};
  end

  assign rst_n = rst_sr[3];

  // ---------------------------------------------------------------------
  // uart_rx_pin is asynchronous to clk; uart.sv samples it through a single
  // flop, so synchronize it here first. Idles high, like the line itself.
  // ---------------------------------------------------------------------
  logic [1:0] rx_sync_q = 2'b11;

  always_ff @(posedge clk) rx_sync_q <= {rx_sync_q[0], uart_rx_pin};

  // ---------------------------------------------------------------------
  // SoC.
  // ---------------------------------------------------------------------
  xlen_t imem_addr, imem_rdata;
  xlen_t dmem_addr, dmem_wdata, dmem_rdata;
  logic [3:0] dmem_wstrb;
  logic       dmem_re;

  soc_top u_soc_top (
      .clk       (clk),
      .rst_n     (rst_n),
      .imem_addr (imem_addr),
      .imem_rdata(imem_rdata),
      .dmem_addr (dmem_addr),
      .dmem_wdata(dmem_wdata),
      .dmem_wstrb(dmem_wstrb),
      .dmem_re   (dmem_re),
      .dmem_rdata(dmem_rdata),
      .uart_tx   (uart_tx_pin),
      .uart_rx   (rx_sync_q[1])
  );

  // ---------------------------------------------------------------------
  // 64 KiB block RAM, 32-bit words, byte write enables.
  //
  // Reads are unconditional (dmem_re is not used): the core only consumes
  // dmem_rdata for an instruction that actually issued a load, and reading
  // has no side effects here. This mirrors the testbench memory models.
  // ---------------------------------------------------------------------
  localparam int MemAddrBits = 14;  // 2^14 words = 64 KiB

  (* ram_style = "block" *)
  logic [31:0] mem[2**MemAddrBits];

  initial $readmemh(MEM_INIT_FILE, mem);

  logic [MemAddrBits-1:0] imem_widx, dmem_widx;
  assign imem_widx = imem_addr[MemAddrBits+1:2];
  assign dmem_widx = dmem_addr[MemAddrBits+1:2];

  // Port A: instruction fetch, read only.
  always_ff @(posedge clk) begin
    imem_rdata <= mem[imem_widx];
  end

  // Port B: data, read-first with per-byte writes.
  always_ff @(posedge clk) begin
    for (int i = 0; i < 4; i++) begin
      if (dmem_wstrb[i]) mem[dmem_widx][8*i+:8] <= dmem_wdata[8*i+:8];
    end
    dmem_rdata <= mem[dmem_widx];
  end

  // ---------------------------------------------------------------------
  // Heartbeat: toggles every 2^25 cycles (~0.67 s) while clk is running.
  // ---------------------------------------------------------------------
  logic [25:0] hb_q = '0;

  always_ff @(posedge clk) hb_q <= hb_q + 26'd1;

  assign led_alive = hb_q[25];

endmodule
