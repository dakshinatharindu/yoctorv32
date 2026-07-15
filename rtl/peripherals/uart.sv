// =============================================================================
// rtl/peripherals/uart.sv
// =============================================================================
// Minimal 16550-register-compatible UART, with a real RX shift register
// (mirrors the TX shifter's timing) and dynamic IIR encoding, so both RX
// and TX can drive an external PLIC (rtl/peripherals/plic.sv) via the
// `irq` output. RX genuinely needs interrupts to be usable (polling for
// keystrokes would waste the whole CPU); TX still works fine in polling
// mode (rtl/soc/... 02_uart_tx.S), but once real IIR/PLIC routing exists
// for RX, adding THRE-empty as a second IER-gated source is a small
// marginal addition, not a second effort.
//
// Registers are WORD-spaced (what Linux's 8250 driver calls reg-shift=2:
// each register occupies its own 32-bit word, only the low byte
// meaningful) rather than the real 16550's byte-packed layout. This is
// necessary, not just convenient: this bus always returns a full word on a
// read (byte/half extraction happens CPU-side, one stage later, in
// load_align.sv) — byte-packing 4 different registers into one word would
// mean every read had to assemble all 4 simultaneously. reg-shift=2 is a
// common, fully driver-supported real-world convention (the DTB just needs
// to say so) and matches how clint.sv already spaces its own registers.
//
// IIR's FIFO-status bits stay fixed at "non-FIFO" regardless of FCR writes
// (no FIFO buffering is implemented — Linux's 8250 autoconfig() probe
// detects a plain 16450-class UART), but the interrupt-pending/ID bits are
// now real, standard 16550 priority encoding restricted to the two sources
// implemented: Received Data Available (IER bit 0) over Transmitter
// Holding Register Empty (IER bit 1). THRE-pending is deliberately
// level-based (`!tx_busy_q`, not edge-latched to the real spec's "cleared
// only by IIR-read-while-reported or THR write") — the in-tree 8250
// driver already disables IER's THRE-enable itself once it has nothing
// left to send (serial8250_stop_tx()), specifically to prevent the
// re-fire-immediately problem an edge latch would otherwise be needed
// for, so the driver's own state machine makes the simpler level-based
// version correct in practice.
//
// TX and RX are both real, cycle-accurate serial shifters — not behavioral
// shortcuts — sharing one baud rate derived from a divisor (DLL/DLM)
// against an assumed 1.8432 MHz reference clock (the classic real-16550
// reference frequency, chosen because it divides evenly into every
// standard baud rate; divisor=1 at 115200 baud). No FPGA target clock has
// been chosen yet, so this is a placeholder exactly like clint.sv's N=1
// mtime divider — revisit together once a real synthesis clock is picked.
// =============================================================================

