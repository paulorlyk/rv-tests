/* =====================================================================
 * zifencei/fencei.S  --  FENCE.I (Zifencei): instruction-fetch fence
 *
 * The only category file of the Zifencei suite; see zifencei/tests.S
 * for how this plugs into the rest (main_tests.S -> zifencei/tests.S
 * -> here), and common.S for the boot/UART/reporting harness everything
 * sits on ("check" is used from there, nothing else). FENCE.I is its
 * own extension, Zifencei, not RV64I proper, so it has a suite of its
 * own even though that suite is a single instruction.
 *
 * FENCE.I makes every store this hart did before it visible to this
 * hart's instruction fetches after it. That is the one thing it does,
 * so every test here is self-modifying code: write an instruction,
 * FENCE.I, execute it, and check that the new instruction ran, never a
 * stale copy. Each rewritten location has always been executed with its
 * old contents first, so a stale copy exists to be served if the fence
 * does nothing.
 *
 * The code under test is a two-instruction routine, written into
 * fi_buf (.bss) or patched in place in .text:
 *     addi  t6, zero, K        the "payload": K identifies the version
 *     jalr  zero, 0(s6)        return; callers use jalr s6, 0(<routine>)
 * and the instruction words are copied from assembled templates in
 * .rodata (fi_tpl_*), so no encoding is written out by hand.
 *
 * What is checked:
 *   - a routine written into a buffer runs; rewritten and fenced, the
 *     new version runs;
 *   - four rewrites in a row, each run once (the immediate built at run
 *     time), summed;
 *   - the new instruction written with four byte stores, and a
 *     compressed pair (c.li/c.jr) written with two halfword stores:
 *     the store width and instruction length don't matter;
 *   - the instruction right after the FENCE.I in the same code stream:
 *     a buffer that stores into its own next-but-one slot, fences, and
 *     runs straight into it;
 *   - patching a routine that lives in .text (fetched many times
 *     before), and patching it back;
 *   - FENCE.I leaves the registers alone.
 * Whether FENCE.I is *needed* (a missing fence may or may not show the
 * stale code) isn't testable, only that it is sufficient.
 *
 * TRAPS: every FENCE.I here is under test and runs armed (TRAP_ARM /
 * TRAP_FAILS, harness.inc), including FI_BUF_INIT's and the one inside
 * fi_buf in the "next instruction" test: on a hart without Zifencei,
 * or one that traps on the reserved fields, each check is a check_trap
 * FAIL, never an UNEXPECTED TRAP hang (the in-place .text patch is
 * undone on the way out). The FENCE.Is of the shared bitx machinery
 * are not under test and go through SYNC_I instead.
 *
 * ASSUMPTIONS: RAM holding .text and .bss is writable and executable
 * from M-mode (the bitx control-transfer tests already need the
 * latter). Under QEMU self-modifying code is detected even without a
 * fence, so there these tests pin down behaviour rather than prove the
 * fence works; on hardware with an instruction cache they are the
 * real test.
 *
 * Bit independence across fields (bitx_zifencei_fencei, at the end): the
 * spec reserves FENCE.I's rd, rs1 and imm[11:0] for finer-grained
 * fences and says implementations shall ignore them (software writes
 * zeros). So the variable bits are all 22 of those, background 0 (the
 * standard encoding), C(22,2) = 231 cases, each emitted with .insn:
 * every one must still fence (the rewritten routine runs) and must not
 * write rd. See BX_C_FI below and bitx.inc.
 *
 * Built unchanged for both widths.
 * ===================================================================== */

    .include "xlen.inc"
    .include "harness.inc"

    .option norvc            /* mandatory, not stylistic -- see i/loads.S */

    .include "bitx.inc"

    .global tests_zifencei_fencei

    .section .text

/* =======================================================================
 *  Shared macros
 * ======================================================================= */

/* FI_LDW reg, sym -- load the 32-bit template word at sym, pc-relative
 * (never gp-relative: the bitx cases sweep gp). */
.macro FI_LDW reg, sym
    .option push
    .option norelax
    lw      \reg, \sym
    .option pop
.endm

/* FI_BUF_INIT payload -- fi_buf = { payload, return } and FENCE.I; s3 =
 * fi_buf. Clobbers t4. Its FENCE.I is part of the test (every FENCE.I
 * in this file is), so callers run it armed. */
.macro FI_BUF_INIT payload
    .option push
    .option norelax
    la      s3, fi_buf
    .option pop
    FI_LDW  t4, \payload
    sw      t4, 0(s3)
    FI_LDW  t4, fi_tpl_ret
    sw      t4, 4(s3)
    fence.i
