/* =====================================================================
 * cache/icache.S  --  instruction-cache stress: whole-cache invalidation
 *                     by FENCE.I over large code blocks, address-bit
 *                     (tag/index) independence of instruction fetch,
 *                     and instructions straddling line and page
 *                     boundaries
 *
 * One of the two category files of the cache suite; see cache/tests.S
 * for how this plugs into the rest, cache/cache.inc for the scratch RAM
 * and the address window, and zifencei/fencei.S for FENCE.I's own
 * tests, whose conventions this file follows: code is written from
 * assembled templates in .rodata (ci_tpl_*, so no encoding is written
 * out by hand), called with "jalr s6, 0(<code>)", and returns with
 * "jalr zero, 0(s6)"; the generated code writes only t5/t6.
 *
 * WHAT IS UNDER TEST. zifencei/fencei.S rewrites one 16-byte buffer, so
 * a FENCE.I that invalidates only the line(s) it happens to find, or a
 * fetch path that is right only within one line, passes it. Here:
 *   - code blocks of 4 KiB (resident in any instruction cache) and
 *     256 KiB (larger than most): every slot "addi t6, t6, 1", run
 *     (t6 = the slot count), then every slot rewritten to
 *     "addi t6, t6, 2", FENCE.I, run again (twice the count). A line
 *     that FENCE.I left stale, or that the data side never wrote back,
 *     runs the old slots and comes up short by its slot count;
 *   - address-bit pairs: a routine "addi t6, zero, ID; ret" planted at
 *     every offset of CX_ADDR_TABLE in the 512 KiB window (0, each bit
 *     3..18, each pair of them), each with its own ID; all called in
 *     table order, then all rewritten with new IDs and called in reverse
 *     order. An instruction-cache tag or set-index bit that is ignored,
 *     stuck or coupled to another one returns another routine's ID. One
 *     check per pass: the first address that returned the wrong ID
 *     (0 = none);
 *   - a 32-bit instruction straddling a 16-, 32-, 64-, 128- or 4096-byte
 *     boundary (each placed so it straddles only that one: the 32-byte
 *     case sits on a 32-byte boundary that is not a 64-byte one), in
 *     three steps: "addi t6, zero, 0x123" runs; only the halfword after
 *     the boundary rewritten (the immediate becomes 0x456) runs the new
 *     immediate; only the halfword before it rewritten (rd becomes t5)
 *     writes t5 and leaves t6 alone. So both halves are refetched
 *     independently, and a fetch buffer that glues a stale half to a
 *     fresh one fails;
 *   - the same straddle in .text, fetched for the first time (the line
 *     or page after the boundary never ran before): at a 64-byte and at
 *     a 4 KiB boundary. These need no FENCE.I and are ADDI tests.
 * Under QEMU (no caches, coherent fetch) all of this passes whether or
 * not FENCE.I does anything; on hardware with an instruction cache it
 * is the real test.
 *
 * TRAPS AND WRONG PATHS. Every FENCE.I is under test and runs armed,
 * and each test stays armed until its last run of generated code: a
 * hart without Zifencei, or a fetch that sees garbage (an illegal
 * instruction), gives check_trap FAILs, never an UNEXPECTED TRAP. Before
 * each test the whole scratch region is filled with
 * "jalr zero, 0(s6)" (ci_prefill, synchronised with SYNC_I), so a stale
 * line, a misplaced line or a fetch from the wrong address runs either
 * an older version of the test's own code or a return, and comes back
 * with a wrong t6 instead of running away. A fetch that returns neither
 * (say, data never written back, on a hart whose FENCE.I is broken)
 * can still run anything; that is not testable more safely.
 *
 * No bitx cases: this file tests no instruction of its own (ADDI and
 * FENCE.I have theirs in i/op_imm.S and zifencei/fencei.S).
 *
 * Built unchanged for both widths.
 * ===================================================================== */

    .include "xlen.inc"
    .include "harness.inc"

    .option norvc            /* mandatory, not stylistic -- see i/loads.S */

    .include "cache/cache.inc"

    .global tests_cache_icache

    .section .text

