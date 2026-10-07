// =============================================================================
// fpga/zc702/rtl/mem_bridge.sv
// =============================================================================
// Gives soc_top the memory it expects (synchronous read, exactly 1 cycle of
// latency on both ports) out of memories that take many clock cycles to
// answer, by pacing the SoC with its clock enable.
//
// For each cycle of the SoC ("core cycle") the bridge, in this order:
//   1. reads the instruction at imem_addr
//   2. reads the data word at dmem_addr, if dmem_re is set
//   3. performs the write at dmem_addr, if any dmem_wstrb bit is set
//   4. raises ce for one clock; on that same clock edge imem_rdata and
//      dmem_rdata change to the results of steps 1 and 2
// While ce is low the SoC holds all of its state, so its address/data outputs
// stay put for as long as the steps above take. Step 4 is what makes this a
// 1-cycle memory from the SoC's side: on the enabled edge it still samples
// the data for the addresses of its PREVIOUS cycle, and the data for the
// addresses it is presenting now only appears afterwards, exactly like a
// synchronous RAM that registers its output on that edge. Reads come before
// the write so that a read and a write of the same word in one core cycle
// see the old value, like the simulation memory models.
//
// After reset the bridge first reads the instruction at imem_addr (which sits
// at RESET_PC) straight onto imem_rdata, without an enable pulse: soc_top's
// first enabled cycle already consumes it.
//
// Step 1 is skipped when the fetch address is the one already fetched last
// time and nothing has written that word since: this is what happens for the
// whole length of a pipeline stall (a 33-cycle divide, for example).
//
// Memory map, matching tb/linux_boot/linux_boot_tb.sv:
//   0x0000_0000 + BOOT_BYTES   boot RAM: block RAM in this module, loaded
//                              from BOOT_INIT_FILE (32-bit words, $readmemh)
//   RAM_BASE + RAM_BYTES       main RAM: through the request port to
//                              hp_axi_master, at DDR_BASE in PS DDR
//   anything else              reads as zero, writes are dropped
// soc_top has already kept CLINT/UART/PLIC accesses away from this level.
//
// Reset: use the same reset as soc_top. The AXI master is deliberately NOT
// on that reset; it finishes a transaction in flight by itself, and the
// reset must be held until its busy output has gone low (see fpga_soc.sv).
// =============================================================================

