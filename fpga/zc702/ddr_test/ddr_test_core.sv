// =============================================================================
// fpga/zc702/ddr_test/ddr_test_core.sv
// =============================================================================
// Milestone 2, step 2: memory test of the PS DDR as seen from the PL, with no
// CPU involved. Drives hp_axi_master's request port and reports over a UART
// transmitter of its own (9600 8N1). Kept free of Xilinx primitives so the
// same logic runs in simulation against tb/fpga/axi_ram_model.sv.
//
// It repeats the following forever, one report line per pass:
//   1. Mailbox exchange with the JTAG debugger (xsdb), at MBOX_BASE:
//        +0x0  read   value written by xsdb
//        +0x4  write  its bitwise inverse      (proves xsdb -> DDR -> PL)
//        +0x8  write  the pass number          (proves PL -> DDR -> xsdb)
//        +0xC  write  status of the last finished pass:
//                     0x600Dnnnn = passed, 0xBAD0nnnn = failed (nnnn = pass)
//   2. Fill TEST_WORDS words from TEST_BASE with an address- and
//      pass-dependent pattern, then read them all back and compare.
//   3. Byte-strobe check on the first word: four single-byte writes must
//      build 0x44332211.
//
// Report line (all fields hexadecimal):
//   #PPPP err=EEEEEEEE at=AAAAAAAA got=GGGGGGGG strb=OK rd=mm-MM wr=mm-MM mbox=XXXXXXXX
//     PPPP      pass number
//     err       number of mismatching words (0 = pass); bus errors count too
//     at/got    address and read value of the first mismatch (0 if none)
//     strb      byte-strobe check, OK or NG
//     rd, wr    min-max latency of the reads / writes in step 2, in clock
//               cycles from the request being presented to req_done
//     mbox      mailbox value read in step 1
// =============================================================================