.endm

/* BX_C_FI nm, rd, rs1, v -- one bit-independence case (bitx.inc): the
 * FENCE.I encoding with rd/rs1 as given and imm = v (raw 12-bit field),
 * emitted with .insn since the assembler's fence.i has no operands.
 *
 * fi_buf is set up with payload 1 and run once (so a stale copy
 * exists), rewritten to payload 2, then rd and rs1 are loaded with the
 * sentinel (rd first: when they alias, it's the same register and the
 * same value), the FENCE.I under test runs, rd is captured into a4, and
 * the buffer runs again. Two checks: the buffer returned 2 (an
 * assemble-time constant), and rd still holds the sentinel (0 for
 * x0). Background rd = rs1 = x0 and imm = 0: the standard encoding.
 *
 * Besides the reserved registers listed in bitx.inc, s3 (fi_buf's
 * address), t4 (template words, then disarming) and a4 (x14, the
 * captured rd) are used; none is ever a candidate. The buffer itself
 * writes only t6 and returns through s6.
 *
 * Trapping: armed before FI_BUF_INIT, so one arm covers its FENCE.I
 * and the one under test (the spec says a hart must ignore the
 * reserved fields, so a trap on a nonzero one is a FAIL too); after a
 * trap, BX_TRAP_FAILS restores sp/gp/tp and reports both names as
 * check_trap FAILs. */
.macro BX_C_FI nm, rd, rs1, v
    BX_NAME .Lbxf_f\@, "\nm bitx rd=x\rd rs1=x\rs1 imm=\v fetch"
    BX_NAME .Lbxf_r\@, "\nm bitx rd=x\rd rs1=x\rs1 imm=\v rd"
    BX_ENTER .Lbxf_f\@
    TRAP_ARM .Lbxf_trap\@          /* covers both FENCE.Is */
    FI_BUF_INIT fi_tpl_one
    jalr    s6, 0(s3)
    FI_LDW  t4, fi_tpl_two
    sw      t4, 0(s3)
    BX_PV   x\rd, 2
    BX_PV   x\rs1, 2
    .insn   i 0x0f, 1, x\rd, x\rs1, ((\v) - (((\v) & 0x800) << 1))
    mv      a4, x\rd
    TRAP_DISARM_R t4
    jalr    s6, 0(s3)
    BX_LDC  t5, 2
    BX_REPORT_AT .Lbxf_f\@
    .if \rd == 0
    mv      t5, zero
    .else
    BX_PV   t5, 2
    .endif
    mv      t6, a4
    BX_REPORT_AT .Lbxf_r\@
    BX_TRAP_FAILS .Lbxf_trap\@, .Lbxf_f\@, .Lbxf_r\@
.endm

tests_zifencei_fencei:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    jal     ra, test_fencei

    jal     ra, bitx_zifencei_fencei

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* fi_patch_site: a routine in .text for the in-place patch test.
 * Returns 1 in t6 as assembled; the test patches it to 2 and back. */
    .balign 4
fi_patch_site:
    addi    t6, zero, 1
    jalr    zero, 0(s6)

/* =======================================================================
 *  FENCE.I
 * ======================================================================= */
test_fencei:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    /* --- a routine written into a buffer runs --- */
    TEST_BEGIN str_fi_first
    TRAP_ARM .Lfi_trap_first
    FI_BUF_INIT fi_tpl_one
    TRAP_DISARM
    jalr    s6, 0(s3)
    mv      s1, t6
    la      a0, str_fi_first
    LIX     a1, 1
    mv      a2, s1
    call    check
    TRAP_FAILS .Lfi_trap_first, str_fi_first

    /* --- rewritten and fenced, the new version runs --- */
    TEST_BEGIN str_fi_rewrite
    la      s3, fi_buf
    FI_LDW  t4, fi_tpl_two
    sw      t4, 0(s3)
    TRAP_ARM .Lfi_trap_rewrite
    fence.i
    TRAP_DISARM
    jalr    s6, 0(s3)
    mv      s1, t6
    la      a0, str_fi_rewrite
    LIX     a1, 2
    mv      a2, s1
    call    check
    TRAP_FAILS .Lfi_trap_rewrite, str_fi_rewrite

    /* --- four rewrites in a row: payload 10, 20, 30, 40, built at run
     *     time from the payload-0 template, each run once, summed --- */
    TEST_BEGIN str_fi_rounds
    la      s3, fi_buf
    FI_LDW  s1, fi_tpl_zero
    li      s2, 10
    li      s4, 4
    li      s5, 0
    TRAP_ARM .Lfi_trap_rounds       /* stays armed until a trap */
