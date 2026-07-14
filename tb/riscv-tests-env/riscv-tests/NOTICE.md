# Vendored from riscv-software-src/riscv-tests

Source: https://github.com/riscv-software-src/riscv-tests
Pinned commit: `34e6b6d1e7936b526075432fb730d89148623484`

Source (env submodule): https://github.com/riscv/riscv-test-env
Pinned commit: `6de71edb142be36319e380ce782c3d1830c65d68`

Both are BSD-3-Clause licensed (see `LICENSE` and `env/LICENSE`, copied in unmodified).

## What's vendored, and why

- `env/encoding.h`, `env/p/riscv_test.h` — vendored **unmodified**. This core now implements
  M-mode CSR/trap machinery (ECALL/EBREAK/illegal-instruction/misaligned-load-store traps,
  MRET, CSRRW/S/C/WI/SI/CI — see `rtl/core/csr/csr.sv`), so the real upstream test environment
  runs as-is; no CSR-free substitute environment is needed or used.
- `isa/macros/scalar/test_macros.h` — unmodified.
- `isa/rv32ui/*.S` (all of upstream's `rv32ui_sc_tests` except `ma_data`, see below) plus the
  underlying `isa/rv64ui/*.S` sources those thin wrappers `#include`.
- `isa/rv32um/*.S` — all 8 (self-contained, no wrapping).
- `isa/rv32ua/*.S` — all 10, plus the underlying `isa/rv64ua/*.S` sources they `#include`.
- `isa/rv32mi/*.S` — all 16 (vendored in full, even though 5 are excluded from the run manifest
  — see below), plus the underlying `isa/rv64mi/*.S` and `isa/rv64si/*.S` sources they `#include`.

Not vendored: `env/p/link.ld` (assumes RAM at `0x80000000`; this core resets to PC `0`, so
`tb/riscv-tests-env/link.ld` is a project-specific replacement — same shape, different address),
`env/v`/`env/pm`/`env/pt` (virtual-memory / multi-hart / physical-timer environments, not
applicable to this single-hart M-mode-only core), all non-integer/atomic/machine-mode ISA
subdirectories (`rv32uf`, `rv32ud`, `rv32uc`, `rv32si`, etc. — not implemented by this core).

## Excluded from the run manifest (`sim/verilator/run_riscv_tests.sh`)

One `rv32ui` test is excluded outright:

- **`ma_data`** — expects misaligned loads/stores to work *transparently* (return byte-correct
  results). This core traps on misaligned load/store by design (`rtl/core/lsu/lsu.sv`,
  causes 4/6), so this test's premise doesn't hold here.

Five `rv32mi` tests are excluded — each hand-verified by inspecting its source and running it
against the real core (70/75 candidate tests pass; these 5 are the only failures, each for a
confirmed, understood reason, not a mystery):

| Test | Reason |
|---|---|
| `breakpoint` | needs a real debug/trigger module (`tdata1-3`/`mcontrol`) — not implemented |
| `zicntr` | needs `cycle`/`instret` (Zicntr) counter CSRs — not implemented |
| `instret_overflow` | needs the `minstret` counter — not implemented |
| `ma_fetch` | needs a misaligned-instruction-**fetch** trap (cause 0) — this core only traps misaligned load/store (cause 4/6), not fetch |
| `pmpaddr` | needs real PMP enforcement — PMP CSRs aren't modeled at all |

The remaining 11 `rv32mi` tests (`csr`, `mcsr`, `illegal`, `ma_addr`, `scall`, `sbreak`, `shamt`,
`lw-misaligned`, `lh-misaligned`, `sh-misaligned`, `sw-misaligned`) pass unmodified.
