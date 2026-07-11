// =============================================================================
// tb/core/programs/05_jal_jalr.S
// =============================================================================
// Directed test: JAL / JALR link-register (pc+4) writeback and target
// computation (branch_unit.sv), including a nonzero JALR immediate.
// =============================================================================

#include "test_macros.h"

.section .text.start
.global _start
_start:
    li    sp, 0x7ff0

    // JAL: rd = return addr (pc of the jal + 4, i.e. the fall-through
    // instruction below), pc redirected to target.
    jal   x10, jal_target
after_jal:
    RVTEST_FAIL 1               // unreachable: jal is unconditional
jal_target:
    la    x11, after_jal
    ASSERT_EQ_REG x10, x11, 2

    // JALR, imm = 0
    la    x12, jalr_target1
    jalr  x13, x12, 0
after_jalr1:
    RVTEST_FAIL 3
jalr_target1:
    la    x14, after_jalr1
    ASSERT_EQ_REG x13, x14, 4

    // JALR, nonzero immediate offset
    la    x12, jalr_target2
    addi  x12, x12, -4
    jalr  x15, x12, 4
after_jalr2:
    RVTEST_FAIL 5
jalr_target2:
    la    x16, after_jalr2
    ASSERT_EQ_REG x15, x16, 6

    // Backward jump loop via JAL-free branch, sanity check after link regs used.
    li    x20, 0
back_loop_entry:
    addi  x20, x20, 1
    li    x21, 3
    bne   x20, x21, back_loop_entry
    ASSERT_EQ x20, 3, 7

    RVTEST_PASS
