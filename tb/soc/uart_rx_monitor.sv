// =============================================================================
// tb/soc/uart_rx_monitor.sv
// =============================================================================
// Testbench-only UART receiver: decodes the actual bit-accurate waveform on
// a `tx` line, independent of and blind to the transmitting peripheral's
// internal registers — a genuine check of the hardware output, not just a
// register-readback. Reusable later for injecting bytes into an RX pin
// once that side of uart.sv exists.
//
// BIT_PERIOD_CYCLES must match the divisor the test program under
// verification actually programs into the UART (bit_period = divisor*16
// in uart.sv's own baud generator) — this module has no visibility into
// the DUT's registers, so it has to be told.
//
// Samples the middle of each bit period (1.5 periods after the detected
// start-bit falling edge for the first data bit, then every further period
// for bits 1..7), the same strategy a real UART receiver uses.
// =============================================================================

`timescale 1ns / 1ps

module uart_rx_monitor #(
    parameter int BIT_PERIOD_CYCLES = 16,
    parameter int MAX_BYTES = 64
) (
    input logic clk,
    input logic rst_n,
    input logic tx,

    output logic [7:0] bytes_q[MAX_BYTES],
    output int unsigned byte_count
);

  typedef enum logic [1:0] {
    IDLE,
    SAMPLING,
    COMMIT
  } state_e;

  state_e      state_q;
  logic        tx_q;
  int unsigned cyc_cnt_q;
  int unsigned bit_idx_q;
  logic [ 7:0] shift_q;

  localparam int Half = BIT_PERIOD_CYCLES / 2;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q    <= IDLE;
      tx_q       <= 1'b1;
      cyc_cnt_q  <= 0;
      bit_idx_q  <= 0;
      byte_count <= 0;
      shift_q    <= 8'd0;
    end else begin
      tx_q <= tx;
      unique case (state_q)
        IDLE: begin
          if (tx_q && !tx) begin  // falling edge: start bit begins now
            state_q   <= SAMPLING;
            cyc_cnt_q <= 0;
            bit_idx_q <= 0;
          end
        end

        SAMPLING: begin
          cyc_cnt_q <= cyc_cnt_q + 1;
          // Data bit `bit_idx_q` sits BIT_PERIOD_CYCLES*(bit_idx_q+1) cycles
          // after the start-bit edge; sample at its midpoint.
          if (cyc_cnt_q == BIT_PERIOD_CYCLES * (bit_idx_q + 1) + Half) begin
            shift_q[bit_idx_q] <= tx;
            if (bit_idx_q == 7) state_q <= COMMIT;
            else bit_idx_q <= bit_idx_q + 1;
          end
        end

        COMMIT: begin
          if (byte_count < MAX_BYTES) begin
            bytes_q[byte_count] <= shift_q;
            byte_count          <= byte_count + 1;
          end
          state_q <= IDLE;
        end

        default: state_q <= IDLE;
      endcase
    end
  end

endmodule