/* =======================================================================
 *  Shared macros
 * ======================================================================= */

/* CI_LDW reg, sym -- load the 32-bit template word at sym, pc-relative. */
.macro CI_LDW reg, sym
    .option push
    .option norelax
    lw      \reg, \sym
    .option pop
.endm

/* T_CI_BLOCK bytes, sz -- the code-block test over `bytes` bytes of the
 * window (sz names the size). Two checks: the first run counts the
 * slots, the rewritten block's run counts twice that. */
.macro T_CI_BLOCK bytes, sz
    CX_NAME .Lcib_r\@, "FENCE.I: \sz code block written, every slot runs"
    CX_NAME .Lcib_n\@, "FENCE.I: \sz code block rewritten, no stale line runs"
    TEST_BEGIN .Lcib_r\@
    jal     ra, ci_prefill
    CX_WIN  s3
    CI_LDW  t4, ci_tpl_inc1
    li      a3, (\bytes) / 4 - 1
    jal     ra, ci_block_write
    TRAP_ARM .Lcib_trap\@           /* stays armed through both runs */
    fence.i
    li      t6, 0
    jalr    s6, 0(s3)
    mv      s1, t6
    CI_LDW  t4, ci_tpl_inc2
    li      a3, (\bytes) / 4 - 1
    jal     ra, ci_block_write
    fence.i
    li      t6, 0
    jalr    s6, 0(s3)
    mv      s2, t6
    TRAP_DISARM
    la      a0, .Lcib_r\@
    li      a1, (\bytes) / 4 - 1
    mv      a2, s1
    call    check
    TEST_BEGIN .Lcib_n\@
    la      a0, .Lcib_n\@
    li      a1, 2 * ((\bytes) / 4 - 1)
    mv      a2, s2
    call    check
    TRAP_FAILS .Lcib_trap\@, .Lcib_r\@, .Lcib_n\@
.endm

/* T_CI_STRAD b, idx -- the straddle test at a b-byte boundary, in the
 * idx-th 4 KiB page of the window after the first: the instruction
 * starts 2 bytes before offset 4096 * (1 + idx) + b, which is a
 * multiple of b but (for b < 4096) not of 2b. The routine is
 *     X    addi  t6, zero, 0x123   (ci_tpl_a; later _b, then _c)
 *     X+4  jalr  zero, 0(s6)
 * written as halfwords, since X is only 2-byte aligned. ci_tpl_b
 * differs from _a only in the immediate (bits 31:20, the half after
 * the boundary); ci_tpl_c differs from _b only in rd (bits 11:7, the
 * half before it). Four checks. */
.macro T_CI_STRAD b, idx
    CX_NAME .Lcis_a\@, "FENCE.I: instruction straddling a \b-byte boundary runs"
    CX_NAME .Lcis_u\@, "FENCE.I: straddler at a \b-byte boundary, half after it rewritten: new immediate"
    CX_NAME .Lcis_l\@, "FENCE.I: straddler at a \b-byte boundary, half before it rewritten: new rd written"
    CX_NAME .Lcis_k\@, "FENCE.I: straddler at a \b-byte boundary, half before it rewritten: old rd untouched"
    TEST_BEGIN .Lcis_a\@
    CX_WIN  s3
    li      t0, 4096 * (1 + (\idx)) + (\b) - 2
    add     s3, s3, t0
    CI_LDW  t4, ci_tpl_a
    sh      t4, 0(s3)
    srli    t4, t4, 16
    sh      t4, 2(s3)
    CI_LDW  t4, ci_tpl_ret
    sh      t4, 4(s3)
    srli    t4, t4, 16
    sh      t4, 6(s3)
    TRAP_ARM .Lcis_trap\@           /* stays armed through all three runs */
    fence.i
    li      t6, -1
    jalr    s6, 0(s3)
    mv      s1, t6
    CI_LDW  t4, ci_tpl_b            /* the half after the boundary */
    srli    t4, t4, 16
    sh      t4, 2(s3)
    fence.i
    li      t6, -1
    jalr    s6, 0(s3)
    mv      s2, t6
    CI_LDW  t4, ci_tpl_c            /* the half before it */
    sh      t4, 0(s3)
    fence.i
    li      t5, -1
    li      t6, -2
    jalr    s6, 0(s3)
    mv      s4, t5
    mv      s5, t6
    TRAP_DISARM
    la      a0, .Lcis_a\@
    li      a1, 0x123
    mv      a2, s1
    call    check
    TEST_BEGIN .Lcis_u\@
    la      a0, .Lcis_u\@
    li      a1, 0x456
    mv      a2, s2
    call    check
    TEST_BEGIN .Lcis_l\@
    la      a0, .Lcis_l\@
    li      a1, 0x456
    mv      a2, s4
    call    check
    TEST_BEGIN .Lcis_k\@
    la      a0, .Lcis_k\@
    li      a1, -2
    mv      a2, s5
    call    check
    TRAP_FAILS .Lcis_trap\@, .Lcis_a\@, .Lcis_u\@, .Lcis_l\@, .Lcis_k\@