1:  slli    t0, s2, 20              /* imm field: bits 31:20 */
    or      t4, s1, t0
    sw      t4, 0(s3)
    fence.i
    jalr    s6, 0(s3)
    add     s5, s5, t6
    addi    s2, s2, 10
    addi    s4, s4, -1
    bnez    s4, 1b
    TRAP_DISARM
    la      a0, str_fi_rounds
    LIX     a1, 100
    mv      a2, s5
    call    check
    TRAP_FAILS .Lfi_trap_rounds, str_fi_rounds

    /* --- the new instruction written a byte at a time (payload 0x123
     *     over the payload-40 version just run) --- */
    TEST_BEGIN str_fi_bytes
    la      s3, fi_buf
    FI_LDW  t4, fi_tpl_zero
    LIX     t0, 0x123 << 20
    or      t4, t4, t0
    sb      t4, 0(s3)
    srli    t4, t4, 8
    sb      t4, 1(s3)
    srli    t4, t4, 8
    sb      t4, 2(s3)
    srli    t4, t4, 8
    sb      t4, 3(s3)
    TRAP_ARM .Lfi_trap_bytes
    fence.i
    TRAP_DISARM
    jalr    s6, 0(s3)
    mv      s1, t6
    la      a0, str_fi_bytes
    LIX     a1, 0x123
    mv      a2, s1
    call    check
    TRAP_FAILS .Lfi_trap_bytes, str_fi_bytes

    /* --- a compressed pair (c.li t6, 5 / c.jr s6) written with two
     *     halfword stores over the 4-byte payload --- */
    TEST_BEGIN str_fi_rvc
    la      s3, fi_buf
    la      t0, fi_tpl_rvc
    lhu     t4, 0(t0)
    sh      t4, 0(s3)
    lhu     t4, 2(t0)
    sh      t4, 2(s3)
    TRAP_ARM .Lfi_trap_rvc
    fence.i
    TRAP_DISARM
    jalr    s6, 0(s3)
    mv      s1, t6
    la      a0, str_fi_rvc
    LIX     a1, 5
    mv      a2, s1
    call    check
    TRAP_FAILS .Lfi_trap_rvc, str_fi_rvc

    /* --- the instruction right after FENCE.I: fi_buf becomes
     *         +0  sw     t4, 8(s3)
     *         +4  fence.i
     *         +8  addi   t6, zero, 1
     *         +12 jalr   zero, 0(s6)
     *     First run with t4 = the payload-1 word (rewrites +8 with
     *     itself, warming it), then with t4 = the payload-2 word: the
     *     fence must make the fetch of +8 see it. --- */
    TEST_BEGIN str_fi_next_warm
    la      s3, fi_buf
    FI_LDW  t4, fi_tpl_sw
    sw      t4, 0(s3)
    FI_LDW  t4, fi_tpl_fence
    sw      t4, 4(s3)
    FI_LDW  t4, fi_tpl_one
    sw      t4, 8(s3)
    FI_LDW  t4, fi_tpl_ret
    sw      t4, 12(s3)
    TRAP_ARM .Lfi_trap_next         /* also covers the FENCE.I in fi_buf */
    fence.i
    FI_LDW  t4, fi_tpl_one
    jalr    s6, 0(s3)
    mv      s1, t6
    FI_LDW  t4, fi_tpl_two
    jalr    s6, 0(s3)
    mv      s2, t6
    TRAP_DISARM
    la      a0, str_fi_next_warm
    LIX     a1, 1
    mv      a2, s1
    call    check
    TEST_BEGIN str_fi_next
    la      a0, str_fi_next
    LIX     a1, 2
    mv      a2, s2
    call    check
    TRAP_FAILS .Lfi_trap_next, str_fi_next_warm, str_fi_next

    /* --- patch a routine in .text in place, and patch it back --- */
    TEST_BEGIN str_fi_text_orig
    la      s3, fi_patch_site
    jalr    s6, 0(s3)
    mv      s1, t6
    TRAP_ARM .Lfi_trap_text
    FI_LDW  t4, fi_tpl_two
    sw      t4, 0(s3)
    fence.i
    jalr    s6, 0(s3)
    mv      s2, t6
    FI_LDW  t4, fi_tpl_one
    sw      t4, 0(s3)
    fence.i
    jalr    s6, 0(s3)
    mv      s4, t6
    TRAP_DISARM
    la      a0, str_fi_text_orig
    LIX     a1, 1
    mv      a2, s1
    call    check
    TEST_BEGIN str_fi_text_patched
    la      a0, str_fi_text_patched
    LIX     a1, 2
    mv      a2, s2
    call    check
    TEST_BEGIN str_fi_text_restored
    la      a0, str_fi_text_restored
    LIX     a1, 1
    mv      a2, s4
    call    check
    j       .Lfi_text_done
