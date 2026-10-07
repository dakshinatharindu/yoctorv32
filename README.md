# yoctorv32

A 5-stage in-order RV32IMA CPU core and small SoC written in SystemVerilog, capable of booting a no-MMU Linux kernel to an interactive shell, both in simulation and on a Xilinx ZC702 FPGA board. The core runs in machine mode with a user mode for processes, and the SoC wraps it with the CLINT, UART and PLIC peripherals Linux needs, laid out to match [remu](https://github.com/dakshinatharindu/remu) (included as a submodule) so the same kernel boots on both.

## Features

- **RV32IMA** — base integer (I), multiply/divide (M), and atomic (A) extensions
- **Classic 5-stage pipeline** — IF/ID/EX/MEM/WB with EX/MEM and MEM/WB forwarding, a one-cycle load-use stall, and branches resolved in EX
- **FPGA-style memories** — instruction and data ports assume synchronous-read (1-cycle latency) block RAM, absorbed into the pipeline without extra stalls for plain loads
- **Machine-mode CSRs** — `mstatus`, `misa`, `mie`, `mip`, `mtvec`, `mscratch`, `mepc`, `mcause`, `mtval`, ID registers, plus PMP CSRs as WARL storage
- **M/U privilege modes** — `mstatus.MPP` is real state, so user-mode `ecall` reports cause 8 and reaches Linux's syscall handler
- **Trap handling** — illegal instruction, `ecall`/`ebreak`, misaligned load/store, `mret`, and M-mode timer and external interrupts (external > timer)
- **CLINT** — `mtime`, `mtimecmp`, `msip` in the SiFive layout used by Linux's `timer-clint` driver
- **16550-compatible UART** — cycle-accurate TX/RX shifters, word-spaced registers (`reg-shift=2`), RX and THRE interrupts
- **PLIC** — single source (the UART) and single context (hart 0, M-mode)
- **Verified** — hand-written directed tests plus 70 tests from the official `riscv-tests` suite, runnable under both Verilator and Icarus Verilog
- **Linux boot** — boots a 6.12 no-MMU kernel to a BusyBox login prompt, with host keystrokes forwarded into the simulated UART
- **Runs on an FPGA** — the same RTL boots that kernel on a ZC702 board at 50 MHz, with the Zynq's DDR as main memory; a clock enable on every register lets the slower memory pace the core

---

## Getting started

### Prerequisites

The easiest path is the included dev container ([.devcontainer/](.devcontainer/)), which builds the simulation tools below from source. To set it up by hand you need:

- [Verilator](https://verilator.org) 5.x (with `--timing` support)
- [Icarus Verilog](https://github.com/steveicarus/iverilog) — only for the `sim/icarus/` scripts
- A RISC-V bare-metal GCC toolchain for `rv32ima`/`ilp32`, with `riscv32-unknown-elf-` on `PATH` (override with `RISCV_PREFIX`)
- `dtc` (device-tree-compiler) — only for the Linux boot
- GTKWave — optional, for viewing waveforms
- Vivado with `xsdb` — only for the FPGA flow; see [Running on the ZC702](#running-on-the-zc702)

### Cloning

remu is a submodule and provides the prebuilt kernel image used by the Linux boot, so clone recursively:

```bash
git clone --recursive https://github.com/dakshinatharindu/yoctorv32.git
# or, in an existing clone:
git submodule update --init
```

All scripts below are run from the project root.

---

## Running the tests

| Script | Testbench | What it runs |
|---|---|---|
| `sim/verilator/run_core_tests.sh` | `tb/core/core_tb.sv` (`core_top` only) | 12 directed programs in `tb/core/programs/` |
| `sim/verilator/run_soc_tests.sh` | `tb/soc/soc_tb.sv` (`soc_top`) | 4 directed programs in `tb/soc/programs/` exercising CLINT, UART and PLIC |
| `sim/verilator/run_riscv_tests.sh` | `tb/core/core_tb.sv` | 70 tests from `rv32ui`, `rv32um`, `rv32ua` and `rv32mi` |
| `sim/icarus/run_core_tests.sh` | `tb/core/core_tb.sv` | Same directed programs, under Icarus Verilog |
| `sim/icarus/run_riscv_tests.sh` | `tb/core/core_tb.sv` | Same riscv-tests, under Icarus Verilog |
| `sim/verilator/run_fpga_tests.sh` | `tb/fpga/fpga_soc_tb.sv` (`soc_top` behind the FPGA memory bridge) | The same 70 riscv-tests relinked to run from a modelled DDR, plus the FPGA boot and hello programs |

Each script builds the model, runs every program, and ends with `[PASS] all ... passed` or a list of failures. The directed-test scripts also take a subset:

```bash
sim/verilator/run_core_tests.sh tb/core/programs/07_div.S tb/core/programs/08_amo.S
```

Test programs report their result by storing to a `tohost` address (see [tb/core/common/test_macros.h](tb/core/common/test_macros.h)): `1` is a pass, `(code << 1) | 1` a failure with `code`. A cycle watchdog reports `TIMEOUT` if the program never gets there.

> The riscv-tests are vendored under `tb/riscv-tests-env/riscv-tests/` at a pinned commit. Six upstream tests are excluded because they need features this core doesn't implement (transparent misaligned access, debug triggers, `cycle`/`instret` counters, misaligned-fetch traps, PMP enforcement). [NOTICE.md](tb/riscv-tests-env/riscv-tests/NOTICE.md) lists each one and why.

### Directed tests

| Core (`tb/core/programs/`) | SoC (`tb/soc/programs/`) |
|---|---|
| `01_alu_imm` · `02_branches` · `03_loads_stores` · `04_hazards_fwd` · `05_jal_jalr` · `06_mul` · `07_div` · `08_amo` · `09_lrsc` · `10_csr_trap` · `11_wfi` · `12_pmp` | `01_timer_irq` · `02_uart_tx` · `03_uart_rx_irq` · `04_uart_tx_irq` |

To add one, drop a `.S` file into either directory; the runner scripts pick up every `*.S` automatically. `sim/verilator/build_prog.sh` assembles a single program to a hex file if you want to drive the testbench by hand.

### Clock-enable fuzzing

`core_top` and `soc_top` take a clock enable, `ce`, which lets a memory slower than one cycle hold the whole SoC (see [Components](#components)). The testbenches normally tie it high. `+CE_FUZZ=<n>` raises it on a random ~1/`n` of clock cycles instead, and every test must still pass:

```bash
SIM_ARGS=+CE_FUZZ=3 sim/verilator/run_core_tests.sh
SIM_ARGS=+CE_FUZZ=3 sim/verilator/run_soc_tests.sh
SIM_ARGS=+CE_FUZZ=3 sim/verilator/run_riscv_tests.sh
sim/verilator/run_linux_boot.sh +CE_FUZZ=3
```

`SIM_ARGS` passes any extra plusargs through to the simulator, so `SIM_ARGS="+CE_FUZZ=3 +verilator+seed+7"` selects a different random pattern. Cycle counts and limits are in enabled cycles.

---

## Booting Linux in simulation

```bash
sim/verilator/run_linux_boot.sh [+MAX_CYCLES=<n>]
```

The script compiles [tb/linux_boot/yoctorv32.dts](tb/linux_boot/yoctorv32.dts), converts remu's kernel (`remu/resources/kernel/Image`) and the DTB to Verilog hex, assembles the boot stub, builds the Verilator model, and runs it. The decoded UART output streams to stdout as it arrives, so partial progress is visible even if a run hangs.

| Plusarg | Description |
|---|---|
| `+MAX_CYCLES=<n>` | Stop after `n` clock cycles (default: `200000000`) |
| `+CE_FUZZ=<n>` | Enable the SoC on a random ~1/`n` of clock cycles (see [Clock-enable fuzzing](#clock-enable-fuzzing)); the run takes about `n` times longer |

The kernel reaches `buildroot login:` after roughly 145M cycles, which takes about 1–2 minutes of wall time for the Verilator model. Log in as `root` with no password.

### Interacting with the console

When run from a real terminal, [tb/linux_boot/host_stdin.c](tb/linux_boot/host_stdin.c) puts it into raw, non-blocking mode and the testbench polls it once per cycle, bit-banging each keystroke onto the UART's RX line:

- Typing, line editing, and Ctrl-C/Ctrl-D/Ctrl-Z all go to the guest shell rather than the host.
- Press **Ctrl-]** to quit the simulator.
- The host terminal is restored on exit.

If stdin isn't a terminal (piped, redirected or backgrounded), input is disabled and the run is non-interactive, which is handy for scripted boots:

```bash
sim/verilator/run_linux_boot.sh +MAX_CYCLES=160000000 < /dev/null > boot.log
```

> Progress lines (the cycle count every 5M cycles) go to `linux_boot_progress.log` in the current directory, not stdout, so they don't interleave with the console output.

### Kernel and device tree

The kernel is remu's Buildroot-built no-MMU Linux 6.12.9 with a BusyBox initramfs, restricted to RV32IMA and M-mode; see remu's [README](remu/README.md#kernel) for how to rebuild it. yoctorv32 uses its own device tree rather than remu's `mini.dtb`, because the hardware differs in a few ways Linux needs to know about:

- **UART** — `reg-shift=2`/`reg-io-width=4` for the word-spaced registers, and compatible `"ns16450", "ns16550a"` so the 8250 driver treats it as FIFO-less while earlycon still matches. It has no `interrupts` property, so Linux polls the console.
- **CLINT** — wired straight to the CPU's local interrupt controller (MTIP/MSIP).
- **`timebase-frequency` = 12 MHz** — `mtime` increments once per core cycle, so this only sets how many cycles Linux treats as one second (48,000 cycles per jiffy at HZ=250). Each timer tick costs about 3,700 cycles, so lower values spend most of the boot in the tick handler. The comment in the DTS records the measured cycles-to-login for each value tried.

The kernel expects `a0` = hart ID and `a1` = DTB address at entry. Real hardware resets with all registers zero, so [tb/linux_boot/boot_stub.S](tb/linux_boot/boot_stub.S) lives in a small boot ROM at the reset vector, sets `a0`/`a1`, and jumps to the kernel.

---

## Running on the ZC702

The SoC runs on the Xilinx ZC702 evaluation board (XC7Z020-CLG484-1) at 50 MHz, built from the same `rtl/` the simulations use. A 4 KiB boot RAM sits at address 0, and 64 MiB of the Zynq's DDR is the main memory at `0x80000000`.

The Zynq's ARM cores run no software. The design uses the processor side of the chip only for its DDR controller, reached from the FPGA fabric through an AXI port.

### Board setup

- **Boot mode** — JTAG: all five SW16 switches off. Set SW10 to `01` to use the on-board USB-JTAG port.
- **Console** — an external 3.3 V USB-UART adapter on Pmod header J63, at 9600 baud 8N1. The board's own USB-UART is wired to the processor side and cannot be reached from the fabric.

  | Adapter pin | Board pin |
  |---|---|
  | RXD | J63 pin 1 (FPGA transmit) |
  | TXD | J63 pin 3 (FPGA receive) |
  | GND | J62 pin 5 |

  J63 is numbered in a zigzag, so pins 1 and 3 are neighbours in the same row. The baud rate is low because these Pmod nets also drive LEDs through level shifters, which limits them to about 100 kHz.
- **Reset** — SW5, the left pushbutton.
- **LEDs** — DS15 blinks while the fabric clock runs, DS16 is on while the SoC is running, and DS17 comes on if a DDR access returns an error.

Open the console with, for example, `picocom -b 9600 /dev/serial/by-id/<your adapter>`.

### Tools

The FPGA flow needs Vivado and its `xsdb` debugger (tested with 2026.1) in addition to the simulation prerequisites. The dev container does not install them. Instead, [devcontainer.json](.devcontainer/devcontainer.json) mounts an existing host install from `~/apps/Xilinx`, and [.devcontainer/xilinx-tool](.devcontainer/xilinx-tool) puts `vivado` and `xsdb` on the path. To give those tools the JTAG cable, the serial port and a node-locked license, the container runs privileged with the host's `/dev` and network. Change the mount path if your install lives elsewhere.

### Building

```bash
fpga/zc702/sw/build.sh
vivado -mode batch -source fpga/zc702/scripts/build.tcl
```

The first script assembles the two bare-metal programs: the boot program and a hello program. The second builds the bitstream, with the boot program in its boot RAM. Outputs land in `fpga/zc702/build/`; check that `timing.rpt` shows no negative slack.

The boot program prints a banner, checks that an image has been loaded at `0x80000000`, and jumps to it.

### Running a program

Every start goes through [run.tcl](fpga/zc702/scripts/run.tcl), run with `xsdb`. It resets the Zynq, programs the fabric, initializes the DDR controller, copies the given images into DDR over JTAG, and releases the core. To run the hello program:

```bash
xsdb fpga/zc702/scripts/run.tcl fpga/zc702/build/hello.bin 0x80000000
```

The console shows the boot banner, then the hello banner, and then echoes what you type. With no image arguments, the boot program reports that nothing is loaded.

### Booting Linux on the board

```bash
fpga/zc702/scripts/boot_linux.sh
```

The script compiles the board device tree ([yoctorv32_zc702.dts](fpga/zc702/yoctorv32_zc702.dts)) and calls `run.tcl` with remu's kernel at `0x80000000` and the device tree at `0x81000000`. The console then shows:

```
yoctorv32 boot
image found, jumping to 80000000
[    0.000000] Linux version 6.12.9 ...
...
Welcome to Buildroot
buildroot login:
```

A simulation of this exact configuration reaches the login prompt after about 162M core cycles, which is about 75 seconds on the board. Log in as `root` with no password.

The board device tree differs from the simulation one only in the console settings: a 50 MHz UART clock and 9600 baud. A few things behave differently from a normal Linux system:

- **Linux's clock runs about five times slow.** `mtime` counts core cycles, and the core completes one cycle for roughly every 23 cycles of the 50 MHz clock, because each cycle waits for DDR.
- **Shell output is slow and fast typing can drop characters.** Linux polls the UART once per timer tick; see [Limitations](#limitations).
- **Booting again means running the script again.** A kernel that has run has modified its image in DDR, so the reset button alone is not enough.

### Resources and timing

| LUTs | Flip-flops | Block RAM | DSPs | Worst slack at 50 MHz |
|---|---|---|---|---|
| 3,921 | 3,567 | 1 | 13 | 1.25 ns |

The longest path runs from memory read data through load forwarding into the single-cycle multiplier.

---

## Project structure

```
yoctorv32/
├── rtl/
│   ├── core/
│   │   ├── core_pkg.sv     # Shared types, opcodes, trap causes, RESET_PC
│   │   ├── core_top.sv     # 5-stage pipeline top (CPU only)
│   │   ├── ifetch/         # PC + synchronous-read instruction fetch
│   │   ├── decode/         # Decoder, immediate generator
│   │   ├── regfile/        # 32 x 32-bit register file
│   │   ├── execute/        # ALU (incl. single-cycle multiply), branch unit, divider
│   │   ├── lsu/            # Load/store unit, load alignment, AMO ALU
│   │   ├── csr/            # CSR file, trap/interrupt/MRET logic, privilege mode
│   │   ├── hazard/         # Load-use stall and forwarding control
│   │   └── pipeline/       # IF/ID, ID/EX, EX/MEM, MEM/WB registers
│   ├── interconnect/       # data_bus: address decode for RAM, CLINT, UART, PLIC
│   ├── peripherals/        # clint.sv, uart.sv, plic.sv
│   └── top/                # soc_top: core + interconnect + peripherals
├── tb/
│   ├── core/               # core_tb + directed programs, linker script, test macros
│   ├── soc/                # soc_tb + directed programs, UART monitor/injector
│   ├── linux_boot/         # Linux boot testbench, boot stub, DTS, host-stdin DPI
│   ├── fpga/               # fpga_soc_tb + AXI/DDR model for the FPGA memory system
│   └── riscv-tests-env/    # Vendored riscv-tests + project linker script
├── sim/
│   ├── verilator/          # Build/run scripts and rtl.f (the RTL file list)
│   └── icarus/             # Icarus Verilog equivalents
├── fpga/
│   └── zc702/
│       ├── rtl/            # Board top, SoC wrapper, memory bridge, AXI master
│       ├── sw/             # Boot program, hello program and their build script
│       ├── scripts/        # Vivado build, JTAG load-and-run, Linux boot
│       ├── zc702.xdc       # Pin and timing constraints
│       └── yoctorv32_zc702.dts  # Board device tree
├── remu/                   # Submodule: C++ reference emulator + prebuilt kernel
└── .devcontainer/          # Dev container with Verilator, Icarus and the RISC-V toolchain
```

`sim/verilator/rtl.f` is the single list of RTL sources; every script reads it, for both simulators and for the FPGA builds.

---

## Architecture

### Pipeline

```
 IF ──> ID ──> EX ──> MEM ──> WB
 │      │      │      │       │
 PC     decode ALU    LSU     load align
 imem   regfile branch CSR/trap writeback
        imm    mul/div
```

- **Fetch** — `imem` returns data one cycle after the address, so `ifetch` tracks the PC that pairs with each arriving word. The two wrong-path words already in flight at a redirect are squashed through a `valid` bit.
- **Hazards** — EX/MEM has priority over MEM/WB forwarding. Loads and CSR reads produce their result in MEM, so a dependent instruction right behind one stalls for one cycle. A skid buffer in `core_top` holds the extra in-flight instruction that the synchronous `imem` leaves behind when a stall begins.
- **Branches and jumps** — resolved in EX, with a 3-cycle penalty when taken. There is no branch predictor.
- **Multiply** is single-cycle. **Divide/remainder** is a 33-cycle iterative restoring divider that stalls EX. Divide-by-zero and overflow follow the RV32M results with no trap.
- **Atomics** — `lr.w`/`sc.w` use a reservation register and take one cycle. `amo*.w` is a two-phase read-modify-write in MEM that stalls for one cycle.
- **Traps and interrupts** — all synchronous trap sources resolve in one place (`csr.sv`, in the MEM stage). Interrupts reuse the same trap-entry path and are only taken when a valid instruction retires, never in the middle of an AMO.

### Memory map

| Region | Base address | Size | Notes |
|---|---|---|---|
| Boot ROM | `0x00000000` | 4 KiB | Linux testbench and FPGA design; `RESET_PC` is `0x0` |
| PLIC | `0x0C000000` | 64 MiB | |
| UART | `0x10000000` | 256 B | Registers word-spaced |
| CLINT | `0x11000000` | 64 KiB | `mtimecmp` @ `+0x4000`, `mtime` @ `+0xBFF8` |
| RAM | `0x80000000` | 64 MiB | Kernel at the base, DTB at `+0x01000000` |

The peripheral bases match remu. The boot ROM and RAM sit outside `soc_top`: memory models in the testbenches, the DDR bridge on the FPGA. `soc_top` only decodes the three peripherals and passes everything else through to that external memory. Instruction fetch always goes straight to RAM, since code never runs from a peripheral.

### Components

**`core_top`** — the CPU, with external instruction and data memory ports and `mtip`/`meip` inputs. It has no knowledge of the memory map, so it can be tested alone against a flat memory (`core_tb`). Its `ce` input is a clock enable on every register: while it is low the core holds all state and keeps its memory outputs stable, so a memory that needs several cycles can pause the core and still look like the 1-cycle memory the pipeline assumes.

**`data_bus`** — decodes the data port's address to RAM, CLINT, UART or PLIC and gates the other targets' read/write strobes. All targets have 1-cycle read latency, so only the returning read-data mux needs a registered select.

**`clint`** — a 64-bit `mtime` that increments every enabled clock cycle (no divider), `mtimecmp`, and `msip`. `mtip` is a combinational `mtime >= mtimecmp`. `msip` is readable and writable but not wired to anything, since a single hart has no one to interrupt.

**`uart`** — 16550 register set with real TX and RX shift registers, a baud divisor (DLL/DLM), and IIR encoding for two sources: received data available and THR empty. It has no FIFO and presents as a 16450.

**`plic`** — one source (the UART's `irq`) and one context, at the offsets Linux's PLIC driver uses. Claiming a source masks it until software completes it.

**`soc_top`** — wires `core_top`, `data_bus` and the three peripherals together. This is the module the testbenches and the FPGA design instantiate. Its `ce` input reaches the core, the interconnect, the CLINT and the PLIC, so `mtime` counts enabled cycles. The UART applies it to register accesses only: its TX/RX shifters run on every clock, which keeps the baud rate in real time.

### FPGA memory system

These modules live in [fpga/zc702/rtl/](fpga/zc702/rtl/) and exist to give `soc_top` its 1-cycle memory out of DDR that takes many cycles to answer.

**`mem_bridge`** — for each core cycle it reads the instruction, performs the data read or write if there is one, and then raises `ce` for one clock. Read data changes only on that enabled edge, so the core still sees a memory with exactly one cycle of latency. It also holds the 4 KiB boot RAM, and skips the instruction read while the core is stalled on the same address.

**`hp_axi_master`** — a minimal AXI3 master for the Zynq's `S_AXI_HP0` port: one single-beat 32-bit read or write at a time. At 50 MHz a DDR read takes about 16 clocks and a write 13.

**`fpga_soc`** — `soc_top`, `mem_bridge` and `hp_axi_master` together, plus reset sequencing that lets an AXI access in flight finish before the SoC restarts. It contains no vendor primitives, so `tb/fpga/fpga_soc_tb.sv` simulates it against a model of the AXI port.

**`fpga_top`** — the board top level: clock generation, reset sources and pins, around `fpga_soc` and the Zynq processing system.

### Boot flow

1. Reset: the PC is `0x0`, all registers are zero, and the core is in M-mode.
2. `boot_stub.S` sets `a0 = 0` (hart ID) and `a1 = 0x81000000` (the DTB address), then jumps to `0x80000000`. On the FPGA, [boot.S](fpga/zc702/sw/boot.S) does the same after printing a banner and checking that an image is present.
3. The kernel parses the DTB, registers the CLINT as its clocksource and clockevent, and programs `mtimecmp` for each tick.
4. The 8250 driver takes over the UART from earlycon and polls it.
5. The kernel unpacks the initramfs and starts `/init`, which lowers to U-mode through `mret`. BusyBox reaches the login prompt, with every system call arriving as a cause-8 `ecall`.

---

## Limitations

- **One FPGA board.** Only the ZC702 is supported, at 50 MHz.
- **The core is slow on the FPGA.** Every core cycle waits for one or two DDR accesses, so the core runs at roughly 2 MHz. There is no cache, and instruction and data accesses are not overlapped.
- **No wall-clock time.** `mtime` counts core cycles rather than real time, so Linux's clock runs slow on the FPGA.
- **No MMU and no S-mode**, so only no-MMU Linux can run.
- **Misaligned loads and stores trap** (causes 4 and 6) rather than being handled in hardware. Misaligned fetch doesn't trap.
- **PMP CSRs are storage only**, with no enforcement.
- **No `cycle`/`time`/`instret` CSRs** (Zicntr). Linux reads time from the CLINT's MMIO registers instead.
- **`wfi` is a no-op** rather than stalling until an interrupt arrives.
- **The PLIC is not described in the DTS**, so Linux runs the UART console by polling, even though the RTL supports interrupt-driven RX and TX (covered by the SoC tests).
