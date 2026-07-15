// =============================================================================
// rtl/peripherals/clint.sv
// =============================================================================
// Core-Local Interruptor: single-hart mtime/mtimecmp/msip, using the de
// facto standard SiFive register layout (msip @ 0x0000, mtimecmp @ 0x4000,
// mtime @ 0xBFF8) — required so the in-tree Linux CLINT driver
// (drivers/clocksource/timer-clint.c), which hardcodes these offsets, works
// against this peripheral unmodified.
//
// mtime is the core's only notion of "time": a free-running 64-bit counter
// incrementing by 1 every clock cycle (no divider yet — no FPGA target
// frequency has been chosen, and simulation doesn't need wall-clock
// accuracy). Once a real clock target is picked, a divide-by-N can be added
// here without touching anything upstream; the DTB's `timebase-frequency`
// just needs to keep matching whatever rate this produces.
//
// msip is present (readable/writable) purely for register-map completeness
// — a single-hart core has no other hart to send a software interrupt to,
// so it is deliberately NOT wired to any mip bit.
//
// rdata is synchronous (1-cycle latency), matching every other memory in
// this system (see tb/core/core_tb.sv, lsu.sv) — the WB-stage load path
// assumes uniform latency regardless of which device backs dmem_rdata.
// mtip is a plain combinational compare, not registered: it's an interrupt
// condition line, not bus read data, so no read latency applies to it.
// =============================================================================

`timescale 1ns / 1ps

module clint (
    input logic clk,
    input logic rst_n,

    // Local bus port — addr is the byte offset within CLINT's 64KB window
    // (interconnect has already stripped the base address).
    input core_pkg::xlen_t addr,
    input core_pkg::xlen_t wdata,
    input logic      [3:0] wstrb,
    input logic             re,

    output core_pkg::xlen_t rdata,
    output logic             mtip
);

  import core_pkg::*;

  localparam logic [15:0] OffMsip = 16'h0000;
  localparam logic [15:0] OffMtimecmpLo = 16'h4000;
  localparam logic [15:0] OffMtimecmpHi = 16'h4004;
  localparam logic [15:0] OffMtimeLo = 16'hBFF8;
  localparam logic [15:0] OffMtimeHi = 16'hBFFC;

  logic [15:0] off;
  assign off = addr[15:0];

  // ---------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------
  logic [63:0] mtime_q;
  logic [63:0] mtimecmp_q;
  logic [31:0] msip_q;

  function automatic logic [31:0] strobed_write(logic [31:0] old_val, logic [31:0] new_val,
                                                 logic [3:0] strb);
    strobed_write = {
      strb[3] ? new_val[31:24] : old_val[31:24],
      strb[2] ? new_val[23:16] : old_val[23:16],
      strb[1] ? new_val[15:8] : old_val[15:8],
      strb[0] ? new_val[7:0] : old_val[7:0]
    };
  endfunction

  logic write_msip, write_mtimecmp_lo, write_mtimecmp_hi, write_mtime_lo, write_mtime_hi;
  assign write_msip        = (|wstrb) && (off == OffMsip);
  assign write_mtimecmp_lo = (|wstrb) && (off == OffMtimecmpLo);
  assign write_mtimecmp_hi = (|wstrb) && (off == OffMtimecmpHi);
  assign write_mtime_lo    = (|wstrb) && (off == OffMtimeLo);
  assign write_mtime_hi    = (|wstrb) && (off == OffMtimeHi);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      mtime_q    <= 64'd0;
      mtimecmp_q <= 64'hFFFF_FFFF_FFFF_FFFF;  // never fire until software programs it
      msip_q     <= 32'd0;
    end else begin
      // Free-running increment, unless software is writing this half this
      // cycle (software write wins over the auto-increment for that half).
      mtime_q[31:0] <= write_mtime_lo ? strobed_write(mtime_q[31:0], wdata, wstrb)
                                       : mtime_q[31:0] + 32'd1;
      mtime_q[63:32] <= write_mtime_hi ? strobed_write(mtime_q[63:32], wdata, wstrb)
          : (mtime_q[31:0] == 32'hFFFF_FFFF ? mtime_q[63:32] + 32'd1 : mtime_q[63:32]);

      if (write_mtimecmp_lo) mtimecmp_q[31:0] <= strobed_write(mtimecmp_q[31:0], wdata, wstrb);
      if (write_mtimecmp_hi) mtimecmp_q[63:32] <= strobed_write(mtimecmp_q[63:32], wdata, wstrb);
      if (write_msip) msip_q <= strobed_write(msip_q, wdata, wstrb);
    end
  end

  assign mtip = mtime_q >= mtimecmp_q;

  // ---------------------------------------------------------------------
  // Read path (registered, 1-cycle latency).
  // ---------------------------------------------------------------------
  xlen_t rdata_next;
  always_comb begin
    unique case (off)
      OffMsip:        rdata_next = msip_q;
      OffMtimecmpLo:  rdata_next = mtimecmp_q[31:0];
      OffMtimecmpHi:  rdata_next = mtimecmp_q[63:32];
      OffMtimeLo:     rdata_next = mtime_q[31:0];
      OffMtimeHi:     rdata_next = mtime_q[63:32];
      default:        rdata_next = '0;
    endcase
  end

  always_ff @(posedge clk) begin
    if (re) rdata <= rdata_next;
  end

endmodule