.Lfi_trap_text:                     /* put fi_patch_site back first */
    la      s3, fi_patch_site
    FI_LDW  t4, fi_tpl_one
    sw      t4, 0(s3)
    TRAP_REPORT str_fi_text_orig
    TRAP_REPORT str_fi_text_patched
    TRAP_REPORT str_fi_text_restored
.Lfi_text_done:

    /* --- no register side effects: five registers with distinct
     *     patterns, one FENCE.I, then (reg ^ pattern) ORed together
     *     must be 0 --- */
    TEST_BEGIN str_fi_regs
    LIXT    a3, 0x0123456789abcdef
    LIXT    a4, 0xfedcba9876543210
    LIXT    a5, 0x5a5a5a5aa5a5a5a5
    LIXT    t3, 0x8000000000000001
    LIXT    t4, 0x7ffffffffffffffe
    TRAP_ARM .Lfi_trap_regs
    fence.i
    TRAP_DISARM
    LIXT    t0, 0x0123456789abcdef
    xor     t5, a3, t0
    LIXT    t0, 0xfedcba9876543210
    xor     t0, a4, t0
    or      t5, t5, t0
    LIXT    t0, 0x5a5a5a5aa5a5a5a5
    xor     t0, a5, t0
    or      t5, t5, t0
    LIXT    t0, 0x8000000000000001
    xor     t0, t3, t0
    or      t5, t5, t0
    LIXT    t0, 0x7ffffffffffffffe
    xor     t0, t4, t0
    or      t5, t5, t0
    mv      s1, t5
    la      a0, str_fi_regs
    LIX     a1, 0
    mv      a2, s1
    call    check
    TRAP_FAILS .Lfi_trap_regs, str_fi_regs

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* Bit independence across fields -- see the file header, BX_C_FI and
 * bitx.inc. rd and rs1 are 5-bit register fields with background x0,
 * imm is the 12-bit field with background 0: the standard encoding.
 * Only the sentinel (BX_PV 2) is used from the pool. */
bitx_zifencei_fencei:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    BX_POOL 0, 0
    BX_E_RRI5 BX_C_FI, "FENCE.I", 0, 0, "0x1,0x2,0x4,0x8,0x10,0x20,0x40,0x80,0x100,0x200,0x400,0x800", 0

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  Instruction templates (copied into code, never executed here) and
 *  strings
 * ======================================================================= */
    .section .rodata
    .balign 4
fi_tpl_zero:  addi    t6, zero, 0
fi_tpl_one:   addi    t6, zero, 1
fi_tpl_two:   addi    t6, zero, 2
fi_tpl_ret:   jalr    zero, 0(s6)
fi_tpl_sw:    sw      t4, 8(s3)
fi_tpl_fence: fence.i
fi_tpl_rvc:
    .option push
    .option rvc
    c.li    t6, 5
    c.jr    s6
    .option pop

str_fi_first:         .asciz "FENCE.I: code written to a buffer runs"
str_fi_rewrite:       .asciz "FENCE.I: rewritten code runs, not the stale copy"
str_fi_rounds:        .asciz "FENCE.I: four rewrites in a row, each runs"
str_fi_bytes:         .asciz "FENCE.I: instruction written with byte stores"
str_fi_rvc:           .asciz "FENCE.I: compressed pair written with halfword stores"
str_fi_next_warm:     .asciz "FENCE.I in the modified code: first run (unchanged)"
str_fi_next:          .asciz "FENCE.I in the modified code: next instruction refetched"
str_fi_text_orig:     .asciz "FENCE.I .text patch: original routine"
str_fi_text_patched:  .asciz "FENCE.I .text patch: patched routine runs"
str_fi_text_restored: .asciz "FENCE.I .text patch: restored routine runs"
str_fi_regs:          .asciz "FENCE.I leaves registers unchanged"

/* =======================================================================
 *  Code buffer
 * ======================================================================= */
    .section .bss
    .balign 8
fi_buf:     .skip 16
