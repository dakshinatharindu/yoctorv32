// =============================================================================
// rtl/core/execute/div_unit.sv
// =============================================================================
// RV32M divide/remainder: multi-cycle iterative unsigned restoring divider
// (radix-2, shift-subtract), sign-corrected at the edges. Latches its
// operands once on the `start` cycle and iterates autonomously afterward —
// it must NOT re-sample the EX-stage forwarding muxes mid-division, since
// execute_stage holds id_ex_q frozen while ex_mem_q/mem_wb_q (and hence
// forward_unit's outputs) keep draining every cycle during the stall.
//
// Latency: 33 cycles per operation (1 latch cycle + 32 shift-subtract
// iterations; `done` pulses on the 32nd iteration, at which point `result`
// is valid combinationally). RV32M special cases (no traps):
//   - divide-by-zero:      quotient = all-ones, remainder = dividend
//   - signed INT_MIN / -1: quotient = INT_MIN, remainder = 0
// =============================================================================

`timescale 1ns / 1ps

module div_unit (
    input logic clk,
    input logic rst_n,

    input logic               start,  // 1-cycle pulse: latch operands, begin
    input core_pkg::alu_op_e  op,     // ALU_DIV / ALU_DIVU / ALU_REM / ALU_REMU
    input core_pkg::xlen_t    dividend_in,
    input core_pkg::xlen_t    divisor_in,

    output logic            busy,
    output logic            done,  // combinational 1-cycle pulse
    output core_pkg::xlen_t result  // combinational, valid when done
);

  import core_pkg::*;

  localparam int unsigned Iters = XLEN;  // 32 shift-subtract iterations

  typedef enum logic {
    ST_IDLE,
    ST_RUN
  } state_e;

  localparam int CntW = $clog2(Iters);
  localparam logic [CntW-1:0] LastIter = CntW'(Iters - 1);

  state_e             state_q;
  logic   [CntW-1:0] cnt_q;

  xlen_t divd_q;  // working dividend -> quotient shift register
  xlen_t div_q;  // absolute divisor
  xlen_t rem_q;
  xlen_t dividend_orig_q;

  logic    sign_quo_q, sign_rem_q, divzero_q, ovf_q;
  alu_op_e op_q;

  logic is_signed_start;
  assign is_signed_start = (op == ALU_DIV) || (op == ALU_REM);

  // Combinational shift-subtract step for the current iteration.
  xlen_t rem_shift, rem_nxt, divd_nxt;

  assign rem_shift = {rem_q[XLEN-2:0], divd_q[XLEN-1]};

  always_comb begin
    if (rem_shift >= div_q) begin
      rem_nxt  = rem_shift - div_q;
      divd_nxt = {divd_q[XLEN-2:0], 1'b1};
    end else begin
      rem_nxt  = rem_shift;
      divd_nxt = {divd_q[XLEN-2:0], 1'b0};
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q <= ST_IDLE;
      cnt_q   <= '0;
    end else if (state_q == ST_IDLE) begin
      if (start) begin
        dividend_orig_q <= dividend_in;
        divzero_q       <= (divisor_in == '0);
        ovf_q           <= is_signed_start && (dividend_in == 32'h8000_0000) &&
            (divisor_in == 32'hFFFF_FFFF);
        sign_quo_q <= is_signed_start && (dividend_in[XLEN-1] ^ divisor_in[XLEN-1]);
        sign_rem_q <= is_signed_start && dividend_in[XLEN-1];
        divd_q <= (is_signed_start && dividend_in[XLEN-1]) ? (~dividend_in + 1'b1) : dividend_in;
        div_q <= (is_signed_start && divisor_in[XLEN-1]) ? (~divisor_in + 1'b1) : divisor_in;
        rem_q   <= '0;
        op_q    <= op;
        cnt_q   <= '0;
        state_q <= ST_RUN;
      end
    end else begin  // ST_RUN
      rem_q  <= rem_nxt;
      divd_q <= divd_nxt;
      if (cnt_q == LastIter) state_q <= ST_IDLE;
      else cnt_q <= cnt_q + 1'b1;
    end
  end

  assign busy = (state_q == ST_RUN);
  assign done = (state_q == ST_RUN) && (cnt_q == LastIter);

  // Output mux: on the done cycle, the just-computed (combinational)
  // rem_nxt/divd_nxt reflect the 32nd iteration — the registers only catch
  // up one cycle later, so the result must be built from the combinational
  // values, not from rem_q/divd_q directly.
  xlen_t quotient_unsigned, remainder_unsigned;
  xlen_t quotient_signed, remainder_signed;
  xlen_t quotient_result, remainder_result;
  logic  is_signed_q;

  assign quotient_unsigned  = divd_nxt;
  assign remainder_unsigned = rem_nxt;
  assign quotient_signed    = sign_quo_q ? (~quotient_unsigned + 1'b1) : quotient_unsigned;
  assign remainder_signed   = sign_rem_q ? (~remainder_unsigned + 1'b1) : remainder_unsigned;
  assign is_signed_q        = (op_q == ALU_DIV) || (op_q == ALU_REM);

  always_comb begin
    if (divzero_q) begin
      quotient_result  = {XLEN{1'b1}};
      remainder_result = dividend_orig_q;
    end else if (ovf_q) begin
      quotient_result  = 32'h8000_0000;
      remainder_result = '0;
    end else begin
      quotient_result  = is_signed_q ? quotient_signed : quotient_unsigned;
      remainder_result = is_signed_q ? remainder_signed : remainder_unsigned;
    end
  end

  assign result = ((op_q == ALU_DIV) || (op_q == ALU_DIVU)) ? quotient_result : remainder_result;

endmodule
