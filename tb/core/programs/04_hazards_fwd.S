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

    // Load result forwarded directly into a branch comparison (load-use
    // hazard, consumer is a branch instead of an ALU op).
    li   x5, 0x2000
    li   x6, 42
    sw   x6, 4(x5)
    lw   x7, 4(x5)
    beq  x7, x6, 6f
    RVTEST_FAIL 6
6:

    // Chained load-use-load-use-branch: a loaded pointer used as the base
    // of a second load, whose result then feeds a branch immediately --
    // the exact pattern in Linux's alloc_fs_context() (fs_type read, then
    // fs_type->init_fs_context read, then a beqz on that result) that
    // stalled a real kernel boot. Two back-to-back load-use hazards on the
    // same register, the second one resolved into a branch.
    li   x5, 0x2000
    li   x6, 0x2010
    sw   x6, 8(x5)         // *(0x2008) = 0x2010 (pointer)
    sw   x0, 16(x6)        // *(0x2010+16) = 0   (pointed-to field == 0)
    lw   x8, 8(x5)         // x8 = 0x2010
    lw   x8, 16(x8)        // x8 = 0
    beqz x8, 7f
    RVTEST_FAIL 7
7:

    // Chained load-use-load-use feeding a STORE's data operand (not a
    // branch) -- the exact pattern in Linux's vfs_create_mount()
    // (mnt->mnt.mnt_sb = fc->root->d_sb) that produced a NULL superblock
    // pointer in a real kernel boot: a doubly-indirected load whose result
    // is stored on the very next instruction.
    li   x5, 0x2000
    li   x6, 0x2020
    sw   x6, 0(x5)          // *(0x2000) = 0x2020       (like fc->root)
    li   x7, 0xbeef
    sw   x7, 4(x6)          // *(0x2020+4) = 0xbeef     (like fc->root->d_sb)
    lw   x8, 0(x5)          // x8 = 0x2020
    lw   x8, 4(x8)          // x8 = 0xbeef
    sw   x8, 8(x5)          // *(0x2008) = x8, freshly double-loaded
    lw   x9, 8(x5)
    ASSERT_EQ x9, 0xbeef, 8

    // Same chain, but immediately preceded by an AMO*.W whose own address
    // is derived from the SAME double-indirected load (fc->root->d_sb),
    // exactly matching vfs_create_mount()'s real instruction sequence:
    //   amoadd.w zero,a4,(a5)      # atomic_inc(&fc->root->d_sb->s_active)
    //   lw a5,28(s2); lw a5,92(a5) # re-read fc->root->d_sb
    //   sw a5,20(s1)               # mnt->mnt.mnt_sb = ...
    li   x5, 0x2000
    li   x6, 0x2020
    sw   x6, 0(x5)          // *(0x2000) = 0x2020        (fc->root)
    li   x7, 0x3000
    sw   x7, 4(x6)          // *(0x2020+4) = 0x3000      (fc->root->d_sb, word-aligned)
    li   x10, 0
    sw   x10, 8(x6)         // *(0x2020+8) = 0           (d_sb->s_active, amo target)
    lw   x11, 0(x5)         // x11 = 0x2020              (fc->root)
    lw   x11, 4(x11)        // x11 = 0x3000              (fc->root->d_sb)
    addi x11, x11, 8        // x11 = &d_sb->s_active (0x3008, still aligned)
    li   x12, 1
    amoadd.w x0, x12, (x11) // atomic_inc(&d_sb->s_active) -- result discarded
    lw   x8, 0(x5)           // x8 = 0x2020               (re-read fc->root)
    lw   x8, 4(x8)           // x8 = 0x3000               (re-read fc->root->d_sb)
    sw   x8, 12(x5)          // *(0x200c) = x8, immediately after the AMO
    lw   x9, 12(x5)
    ASSERT_EQ x9, 0x3000, 9

    RVTEST_PASS
