// =============================================================================
// tb/linux_boot/linux_boot_tb.sv
// =============================================================================
// Exploratory Linux-boot testbench: instantiates soc_top (unchanged from
// tb/soc/soc_tb.sv's own use of it) against two separate memory regions —
// a small boot ROM at address 0 (RESET_PC, unchanged) holding boot_stub.S,
// and a 64 MiB main RAM at the real 0x8000_0000 address holding remu's
// kernel Image plus our own compiled DTB. This routing is testbench-only;
// soc_top's RTL (data_bus/clint/uart) is completely unmodified — it already
// intercepts CLINT/UART addresses before they'd reach this level.
//
// Unlike every other testbench in this project, there is no tohost
// convention here (Linux doesn't know about it) — this just runs to a
// large +MAX_CYCLES and streams every byte the uart_rx_monitor decodes off
// the real uart_tx waveform straight to stdout as it arrives, so partial
// boot-log progress is visible even if the run hangs or times out.
//
// Usage: +MAX_CYCLES=20000000 (default; booting Linux is a lot of cycles)
// =============================================================================

`timescale 1ns / 1ps

module linux_boot_tb;

  import core_pkg::*;

  localparam int BootRomBytes = 4096;
  localparam xlen_t RamBase = 32'h8000_0000;
  localparam int RamBytes = 32'h0400_0000;  // 64 MiB
  localparam int MaxCyclesDefault = 20_000_000;

  logic clk = 1'b0;
  logic rst_n = 1'b0;

  always #5 clk = ~clk;

  logic [7:0] boot_rom[0:BootRomBytes-1];
  // 0-based, not [RamBase:RamBase+RamBytes-1] — Verilator's $readmemh
  // bounds-checking did not accept 0x8000_0000-magnitude array bounds in
  // practice; addresses are translated to RamBase-relative offsets below
  // instead (both at simulation-load time via objcopy --change-addresses,
  // and here in read_mem/the write process).
  logic [7:0] main_ram[0:RamBytes-1];

  xlen_t imem_addr, imem_rdata;
  xlen_t dmem_addr, dmem_wdata, dmem_rdata;
  logic [3:0] dmem_wstrb;
  logic dmem_re;
  logic uart_tx;

  soc_top dut (
      .clk       (clk),
      .rst_n     (rst_n),
      .imem_addr (imem_addr),
      .imem_rdata(imem_rdata),
      .dmem_addr (dmem_addr),
      .dmem_wdata(dmem_wdata),
      .dmem_wstrb(dmem_wstrb),
      .dmem_re   (dmem_re),
      .dmem_rdata(dmem_rdata),
      .uart_tx   (uart_tx),
      .uart_rx   (1'b1)  // idle/mark state; no RX injection in this exploratory harness yet
  );

  // ---------------------------------------------------------------------
  // Two-region memory model (boot ROM at 0, main RAM at RamBase). Purely a
  // testbench convenience for simulation — a real SoC would need actual
  // RTL address decode for a physical boot ROM, deferred to the FPGA
  // bring-up phase, same as the rest of the memory-map partitioning.
  // ---------------------------------------------------------------------
  function automatic xlen_t read_mem(xlen_t addr);
    xlen_t ram_off;
    if (addr < BootRomBytes) begin
      read_mem = {boot_rom[addr+3], boot_rom[addr+2], boot_rom[addr+1], boot_rom[addr+0]};
    end else if (addr >= RamBase && addr < RamBase + RamBytes) begin
      ram_off = addr - RamBase;
      read_mem = {main_ram[ram_off+3], main_ram[ram_off+2], main_ram[ram_off+1], main_ram[ram_off+0]};
    end else begin
      read_mem = 32'h0;
    end
  endfunction

  always_ff @(posedge clk) begin
    imem_rdata <= read_mem(imem_addr);
    dmem_rdata <= read_mem(dmem_addr);
  end

  always_ff @(posedge clk) begin
    if (rst_n && (|dmem_wstrb)) begin
      if (dmem_addr < BootRomBytes) begin
        if (dmem_wstrb[0]) boot_rom[dmem_addr+0] <= dmem_wdata[7:0];
        if (dmem_wstrb[1]) boot_rom[dmem_addr+1] <= dmem_wdata[15:8];
        if (dmem_wstrb[2]) boot_rom[dmem_addr+2] <= dmem_wdata[23:16];
        if (dmem_wstrb[3]) boot_rom[dmem_addr+3] <= dmem_wdata[31:24];
      end else if (dmem_addr >= RamBase && dmem_addr < RamBase + RamBytes) begin
        automatic xlen_t ram_off = dmem_addr - RamBase;
        if (dmem_wstrb[0]) main_ram[ram_off+0] <= dmem_wdata[7:0];
        if (dmem_wstrb[1]) main_ram[ram_off+1] <= dmem_wdata[15:8];
        if (dmem_wstrb[2]) main_ram[ram_off+2] <= dmem_wdata[23:16];
        if (dmem_wstrb[3]) main_ram[ram_off+3] <= dmem_wdata[31:24];
      end
    end
  end

  // ---------------------------------------------------------------------
  // UART waveform monitor, streaming decoded bytes to stdout live.
  // ---------------------------------------------------------------------
  localparam int UartMaxBytes = 1 << 20;
  logic [7:0] uart_bytes[UartMaxBytes];
  int unsigned uart_byte_count;

  uart_rx_monitor #(
      .BIT_PERIOD_CYCLES(16),
      .MAX_BYTES(UartMaxBytes)
  ) u_uart_monitor (
      .clk       (clk),
      .rst_n     (rst_n),
      .tx        (uart_tx),
      .bytes_q   (uart_bytes),
      .byte_count(uart_byte_count)
  );

  int unsigned prev_uart_byte_count;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      prev_uart_byte_count <= 0;
    end else if (uart_byte_count != prev_uart_byte_count) begin
      $write("%c", uart_bytes[prev_uart_byte_count]);
      $fflush;
      prev_uart_byte_count <= uart_byte_count;
    end
  end

  // ---------------------------------------------------------------------
  // Load + run.
  // ---------------------------------------------------------------------
  string boot_stub_hex, kernel_hex, dtb_hex;
  int max_cycles;
  int cyc;

  initial begin
    cyc = 0;

    for (int i = 0; i < BootRomBytes; i++) boot_rom[i] = 8'h00;
    for (int i = 0; i < RamBytes; i++) main_ram[i] = 8'h00;

    if (!$value$plusargs("BOOT_STUB=%s", boot_stub_hex)) begin
      $fatal(1, "linux_boot_tb: missing +BOOT_STUB=<path> plusarg");
    end
    if (!$value$plusargs("KERNEL=%s", kernel_hex)) begin
      $fatal(1, "linux_boot_tb: missing +KERNEL=<path> plusarg");
    end
    if (!$value$plusargs("DTB=%s", dtb_hex)) begin
      $fatal(1, "linux_boot_tb: missing +DTB=<path> plusarg");
    end

    $readmemh(boot_stub_hex, boot_rom);
    $readmemh(kernel_hex, main_ram);
    $readmemh(dtb_hex, main_ram);

    if (!$value$plusargs("MAX_CYCLES=%d", max_cycles)) begin
      max_cycles = MaxCyclesDefault;
    end

    $display("linux_boot_tb: boot_stub=%s kernel=%s dtb=%s max_cycles=%0d",
              boot_stub_hex, kernel_hex, dtb_hex, max_cycles);

    repeat (3) @(posedge clk);
    rst_n = 1'b1;

    while (cyc < max_cycles) begin
      @(posedge clk);
      cyc++;
      if (cyc % 200000 == 0) begin
        $display("linux_boot_tb: cyc=%0d imem_addr=%08h dmem_addr=%08h uart_bytes=%0d", cyc,
                  imem_addr, dmem_addr, uart_byte_count);
      end
    end

    $display("\nlinux_boot_tb: stopped after %0d cycles (%0d uart bytes decoded)", cyc,
              uart_byte_count);
    $finish;
  end

  initial begin
    if ($test$plusargs("VCD")) begin
      $dumpfile("linux_boot_tb.vcd");
      $dumpvars(0, linux_boot_tb);
    end
  end

endmodule
