// =============================================================================
// fpga/zc702/uart_test/uart_test_top.sv
// =============================================================================
// Milestone 0: standalone UART link check for the ZC702, with no CPU. Proves
// the clock path, reset button, Pmod pins, level shifters, USB-UART adapter
// and terminal settings before soc_top is brought up on the board.
//
// - Default: transmits "yoctorv32 UART OK\r\n" at 9600 8N1, then pauses
//   ~0.67 s and repeats.
// - While SW7 is held: uart_tx_pin is a raw combinational copy of
//   uart_rx_pin, so typed characters echo back. This path does not depend on
//   the clock or reset at all.
//
// The clock (200 MHz LVDS -> 50 MHz MMCM), reset synchronizer and pinout are
// the ones the milestone 1 fpga_top will reuse unchanged. 9600 baud because
// UG850 limits the LED-loaded Pmod nets to roughly 100 kHz toggle rate.
// =============================================================================

`timescale 1ns / 1ps

module uart_test_top (
    input  logic sys_clk_p,    // 200 MHz LVDS system clock (U43)
    input  logic sys_clk_n,
    input  logic btn_rst,      // SW5 (left pushbutton), active high
    input  logic btn_loop,     // SW7 (right pushbutton): hold for raw loopback
    input  logic uart_rx_pin,  // from USB-UART TXD (J63.3)
    output logic uart_tx_pin,  // to USB-UART RXD (J63.1)
    output logic led_alive     // heartbeat, LED DS15
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
  // Message transmitter.
  // ---------------------------------------------------------------------
  localparam int ClkHz = 50_000_000;
  localparam int Baud = 9600;
  localparam int BitCycles = ClkHz / Baud;  // 5208 clk cycles per bit
  localparam int MsgLen = 19;
  // First character sits in the most significant byte.
  localparam logic [8*MsgLen-1:0] Msg = {"yoctorv32 UART OK", 8'h0D, 8'h0A};

  logic [12:0] baud_cnt_q;
  logic [ 3:0] bit_idx_q;  // 0..9 across the 10-bit frame (start, 8 data, stop)
  logic [ 4:0] char_idx_q;
  logic [ 9:0] frame_q;  // {stop, data[7:0], start}, shifted out LSB first
  logic [24:0] gap_cnt_q;  // 2^25 cycles @ 50 MHz = ~0.67 s between messages
  logic        sending_q;
  logic        tx_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      baud_cnt_q <= '0;
      bit_idx_q  <= '0;
      char_idx_q <= '0;
      frame_q    <= '1;
      gap_cnt_q  <= '0;
      sending_q  <= 1'b0;
      tx_q       <= 1'b1;
    end else if (!sending_q) begin
      tx_q <= 1'b1;
      if (char_idx_q == MsgLen) begin
        // Whole message sent: idle the line, then start over.
        gap_cnt_q <= gap_cnt_q + 25'd1;
        if (&gap_cnt_q) char_idx_q <= '0;
      end else begin
        frame_q    <= {1'b1, Msg[8*(MsgLen-1-char_idx_q)+:8], 1'b0};
        sending_q  <= 1'b1;
        baud_cnt_q <= '0;
        bit_idx_q  <= '0;
      end
    end else begin
      tx_q <= frame_q[0];
      if (baud_cnt_q == 13'(BitCycles - 1)) begin
        baud_cnt_q <= '0;
        frame_q    <= {1'b1, frame_q[9:1]};
        if (bit_idx_q == 4'd9) begin
          sending_q  <= 1'b0;
          char_idx_q <= char_idx_q + 5'd1;
        end else begin
          bit_idx_q <= bit_idx_q + 4'd1;
        end
      end else begin
        baud_cnt_q <= baud_cnt_q + 13'd1;
      end
    end
  end

  // Raw loopback is purely combinational, so it still works with a dead clock.
  assign uart_tx_pin = btn_loop ? uart_rx_pin : tx_q;

  // ---------------------------------------------------------------------
  // Heartbeat: toggles every 2^25 cycles (~0.67 s) while clk is running.
  // ---------------------------------------------------------------------
  logic [25:0] hb_q = '0;

  always_ff @(posedge clk) hb_q <= hb_q + 26'd1;

  assign led_alive = hb_q[25];

endmodule
