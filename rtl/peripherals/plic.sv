// =============================================================================
// rtl/peripherals/plic.sv
// =============================================================================
// Minimal single-source, single-context PLIC (Platform-Level Interrupt
// Controller): only source 1 (the UART's combined irq line) and one
// context (hart 0, M-mode) are actually backed. The standard SiFive-PLIC
// register layout is used (matches remu's DTB base 0x0C00_0000) at exactly
// the offsets the in-tree Linux PLIC driver touches for a 1-device PLIC —
// everything else in the PLIC's address window reads as 0.
//
//   priority[1]    @ 0x0004 (R/W)
//   pending  bit1  @ 0x1000 (R,  bit1 of word0; see gateway below)
//   enable   bit1  @ 0x2000 (R/W, context 0, bit1 of word0)
//   threshold      @ 0x20_0000 (R/W, context 0)
//   claim/complete @ 0x20_0004 (R=claim, W=complete, context 0)
//
// Gateway semantics (textbook minimal model, not a shortcut): claiming a
// level-triggered source suppresses re-claiming that same assertion until
// software completes it; if the underlying condition is still asserted
// after completion, it naturally re-arms on the next read. This matches
// how the UART's RX/TX conditions behave in practice — servicing them
// (reading RBR / writing THR) is exactly what drops the level.
// =============================================================================

`timescale 1ns / 1ps

module plic (
    input logic clk,
    input logic rst_n,

    input core_pkg::xlen_t addr,
    input core_pkg::xlen_t wdata,
    input logic      [3:0] wstrb,
    input logic             re,

    output core_pkg::xlen_t rdata,

    input  logic source1,  // UART's combined irq line
    output logic meip
);

  import core_pkg::*;

  // addr arrives as the CPU's full absolute address (data_bus passes it
  // straight through unchanged, same as clint.sv/uart.sv) — mask down to
  // the local offset within the PLIC's window before comparing. 24 bits
  // comfortably covers the largest offset used here (0x20_0004).
  logic [23:0] off;
  assign off = addr[23:0];

  localparam logic [23:0] OffPriority1 = 24'h00_0004;
  localparam logic [23:0] OffPending0 = 24'h00_1000;
  localparam logic [23:0] OffEnable0 = 24'h00_2000;
  localparam logic [23:0] OffThreshold = 24'h20_0000;
  localparam logic [23:0] OffClaimComplete = 24'h20_0004;

  logic write_en;
  assign write_en = |wstrb;

  xlen_t priority_1_q, threshold_q;
  logic  enable_1_q;
  logic  claimed_q;

  // Gateway: source1 is pending as long as it's asserted and not currently
  // claimed-but-not-yet-completed.
  logic pending_1;
  assign pending_1 = source1 && !claimed_q;

  logic claim_grant;
  assign claim_grant = pending_1 && enable_1_q && (priority_1_q > threshold_q);

  assign meip = claim_grant;

  logic write_priority1, write_enable0, write_threshold, write_claim_complete;
  assign write_priority1      = write_en && (off == OffPriority1);
  assign write_enable0        = write_en && (off == OffEnable0);
  assign write_threshold      = write_en && (off == OffThreshold);
  assign write_claim_complete = write_en && (off == OffClaimComplete);

  logic read_claim_complete;
  assign read_claim_complete = re && (off == OffClaimComplete);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      priority_1_q <= '0;
      threshold_q  <= '0;
      enable_1_q   <= 1'b0;
      claimed_q    <= 1'b0;
    end else begin
      if (write_priority1) priority_1_q <= wdata;
      if (write_enable0) enable_1_q <= wdata[1];
      if (write_threshold) threshold_q <= wdata;

      // Claim (read) and complete (write) both touch claimed_q; a
      // simultaneous claim+complete can't happen (one is re, one is
      // write_en), so no priority conflict between the two branches below.
      if (read_claim_complete && claim_grant) claimed_q <= 1'b1;
      if (write_claim_complete && wdata[3:0] == 4'd1) claimed_q <= 1'b0;
    end
  end

  xlen_t rdata_next;
  always_comb begin
    unique case (off)
      OffPriority1:      rdata_next = priority_1_q;
      OffPending0:       rdata_next = {30'b0, pending_1, 1'b0};
      OffEnable0:        rdata_next = {30'b0, enable_1_q, 1'b0};
      OffThreshold:      rdata_next = threshold_q;
      OffClaimComplete:  rdata_next = claim_grant ? 32'd1 : 32'd0;
      default:           rdata_next = '0;
    endcase
  end

  always_ff @(posedge clk) begin
    if (re) rdata <= rdata_next;
  end

endmodule