`timescale 1ns / 1ps

module mem_bridge #(
    parameter int unsigned BOOT_BYTES     = 4096,  // power of two
    parameter              BOOT_INIT_FILE = "",
    parameter logic [31:0] RAM_BASE       = 32'h8000_0000,
    parameter logic [31:0] RAM_BYTES      = 32'h0400_0000,
    parameter logic [31:0] DDR_BASE       = 32'h1000_0000
) (
    input logic clk,
    input logic rst_n,

    // soc_top memory ports
    input  logic [31:0] imem_addr,
    output logic [31:0] imem_rdata,
    input  logic [31:0] dmem_addr,
    input  logic [31:0] dmem_wdata,
    input  logic [ 3:0] dmem_wstrb,
    input  logic        dmem_re,
    output logic [31:0] dmem_rdata,
    output logic        ce,

    // hp_axi_master request port
    output logic        req_valid,
    output logic        req_write,
    output logic [31:0] req_addr,
    output logic [31:0] req_wdata,
    output logic [ 3:0] req_wstrb,
    input  logic        req_done,
    input  logic [31:0] req_rdata,
    input  logic        req_error,

    output logic bus_error  // sticky: an AXI access returned an error
);

  // ---------------------------------------------------------------------
  // Address decode.
  // ---------------------------------------------------------------------
  typedef enum logic [1:0] {
    RGN_NONE,
    RGN_BOOT,
    RGN_RAM
  } region_e;

  function automatic region_e region_of(input logic [31:0] addr);
    if (addr < BOOT_BYTES) return RGN_BOOT;
    if (addr >= RAM_BASE && (addr - RAM_BASE) < RAM_BYTES) return RGN_RAM;
    return RGN_NONE;
  endfunction

  function automatic logic [31:0] ddr_addr_of(input logic [31:0] addr);
    return DDR_BASE + (addr - RAM_BASE);
  endfunction

  region_e irgn, drgn;
  assign irgn = region_of(imem_addr);
  assign drgn = region_of(dmem_addr);

  // ---------------------------------------------------------------------
  // Boot RAM: one port, shared by the fetch and data steps.
  // ---------------------------------------------------------------------
  localparam int BootIdxBits = $clog2(BOOT_BYTES / 4);

  (* ram_style = "block" *)
  logic [           31:0] boot_mem     [BOOT_BYTES / 4];
  logic [BootIdxBits-1:0] boot_idx;
  logic [            3:0] boot_we;
  logic [           31:0] boot_rdata;

  initial begin
    if (BOOT_INIT_FILE != "") $readmemh(BOOT_INIT_FILE, boot_mem);
  end

  always_ff @(posedge clk) begin
    for (int i = 0; i < 4; i++) begin
      if (boot_we[i]) boot_mem[boot_idx][8*i+:8] <= dmem_wdata[8*i+:8];
    end
    boot_rdata <= boot_mem[boot_idx];
  end

  // ---------------------------------------------------------------------
  // Sequencer.
  // ---------------------------------------------------------------------
  typedef enum logic [3:0] {
    ST_FETCH,       // start step 1
    ST_FETCH_BOOT,  // boot RAM data arrives
    ST_FETCH_AXI,   // waiting for the AXI read
    ST_PRIME,       // after reset only: show the first instruction
    ST_DREAD,       // start step 2
    ST_DREAD_BOOT,
    ST_DREAD_AXI,
    ST_DWRITE,      // start step 3
    ST_DWRITE_AXI,
    ST_STEP         // step 4: ce high, read data moves to the outputs
  } state_e;

  state_e        state_q;
  logic          prime_q;  // first fetch after reset is still to be shown
  logic   [31:0] imem_next_q, dmem_next_q;  // results of steps 1 and 2
  logic   [31:0] imem_rdata_q, dmem_rdata_q;  // what the SoC sees

  // Fetch reuse: imem_next_q already holds the word at fetched_addr_q.
  logic          fetched_valid_q;
  logic   [29:0] fetched_addr_q;
  logic          fetch_hit;
  assign fetch_hit = fetched_valid_q && (fetched_addr_q == imem_addr[31:2]);

  logic write_pending;
  assign write_pending = |dmem_wstrb;

  // The boot RAM is addressed by the fetch in the fetch states and by the
  // data port otherwise; it is written in ST_DWRITE only.
  assign boot_idx = (state_q == ST_FETCH) ? imem_addr[BootIdxBits+1:2] : dmem_addr[BootIdxBits+1:2];
  assign boot_we = (state_q == ST_DWRITE && drgn == RGN_BOOT) ? dmem_wstrb : 4'b0000;

  assign ce         = (state_q == ST_STEP);
  assign imem_rdata = imem_rdata_q;
  assign dmem_rdata = dmem_rdata_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q         <= ST_FETCH;
      prime_q         <= 1'b1;
      imem_next_q     <= '0;
      dmem_next_q     <= '0;
      imem_rdata_q    <= '0;
      dmem_rdata_q    <= '0;
      fetched_valid_q <= 1'b0;
      fetched_addr_q  <= '0;
      req_valid       <= 1'b0;
      req_write       <= 1'b0;
      req_addr        <= '0;
      req_wdata       <= '0;
      req_wstrb       <= 4'b0000;
      bus_error       <= 1'b0;
    end else begin
      unique case (state_q)
        // ---------------- step 1: instruction ----------------
        ST_FETCH: begin
          if (fetch_hit) begin
            state_q <= ST_DREAD;
          end else begin
            fetched_addr_q  <= imem_addr[31:2];
            fetched_valid_q <= 1'b1;
            unique case (irgn)
              RGN_BOOT: state_q <= ST_FETCH_BOOT;
              RGN_RAM: begin
                req_valid <= 1'b1;
                req_write <= 1'b0;
                req_addr  <= ddr_addr_of(imem_addr);
                state_q   <= ST_FETCH_AXI;
              end
              default: begin
                imem_next_q <= '0;
                state_q     <= prime_q ? ST_PRIME : ST_DREAD;
              end
            endcase
          end
        end

        ST_FETCH_BOOT: begin
          imem_next_q <= boot_rdata;
          state_q     <= prime_q ? ST_PRIME : ST_DREAD;
        end

        ST_FETCH_AXI: begin
          if (req_done) begin
            req_valid   <= 1'b0;
            imem_next_q <= req_rdata;
            if (req_error) bus_error <= 1'b1;
            state_q <= prime_q ? ST_PRIME : ST_DREAD;
          end
        end

        // The SoC has not been enabled yet and imem_addr is unchanged, so the
        // fetch that follows is a reuse hit.
        ST_PRIME: begin
          imem_rdata_q <= imem_next_q;
          prime_q      <= 1'b0;
          state_q      <= ST_FETCH;
        end

        // ---------------- step 2: data read ----------------
        ST_DREAD: begin
          if (!dmem_re) begin
            state_q <= ST_DWRITE;
          end else begin
            unique case (drgn)
              RGN_BOOT: state_q <= ST_DREAD_BOOT;
              RGN_RAM: begin
                req_valid <= 1'b1;
                req_write <= 1'b0;
                req_addr  <= ddr_addr_of(dmem_addr);
                state_q   <= ST_DREAD_AXI;
              end
              default: begin
                dmem_next_q <= '0;
                state_q     <= ST_DWRITE;
              end
            endcase
          end
        end

        ST_DREAD_BOOT: begin
          dmem_next_q <= boot_rdata;
          state_q     <= ST_DWRITE;
        end

        ST_DREAD_AXI: begin
          if (req_done) begin
            req_valid   <= 1'b0;
            dmem_next_q <= req_rdata;
            if (req_error) bus_error <= 1'b1;
            state_q <= ST_DWRITE;
          end
        end

        // ---------------- step 3: data write ----------------
        ST_DWRITE: begin
          if (!write_pending) begin
            state_q <= ST_STEP;
          end else begin
            // The word under the fetch-reuse entry is about to change.
            if (dmem_addr[31:2] == fetched_addr_q) fetched_valid_q <= 1'b0;
            if (drgn == RGN_RAM) begin
              req_valid <= 1'b1;
              req_write <= 1'b1;
              req_addr  <= ddr_addr_of(dmem_addr);
              req_wdata <= dmem_wdata;
              req_wstrb <= dmem_wstrb;
              state_q   <= ST_DWRITE_AXI;
            end else begin
              // Boot RAM is written on this clock edge (boot_we); anything
              // else is dropped.
              state_q <= ST_STEP;
            end
          end
        end

        ST_DWRITE_AXI: begin
          if (req_done) begin
            req_valid <= 1'b0;
            if (req_error) bus_error <= 1'b1;
            state_q <= ST_STEP;
          end
        end

        // ---------------- step 4: advance the SoC ----------------
        ST_STEP: begin
          imem_rdata_q <= imem_next_q;
          dmem_rdata_q <= dmem_next_q;
          state_q      <= ST_FETCH;
        end

        default: state_q <= ST_FETCH;
      endcase
    end
  end

endmodule