.endm

tests_cache_icache:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    call    bx_sled_release         /* bx_region is ours from here on */

    jal     ra, test_ci_block
    jal     ra, test_ci_pairs
    jal     ra, test_ci_strad
    jal     ra, test_ci_text

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  Subroutines
 * ======================================================================= */

/* ci_prefill: every word of the first CX_REGION_BYTES of bx_region =
 * "jalr zero, 0(s6)", then SYNC_I (machinery, not under test).
 * Clobbers t0-t3. */
ci_prefill:
    CI_LDW  t1, ci_tpl_ret
    la      t0, bx_region
    li      t2, CX_REGION_BYTES / 4
1:  sw      t1, 0(t0)
    addi    t0, t0, 4
    addi    t2, t2, -1
    bnez    t2, 1b
    SYNC_I  t3
    ret

/* ci_block_write: a3 words of t4 from s3 on, then "jalr zero, 0(s6)".
 * Clobbers t0-t2. */
ci_block_write:
    mv      t0, s3
    mv      t1, a3
1:  sw      t4, 0(t0)
    addi    t0, t0, 4
    addi    t1, t1, -1
    bnez    t1, 1b
    CI_LDW  t2, ci_tpl_ret
    sw      t2, 0(t0)
    ret

/* ci_pair_plant: at s3 + o for the k-th offset o of ci_addr_tab,
 * "addi t6, zero, a3 + k; jalr zero, 0(s6)". Clobbers t0-t5. */
ci_pair_plant:
    la      t0, ci_addr_tab
    li      t2, CX_ADDR_N
    mv      t5, a3
    CI_LDW  t1, ci_tpl_zero
1:  lw      t3, 0(t0)
    add     t3, t3, s3
    slli    t4, t5, 20              /* imm field: bits 31:20 */
    or      t4, t4, t1
    sw      t4, 0(t3)
    CI_LDW  t4, ci_tpl_ret
    sw      t4, 4(t3)
    addi    t5, t5, 1
    addi    t0, t0, 4
    addi    t2, t2, -1
    bnez    t2, 1b
    ret

/* ci_pair_run: call every planted routine, in table order if a4 = 0,
 * reversed otherwise, with t6 poisoned; a5 = the first address whose
 * routine didn't return its ID (a3 + k), 0 if none. The routines touch
 * only t6 and return through s6, so ra survives. Clobbers t0-t4, t6. */
ci_pair_run:
    la      t0, ci_addr_tab
    li      t1, 4
    mv      t4, a3
    beqz    a4, 1f
    la      t0, ci_addr_tab_end - 4
    li      t1, -4
    addi    t4, a3, CX_ADDR_N - 1
1:  li      t2, CX_ADDR_N
    li      a5, 0
2:  lw      t3, 0(t0)
    add     t3, t3, s3
    li      t6, -1
    jalr    s6, 0(t3)
    beq     t6, t4, 3f
    bnez    a5, 3f
    mv      a5, t3
