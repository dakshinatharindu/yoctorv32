// =============================================================================
// tb/core/programs/04_hazards_fwd.S
// =============================================================================
// Directed test: EX/MEM and MEM/WB forwarding (forward_unit.sv) and the
// load-use stall (hazard_unit.sv). These are the highest-risk untested
// paths in the pipeline, since directed unit tests on individual blocks
// can't exercise cross-stage timing.
// =============================================================================

#include "test_macros.h"

.section .text.start
.global _start
_start:
    li   sp, 0x7ff0

    // EX/MEM forwarding: result consumed by the very next instruction.
    li   x10, 4
    li   x11, 6
    add  x12, x10, x11     // x12 = 10, produced in EX this cycle
    add  x13, x12, x0      // consumes x12 one cycle later -> needs EX/MEM fwd
    ASSERT_EQ x13, 10, 1

    // MEM/WB forwarding: result consumed two instructions later.
    li   x10, 3
    li   x11, 9
    sub  x12, x11, x10     // x12 = 6
    addi x14, x0, 1        // unrelated instruction between producer/consumer
    add  x15, x12, x14     // x15 = 7, needs MEM/WB fwd
    ASSERT_EQ x15, 7, 2

    // Load-use hazard: consumer immediately after a load must stall one cycle.
    li   x5, 0x2000
    li   x6, 123
    sw   x6, 0(x5)
    lw   x7, 0(x5)
    addi x8, x7, 1
    ASSERT_EQ x8, 124, 3

    // Chained dependency through three back-to-back ALU ops.
    li   x10, 1
    addi x10, x10, 1       // 2
    addi x10, x10, 1       // 3
    addi x10, x10, 1       // 4
    ASSERT_EQ x10, 4, 4

    // Forwarding into a branch comparison (branches resolve in EX too).
    li   x10, 5
    addi x11, x10, 0       // x11 = 5, produced right before the branch
    beq  x11, x10, 5f
    RVTEST_FAIL 5
5:

    RVTEST_PASS
