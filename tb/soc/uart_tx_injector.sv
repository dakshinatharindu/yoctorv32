// =============================================================================
// tb/soc/uart_tx_injector.sv
// =============================================================================
// Testbench-only UART transmitter: the mirror image of uart_rx_monitor.sv,
// used to inject a byte onto a wire as if an external peer sent it (drives
// the DUT's uart.sv rx input). Structurally the same 10-bit start/8-data/
// stop frame shifter as uart.sv's own real TX shifter, just living in the
// testbench instead of the DUT.
// =============================================================================

`timescale 1ns / 1ps

module uart_tx_injector #(
    parameter int BIT_PERIOD_CYCLES = 16
) (
    input logic clk,
    input logic rst_n,

    input  logic       send,  // pulse for 1 cycle to start sending send_byte
    input  logic [7:0] send_byte,
    output logic       busy,

    output logic tx
);

  logic [31:0] cyc_cnt_q;
  logic [ 3:0] bit_idx_q;
  logic [ 9:0] shift_q;
  logic        busy_q;
  logic        tx_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cyc_cnt_q <= 32'd0;
      bit_idx_q <= 4'd0;
      shift_q   <= 10'h3FF;
      busy_q    <= 1'b0;
      tx_q      <= 1'b1;
    end else if (send && !busy_q) begin
      shift_q   <= {1'b1, send_byte, 1'b0};  // stop, data[7:0], start
      busy_q    <= 1'b1;
      cyc_cnt_q <= 32'd0;
      bit_idx_q <= 4'd0;
    end else if (busy_q) begin
      if (cyc_cnt_q == BIT_PERIOD_CYCLES - 1) begin
        cyc_cnt_q <= 32'd0;
        tx_q      <= shift_q[0];
        shift_q   <= {1'b1, shift_q[9:1]};
        if (bit_idx_q == 4'd9) begin
          busy_q    <= 1'b0;
          bit_idx_q <= 4'd0;
        end else begin
          bit_idx_q <= bit_idx_q + 4'd1;
        end
      end else begin
        cyc_cnt_q <= cyc_cnt_q + 32'd1;
      end
    end
  end

  assign busy = busy_q;
  assign tx   = tx_q;

endmodule