3:  add     t0, t0, t1
    srai    t3, t1, 2               /* the ID steps with the table: +-1 */
    add     t4, t4, t3
    addi    t2, t2, -1
    bnez    t2, 2b
    ret

/* =======================================================================
 *  Code blocks
 * ======================================================================= */
test_ci_block:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    T_CI_BLOCK 4096, "4 KiB"
    T_CI_BLOCK 262144, "256 KiB"

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  Address-bit pairs
 * ======================================================================= */
test_ci_pairs:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    TEST_BEGIN str_ci_pair_up
    jal     ra, ci_prefill
    CX_WIN  s3
    li      a3, 1
    jal     ra, ci_pair_plant
    TRAP_ARM .Lci_trap_pair         /* stays armed through both passes */
    fence.i
    li      a3, 1
    li      a4, 0
    jal     ra, ci_pair_run
    mv      s1, a5
    li      a3, 0x401
    jal     ra, ci_pair_plant
    fence.i
    li      a3, 0x401
    li      a4, 1
    jal     ra, ci_pair_run
    mv      s2, a5
    TRAP_DISARM
    la      a0, str_ci_pair_up
    li      a1, 0
    mv      a2, s1
    call    check
    TEST_BEGIN str_ci_pair_down
    la      a0, str_ci_pair_down
    li      a1, 0
    mv      a2, s2
    call    check
    TRAP_FAILS .Lci_trap_pair, str_ci_pair_up, str_ci_pair_down

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  Straddling instructions (generated)
 * ======================================================================= */
test_ci_strad:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    jal     ra, ci_prefill
    T_CI_STRAD 16, 0
    T_CI_STRAD 32, 1
    T_CI_STRAD 64, 2
    T_CI_STRAD 128, 3
    T_CI_STRAD 4096, 4

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  Straddling instructions in .text, first fetch
 * ======================================================================= */
test_ci_text:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    TEST_BEGIN str_ci_text64
    li      t6, -1
    la      t0, ci_strad64
    jalr    s6, 0(t0)
    mv      s1, t6
    la      a0, str_ci_text64
    li      a1, 0x2a5
    mv      a2, s1
    call    check

    TEST_BEGIN str_ci_text4k
    li      t6, -1
    la      t0, ci_strad4k
    jalr    s6, 0(t0)
    mv      s1, t6
    la      a0, str_ci_text4k
    li      a1, 0x5a2
    mv      a2, s1
    call    check

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* The .text straddlers: each "addi" starts 2 bytes before a 64-byte /
 * 4 KiB boundary, so its upper half is the first thing in a line / page
 * nothing else runs from. Only ever entered at the label; the filler
 * before it is c.unimp (0x0000), so a fetch that lands there traps. */
    .balign 64
    .fill   31, 2, 0
ci_strad64:
    addi    t6, zero, 0x2a5
    jalr    zero, 0(s6)

    .balign 4096
    .fill   2047, 2, 0
ci_strad4k:
    addi    t6, zero, 0x5a2
    jalr    zero, 0(s6)

/* =======================================================================
 *  Instruction templates (copied into code, never executed here),
 *  address table and strings
 * ======================================================================= */
    CX_ADDR_TABLE ci_addr_tab

    .section .rodata
    .balign 4
ci_tpl_inc1:  addi    t6, t6, 1
ci_tpl_inc2:  addi    t6, t6, 2
ci_tpl_ret:   jalr    zero, 0(s6)
ci_tpl_zero:  addi    t6, zero, 0
ci_tpl_a:     addi    t6, zero, 0x123
ci_tpl_b:     addi    t6, zero, 0x456
ci_tpl_c:     addi    t5, zero, 0x456

str_ci_pair_up:   .asciz "FENCE.I: code at address-bit pairs over 512 KiB, called in order: first wrong address (0 = none)"
str_ci_pair_down: .asciz "FENCE.I: code at address-bit pairs rewritten, called in reverse: first wrong address (0 = none)"
str_ci_text64:    .asciz "ADDI straddling a 64-byte boundary in .text, first fetch"
str_ci_text4k:    .asciz "ADDI straddling a 4 KiB page boundary in .text, first fetch"