`timescale 1ns / 1ps

module ddr_test_core #(
    parameter int unsigned CLK_HZ     = 50_000_000,
    parameter int unsigned BAUD       = 9600,
    parameter logic [31:0] TEST_BASE  = 32'h1000_0000,
    parameter int unsigned TEST_WORDS = 32'h0100_0000,  // 64 MiB
    parameter logic [31:0] MBOX_BASE  = 32'h1400_0000
) (
    input logic clk,
    input logic rst_n,

    // To hp_axi_master
    output logic        req_valid,
    output logic        req_write,
    output logic [31:0] req_addr,
    output logic [31:0] req_wdata,
    output logic [ 3:0] req_wstrb,
    input  logic        req_done,
    input  logic [31:0] req_rdata,
    input  logic        req_error,

    output logic uart_tx,
    output logic fail_sticky  // set by the first failed pass, cleared by reset
);

  // ---------------------------------------------------------------------
  // Text helpers.
  // ---------------------------------------------------------------------
  function automatic logic [7:0] hex1(input logic [3:0] n);
    return (n < 4'd10) ? (8'h30 + 8'(n)) : (8'h37 + 8'(n));
  endfunction

  function automatic logic [15:0] hex2(input logic [7:0] v);
    return {hex1(v[7:4]), hex1(v[3:0])};
  endfunction

  function automatic logic [31:0] hex4(input logic [15:0] v);
    return {hex2(v[15:8]), hex2(v[7:0])};
  endfunction

  function automatic logic [63:0] hex8(input logic [31:0] v);
    return {hex4(v[31:16]), hex4(v[15:0])};
  endfunction

  localparam int BannerLen = 22;
  localparam int LineLen = 85;
  localparam logic [8*BannerLen-1:0] Banner = {8'h0D, 8'h0A, "yoctorv32 DDR test", 8'h0D, 8'h0A};

  // ---------------------------------------------------------------------
  // UART transmitter: sends tx_len_q characters from the top of tx_buf_q.
  // ---------------------------------------------------------------------
  localparam int unsigned BitCycles = CLK_HZ / BAUD;

  logic [8*LineLen-1:0] tx_buf_q;
  logic [          7:0] tx_len_q;
  logic                 tx_load;
  logic [8*LineLen-1:0] tx_load_buf;
  logic [          7:0] tx_load_len;

  logic [         31:0] baud_cnt_q;
  logic [          3:0] bit_idx_q;
  logic [          9:0] frame_q;  // {stop, data[7:0], start}, sent LSB first
  logic                 sending_q;
  logic                 tx_q;
  logic                 tx_idle;

  assign tx_idle = (tx_len_q == 8'd0) && !sending_q;
  assign uart_tx = tx_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tx_buf_q   <= '0;
      tx_len_q   <= 8'd0;
      baud_cnt_q <= '0;
      bit_idx_q  <= 4'd0;
      frame_q    <= '1;
      sending_q  <= 1'b0;
      tx_q       <= 1'b1;
    end else if (tx_load) begin
      tx_buf_q <= tx_load_buf;
      tx_len_q <= tx_load_len;
    end else if (!sending_q) begin
      tx_q <= 1'b1;
      if (tx_len_q != 8'd0) begin
        frame_q    <= {1'b1, tx_buf_q[8*LineLen-1-:8], 1'b0};
        tx_buf_q   <= {tx_buf_q[8*LineLen-9:0], 8'h00};
        tx_len_q   <= tx_len_q - 8'd1;
        sending_q  <= 1'b1;
        baud_cnt_q <= '0;
        bit_idx_q  <= 4'd0;
      end
    end else begin
      tx_q <= frame_q[0];
      if (baud_cnt_q == BitCycles - 1) begin
        baud_cnt_q <= '0;
        frame_q    <= {1'b1, frame_q[9:1]};
        if (bit_idx_q == 4'd9) sending_q <= 1'b0;
        else bit_idx_q <= bit_idx_q + 4'd1;
      end else begin
        baud_cnt_q <= baud_cnt_q + 32'd1;
      end
    end
  end

  // ---------------------------------------------------------------------
  // Test sequencer.
  // ---------------------------------------------------------------------
  typedef enum logic [3:0] {
    ST_BANNER,
    ST_MBOX_RD,
    ST_ECHO_WR,
    ST_PASS_WR,
    ST_FILL,
    ST_CHECK,
    ST_STRB,
    ST_STATUS_WR,
    ST_REPORT
  } state_e;

  localparam int IdxBits = $clog2(TEST_WORDS);
  localparam logic [IdxBits-1:0] LastIdx = IdxBits'(TEST_WORDS - 1);

  state_e               state_q;
  logic                 text_sent_q;  // banner/report line handed to the UART
  logic   [       15:0] pass_q;
  logic   [IdxBits-1:0] idx_q;
  logic   [        2:0] strb_step_q;
  logic   [       31:0] mbox_q;
  logic   [       31:0] err_cnt_q;
  logic   [       31:0] err_addr_q;
  logic   [       31:0] err_got_q;
  logic                 strb_ok_q;
  logic [7:0] lat_q, rd_min_q, rd_max_q, wr_min_q, wr_max_q;

  logic [31:0] word_addr;
  logic [31:0] pattern;
  assign word_addr = TEST_BASE + {{(30 - IdxBits) {1'b0}}, idx_q, 2'b00};
  assign pattern   = word_addr ^ {pass_q, ~pass_q};

  logic pass_ok;
  assign pass_ok = (err_cnt_q == 32'd0) && strb_ok_q;

  // The request each bus state issues.
  logic        nx_write;
  logic [31:0] nx_addr;
  logic [31:0] nx_wdata;
  logic [ 3:0] nx_wstrb;

  always_comb begin
    nx_write = 1'b0;
    nx_addr  = MBOX_BASE;
    nx_wdata = '0;
    nx_wstrb = 4'b1111;

    unique case (state_q)
      ST_MBOX_RD: begin
        nx_addr = MBOX_BASE + 32'h0;
      end
      ST_ECHO_WR: begin
        nx_write = 1'b1;
        nx_addr  = MBOX_BASE + 32'h4;
        nx_wdata = ~mbox_q;
      end
      ST_PASS_WR: begin
        nx_write = 1'b1;
        nx_addr  = MBOX_BASE + 32'h8;
        nx_wdata = {16'h0, pass_q};
      end
      ST_FILL: begin
        nx_write = 1'b1;
        nx_addr  = word_addr;
        nx_wdata = pattern;
      end
      ST_CHECK: begin
        nx_addr = word_addr;
      end
      ST_STRB: begin
        // Step 0 sets the word to all ones, steps 1-4 each overwrite one
        // byte (0x11, 0x22, 0x33, 0x44 into bytes 0..3), step 5 reads back.
        nx_addr = TEST_BASE;
        if (strb_step_q == 3'd0) begin
          nx_write = 1'b1;
          nx_wdata = 32'hFFFF_FFFF;
        end else if (strb_step_q <= 3'd4) begin
          nx_write = 1'b1;
          nx_wdata = {4{8'h11 * {5'b0, strb_step_q}}};
          nx_wstrb = 4'b0001 << (strb_step_q - 3'd1);
        end
      end
      ST_STATUS_WR: begin
        nx_write = 1'b1;
        nx_addr  = MBOX_BASE + 32'hC;
        nx_wdata = {pass_ok ? 16'h600D : 16'hBAD0, pass_q};
      end
      default: ;
    endcase
  end

  logic bus_state;
  assign bus_state = (state_q != ST_BANNER) && (state_q != ST_REPORT);

  always_comb begin
    tx_load     = 1'b0;
    tx_load_buf = '0;
    tx_load_len = 8'd0;
    if (!text_sent_q && tx_idle) begin
      if (state_q == ST_BANNER) begin
        tx_load     = 1'b1;
        tx_load_buf = {Banner, {(8 * (LineLen - BannerLen)) {1'b0}}};
        tx_load_len = 8'(BannerLen);
      end else if (state_q == ST_REPORT) begin
        tx_load = 1'b1;
        tx_load_buf = {
          "#", hex4(pass_q),
          " err=", hex8(err_cnt_q),
          " at=", hex8(err_addr_q),
          " got=", hex8(err_got_q),
          " strb=", strb_ok_q ? "OK" : "NG",
          " rd=", hex2(rd_min_q), "-", hex2(rd_max_q),
          " wr=", hex2(wr_min_q), "-", hex2(wr_max_q),
          " mbox=", hex8(mbox_q),
          8'h0D, 8'h0A
        };
        tx_load_len = 8'(LineLen);
      end
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q     <= ST_BANNER;
      text_sent_q <= 1'b0;
      pass_q      <= 16'd0;
      idx_q       <= '0;
      strb_step_q <= 3'd0;
      mbox_q      <= '0;
      err_cnt_q   <= '0;
      err_addr_q  <= '0;
      err_got_q   <= '0;
      strb_ok_q   <= 1'b0;
      lat_q       <= 8'd0;
      rd_min_q    <= 8'hFF;
      rd_max_q    <= 8'h00;
      wr_min_q    <= 8'hFF;
      wr_max_q    <= 8'h00;
      req_valid   <= 1'b0;
      req_write   <= 1'b0;
      req_addr    <= '0;
      req_wdata   <= '0;
      req_wstrb   <= 4'b0000;
      fail_sticky <= 1'b0;
    end else if (!bus_state) begin
      // Text states: hand the text to the UART, then wait for it to drain.
      if (!text_sent_q) begin
        if (tx_load) text_sent_q <= 1'b1;
      end else if (tx_idle) begin
        text_sent_q <= 1'b0;
        state_q     <= ST_MBOX_RD;
        if (state_q == ST_REPORT) begin
          if (!pass_ok) fail_sticky <= 1'b1;
          pass_q     <= pass_q + 16'd1;
          err_cnt_q  <= '0;
          err_addr_q <= '0;
          err_got_q  <= '0;
          rd_min_q   <= 8'hFF;
          rd_max_q   <= 8'h00;
          wr_min_q   <= 8'hFF;
          wr_max_q   <= 8'h00;
        end
      end
    end else if (!req_valid) begin
      // Issue this state's request.
      req_valid <= 1'b1;
      req_write <= nx_write;
      req_addr  <= nx_addr;
      req_wdata <= nx_wdata;
      req_wstrb <= nx_wstrb;
      lat_q     <= 8'd1;
    end else if (!req_done) begin
      if (lat_q != 8'hFF) lat_q <= lat_q + 8'd1;
    end else begin
      // Request finished: take the result and move on.
      req_valid <= 1'b0;

      if (req_error) begin
        if (err_cnt_q == 32'd0) begin
          err_addr_q <= req_addr;
          err_got_q  <= 32'hDEAD_AC5E;  // marks a bus error rather than bad data
        end
        if (err_cnt_q != 32'hFFFF_FFFF) err_cnt_q <= err_cnt_q + 32'd1;
      end

      unique case (state_q)
        ST_MBOX_RD: begin
          mbox_q  <= req_rdata;
          state_q <= ST_ECHO_WR;
        end

        ST_ECHO_WR: state_q <= ST_PASS_WR;

        ST_PASS_WR: begin
          idx_q   <= '0;
          state_q <= ST_FILL;
        end

        ST_FILL: begin
          if (lat_q < wr_min_q) wr_min_q <= lat_q;
          if (lat_q > wr_max_q) wr_max_q <= lat_q;
          if (idx_q == LastIdx) begin
            idx_q   <= '0;
            state_q <= ST_CHECK;
          end else begin
            idx_q <= idx_q + 1'b1;
          end
        end

        ST_CHECK: begin
          if (lat_q < rd_min_q) rd_min_q <= lat_q;
          if (lat_q > rd_max_q) rd_max_q <= lat_q;
          if (!req_error && (req_rdata != pattern)) begin
            if (err_cnt_q == 32'd0) begin
              err_addr_q <= req_addr;
              err_got_q  <= req_rdata;
            end
            if (err_cnt_q != 32'hFFFF_FFFF) err_cnt_q <= err_cnt_q + 32'd1;
          end
          if (idx_q == LastIdx) begin
            idx_q       <= '0;
            strb_step_q <= 3'd0;
            state_q     <= ST_STRB;
          end else begin
            idx_q <= idx_q + 1'b1;
          end
        end

        ST_STRB: begin
          if (strb_step_q == 3'd5) begin
            strb_ok_q <= (req_rdata == 32'h4433_2211);
            state_q   <= ST_STATUS_WR;
          end else begin
            strb_step_q <= strb_step_q + 3'd1;
          end
        end

        ST_STATUS_WR: state_q <= ST_REPORT;

        default: state_q <= ST_MBOX_RD;
      endcase
    end
  end

endmodule