`timescale 1ns / 1ps

module uart (
    input logic clk,
    input logic rst_n,

    input core_pkg::xlen_t addr,
    input core_pkg::xlen_t wdata,
    input logic      [3:0] wstrb,
    input logic             re,

    output core_pkg::xlen_t rdata,
    output logic             tx,
    input  logic             rx,

    // Combined interrupt line (RX-data-available OR THRE-empty, whichever
    // is enabled in IER), for an external PLIC — see plic.sv.
    output logic irq
);

  import core_pkg::*;

  localparam logic [4:0] OffThrRbrDll = 5'h00;
  localparam logic [4:0] OffIerDlm = 5'h04;
  localparam logic [4:0] OffIirFcr = 5'h08;
  localparam logic [4:0] OffLcr = 5'h0C;
  localparam logic [4:0] OffMcr = 5'h10;
  localparam logic [4:0] OffLsr = 5'h14;
  localparam logic [4:0] OffMsr = 5'h18;
  localparam logic [4:0] OffScr = 5'h1C;

  logic [4:0] off;
  assign off = addr[4:0];

  logic [7:0] ier_q, lcr_q, mcr_q, scr_q, dll_q, dlm_q;
  logic       dlab;
  assign dlab = lcr_q[7];

  logic write_en;
  assign write_en = |wstrb;

  logic write_thr_dll, write_ier_dlm, write_lcr, write_mcr, write_scr;
  assign write_thr_dll = write_en && (off == OffThrRbrDll);
  assign write_ier_dlm = write_en && (off == OffIerDlm);
  assign write_lcr     = write_en && (off == OffLcr);
  assign write_mcr     = write_en && (off == OffMcr);
  assign write_scr     = write_en && (off == OffScr);

  // ---------------------------------------------------------------------
  // TX shift register + baud generator.
  // ---------------------------------------------------------------------
  logic [15:0] divisor;
  assign divisor = {dlm_q, dll_q};

  logic [31:0] bit_period;  // clk cycles per bit = divisor * 16 (16x oversample)
  assign bit_period = {16'b0, divisor} << 4;

  logic [31:0] cyc_cnt_q;
  logic [ 3:0] bit_idx_q;  // 0..9 across the 10-bit frame (start, 8 data, stop)
  logic [ 9:0] tx_shift_q;
  logic        tx_busy_q;
  logic        tx_q;

  logic thr_write;
  assign thr_write = write_thr_dll && !dlab;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cyc_cnt_q  <= 32'd0;
      bit_idx_q  <= 4'd0;
      tx_shift_q <= 10'h3FF;
      tx_busy_q  <= 1'b0;
      tx_q       <= 1'b1;
    end else if (thr_write && !tx_busy_q) begin
      tx_shift_q <= {1'b1, wdata[7:0], 1'b0};  // stop, data[7:0], start
      tx_busy_q  <= 1'b1;
      cyc_cnt_q  <= 32'd0;
      bit_idx_q  <= 4'd0;
    end else if (tx_busy_q) begin
      if (cyc_cnt_q == bit_period - 32'd1) begin
        cyc_cnt_q  <= 32'd0;
        tx_q       <= tx_shift_q[0];
        tx_shift_q <= {1'b1, tx_shift_q[9:1]};
        if (bit_idx_q == 4'd9) begin
          tx_busy_q <= 1'b0;
          bit_idx_q <= 4'd0;
        end else begin
          bit_idx_q <= bit_idx_q + 4'd1;
        end
      end else begin
        cyc_cnt_q <= cyc_cnt_q + 32'd1;
      end
    end
  end

  assign tx = tx_q;

  // ---------------------------------------------------------------------
  // RX shift register. Mirrors tb/soc/uart_rx_monitor.sv's proven
  // sampling strategy (detect the start-bit falling edge, sample the
  // middle of each subsequent bit period, commit the assembled byte one
  // cycle after the last data-bit sample to avoid reading rx_shift_q
  // before its own last non-blocking write has landed) — same baud rate
  // as TX (one shared divisor/bit_period).
  // ---------------------------------------------------------------------
  typedef enum logic [1:0] {
    RX_IDLE,
    RX_SAMPLING,
    RX_COMMIT
  } rx_state_e;

  rx_state_e   rx_state_q;
  logic        rx_q;
  logic [31:0] rx_cyc_cnt_q;
  logic [ 3:0] rx_bit_idx_q;
  logic [ 7:0] rx_shift_q;
  logic [ 7:0] rbr_q;
  logic        lsr_dr_q;

  logic read_rbr;
  assign read_rbr = re && !dlab && (off == OffThrRbrDll);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rx_state_q   <= RX_IDLE;
      rx_q         <= 1'b1;
      rx_cyc_cnt_q <= 32'd0;
      rx_bit_idx_q <= 4'd0;
      rx_shift_q   <= 8'd0;
      rbr_q        <= 8'd0;
      lsr_dr_q     <= 1'b0;
    end else begin
      rx_q <= rx;
      unique case (rx_state_q)
        RX_IDLE: begin
          if (rx_q && !rx) begin  // falling edge: start bit begins now
            rx_state_q   <= RX_SAMPLING;
            rx_cyc_cnt_q <= 32'd0;
            rx_bit_idx_q <= 4'd0;
          end
        end

        RX_SAMPLING: begin
          rx_cyc_cnt_q <= rx_cyc_cnt_q + 32'd1;
          // Data bit rx_bit_idx_q sits bit_period*(rx_bit_idx_q+1) cycles
          // after the start-bit edge; sample at its midpoint.
          if (rx_cyc_cnt_q == bit_period * (32'(rx_bit_idx_q) + 32'd1) + (bit_period >> 1)) begin
            rx_shift_q[rx_bit_idx_q[2:0]] <= rx;
            if (rx_bit_idx_q == 4'd7) rx_state_q <= RX_COMMIT;
            else rx_bit_idx_q <= rx_bit_idx_q + 4'd1;
          end
        end

        RX_COMMIT: begin
          rbr_q      <= rx_shift_q;
          lsr_dr_q   <= 1'b1;
          rx_state_q <= RX_IDLE;
        end

        default: rx_state_q <= RX_IDLE;
      endcase

      // Reading RBR always wins over a same-cycle receive commit setting
      // DR again — an extremely narrow race in practice (a new byte
      // finishing in the exact cycle software reads the previous one).
      if (read_rbr) lsr_dr_q <= 1'b0;
    end
  end

  // ---------------------------------------------------------------------
  // Register storage. DLAB (lcr_q[7]) banks offset 0/1 between THR/IER and
  // the DLL/DLM baud divisor latches, per the real 16550 convention.
  // ---------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ier_q <= 8'd0;
      lcr_q <= 8'd0;
      mcr_q <= 8'd0;
      scr_q <= 8'd0;
      dll_q <= 8'd0;
      dlm_q <= 8'd0;
    end else begin
      if (write_ier_dlm) begin
        if (dlab) dlm_q <= wdata[7:0];
        else ier_q <= wdata[7:0];
      end
      if (write_thr_dll && dlab) dll_q <= wdata[7:0];
      if (write_lcr) lcr_q <= wdata[7:0];
      if (write_mcr) mcr_q <= wdata[7:0];
      if (write_scr) scr_q <= wdata[7:0];
    end
  end

  // ---------------------------------------------------------------------
  // Read path (registered, 1-cycle latency, matching every other memory in
  // this system).
  // ---------------------------------------------------------------------
  logic [7:0] lsr_val;
  // bit7=0(rsvd) bit6=TEMT bit5=THRE bit4=BI(0) bit3=FE(0) bit2=PE(0)
  // bit1=OE(0) bit0=DR
  assign lsr_val = {1'b0, !tx_busy_q, !tx_busy_q, 4'b0000, lsr_dr_q};

  // Dynamic IIR: standard 16550 priority, restricted to the two sources
  // implemented (RX Data Available > THRE Empty). bit0 is inverted
  // ("1" = no interrupt pending); bits[7:4] stay 0 (non-FIFO).
  logic rx_int_pending, tx_int_pending;
  assign rx_int_pending = ier_q[0] && lsr_dr_q;
  assign tx_int_pending = ier_q[1] && !tx_busy_q;
  assign irq = rx_int_pending || tx_int_pending;

  logic [2:0] iir_iid;
  assign iir_iid = rx_int_pending ? 3'b010 : (tx_int_pending ? 3'b001 : 3'b000);

  logic [7:0] iir_val;
  assign iir_val = {4'b0000, iir_iid, !(rx_int_pending || tx_int_pending)};

  xlen_t rdata_next;
  always_comb begin
    unique case (off)
      OffThrRbrDll: rdata_next = dlab ? xlen_t'(dll_q) : xlen_t'(rbr_q);
      OffIerDlm:    rdata_next = dlab ? xlen_t'(dlm_q) : xlen_t'(ier_q);
      OffIirFcr:    rdata_next = xlen_t'(iir_val);
      OffLcr:       rdata_next = xlen_t'(lcr_q);
      OffMcr:       rdata_next = xlen_t'(mcr_q);
      OffLsr:       rdata_next = xlen_t'(lsr_val);
      OffMsr:       rdata_next = xlen_t'(8'h00);
      OffScr:       rdata_next = xlen_t'(scr_q);
      default:      rdata_next = '0;
    endcase
  end

  always_ff @(posedge clk) begin
    if (re) rdata <= rdata_next;
  end

endmodule
