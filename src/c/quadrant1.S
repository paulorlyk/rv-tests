/* =====================================================================
 * c/quadrant1.S  --  RVC quadrant 1 (compressed opcode bits[1:0]=01):
 *                       C.NOP, C.ADDI, C.ADDIW, C.LI, C.ADDI16SP,
 *                       C.LUI, C.SRLI, C.SRAI, C.ANDI, C.SUB, C.XOR,
 *                       C.OR, C.AND, C.SUBW, C.ADDW, C.J, C.BEQZ,
 *                       C.BNEZ; C.JAL (RV32 image only)
 *
 * Part of the RV64C test suite; see c/tests.S for the overall
 * structure and common.S for the boot/UART/reporting harness this
 * builds on ("check", "uart_puts", etc. are provided there). This
 * file's only entry point called from outside is tests_c_quadrant1,
 * invoked once by run_tests (in c/tests.S).
 *
 * The C.NOP memory-unaffected check uses word_buf, defined and
 * .global'd in c/quadrant0.S.
 *
 * Bit independence across fields (bitx_c_quadrant1, called last): every
 * bit pair among each instruction's variable fields set together, for
 * every instruction here except C.NOP (no variable fields): 55 cases
 * for C.ADDI/C.ADDIW/C.LI/C.J/C.BEQZ/C.BNEZ, 49 for C.LUI, 36 for
 * C.SRLI/C.SRAI/C.ANDI, 15 for C.ADDI16SP and each CA op. See the
 * bit-independence block below and bitx.inc.
 *
 * RV32 image (xlen.inc): C.ADDIW, C.SUBW and C.ADDW are RV64C-only and
 * left out; C.JAL, which reuses C.ADDIW's encoding on RV32C, is tested
 * instead (test_c_jal, plus 55 bit-independence cases); C.SRLI/C.SRAI
 * take a 5-bit shamt (28 bit-independence cases each).
 * ===================================================================== */

    .include "xlen.inc"
    .include "harness.inc"

    .option norvc

    .include "bitx.inc"

    .global tests_c_quadrant1

    .section .text

/* =======================================================================
 *  Bit-independence cases (bitx.inc, bitx.S)
 *
 *  Expected values here are all assemble-time constants from the pool
 *  (the operands are fixed: BX_Q1_VA/BX_Q1_VB), so no reference
 *  instruction is involved at all. Where rd is also a source (C.ADDI,
 *  C.ADDIW, C.SRLI/SRAI/ANDI and the CA ops) it starts as BX_Q1_VA;
 *  where it's only written (C.LI, C.LUI) it's poisoned with the
 *  sentinel.
 * ======================================================================= */
    .equ BX_Q1_VA, 0x8123456789abcdef
    .equ BX_Q1_VB, 0x0fedcba987654321

/* CI / CB-immediate: rd (5-bit, or 3-bit for SRLI/SRAI/ANDI) and a 6-bit
 * immediate or shamt; v is the raw field. C.LUI rd=x2 is skipped (that
 * encoding is C.ADDI16SP, tested separately), so C.LUI has 55 - 6 = 49
 * cases. */
.macro BX_C_CI insn, nm, rd, v
    .set    bx_skip, 0
    .ifc \insn, c.lui
    .if \rd == 2
    .set    bx_skip, 1
    .endif
    .endif
    .if bx_skip == 0
    BX_ENTER
    .ifc \insn, c.addi
    BX_LDC  t5, (BX_Q1_VA + ((\v) - (((\v) & 0x20) << 1)))
    .endif
    .ifc \insn, c.addiw
    BX_LDC  t5, ((((BX_Q1_VA + ((\v) - (((\v) & 0x20) << 1))) & 0xffffffff) ^ 0x80000000) - 0x80000000)
    .endif
    .ifc \insn, c.li
    BX_LDC  t5, ((\v) - (((\v) & 0x20) << 1))
    .endif
    .ifc \insn, c.lui
    BX_LDC  t5, (((\v) - (((\v) & 0x20) << 1)) << 12)
    .endif
    .ifc \insn, c.srli
    BX_LDC  t5, ((BX_Q1_VA & XLEN_MASK) >> (\v))
    .endif
    .ifc \insn, c.srai
    BX_LDC  t5, (((BX_Q1_VA & XLEN_MASK) >> (\v)) | (-((BX_Q1_VA & XLEN_MASK) >> (XLEN - 1)) & ~(XLEN_MASK >> (\v))))
    .endif
    .ifc \insn, c.andi
    BX_LDC  t5, (BX_Q1_VA & ((\v) - (((\v) & 0x20) << 1)))
    .endif
    .set    bx_wo, 0                /* rd is write-only */
    .ifc \insn, c.li
    .set    bx_wo, 1
    .endif
    .ifc \insn, c.lui
    .set    bx_wo, 1
    .endif
    .if bx_wo
    BX_PV   x\rd, 2
    .else
    BX_PV   x\rd, 0
    .endif
    .option push
    .option rvc
    .ifc \insn, c.lui
    c.lui   x\rd, (((\v) - (((\v) & 0x20) << 1)) & 0xfffff)
    .else
    .ifc \insn, c.srli
    c.srli  x\rd, (\v)
    .else
    .ifc \insn, c.srai
    c.srai  x\rd, (\v)
    .else
    \insn   x\rd, ((\v) - (((\v) & 0x20) << 1))
    .endif
    .endif
    .endif
    .option pop
    mv      t6, x\rd
    BX_REPORT "\nm bitx rd=x\rd imm=\v"
    .endif
.endm

/* C.ADDI16SP: its only field is the 6-bit nzimm (bits 9:4), so C(6,2) =
 * 15 within-field pairs; sp is loaded with BX_Q1_VA and restored by
 * BX_REPORT. */
.macro BX_C_A16SP nm, v
    BX_ENTER
    BX_LDC  t5, (BX_Q1_VA + ((\v) - (((\v) & 0x200) << 1)))
    BX_PV   sp, 0
    .option push
    .option rvc
    c.addi16sp sp, ((\v) - (((\v) & 0x200) << 1))
    .option pop
    mv      t6, sp
    BX_REPORT "\nm bitx imm=\v"
.endm

/* CA: rd' (also rs1') and rs2'. rd' = VA, then rs2' = VB, so aliasing
 * makes both VB. */
.macro BX_CA_EXP insn, a, b
    .ifc \insn, c.sub
    BX_LDC  t5, ((\a) - (\b))
    .endif
    .ifc \insn, c.xor
    BX_LDC  t5, ((\a) ^ (\b))
    .endif
    .ifc \insn, c.or
    BX_LDC  t5, ((\a) | (\b))
    .endif
    .ifc \insn, c.and
    BX_LDC  t5, ((\a) & (\b))
    .endif
    .ifc \insn, c.subw
    BX_LDC  t5, (((((\a) - (\b)) & 0xffffffff) ^ 0x80000000) - 0x80000000)
    .endif
    .ifc \insn, c.addw
    BX_LDC  t5, (((((\a) + (\b)) & 0xffffffff) ^ 0x80000000) - 0x80000000)
    .endif
.endm

.macro BX_C_CA insn, nm, rd, rs2
    BX_ENTER
    .if \rd == \rs2
    BX_CA_EXP \insn, BX_Q1_VB, BX_Q1_VB
    .else
    BX_CA_EXP \insn, BX_Q1_VA, BX_Q1_VB
    .endif
    BX_PV   x\rd, 0
    BX_PV   x\rs2, 1
    .option push
    .option rvc
    \insn   x\rd, x\rs2
    .option pop
    mv      t6, x\rd
    BX_REPORT "\nm bitx rd'=x\rd rs2'=x\rs2"
.endm

/* C.J: the 11-bit offset (bits 11:1, bit 11 the sign) alone, C(11,2) =
 * 55 pairs, landing in the counting sled. Unlike a 4-byte transfer,
 * +2 is a real target here (the next halfword), though for C.J it's
 * indistinguishable from not jumping at all. */
.macro BX_C_CJ nm, v
    .if ((\v) - (((\v) & 0x800) << 1)) > 0
    BX_C_CJ_ \nm, \v, ((\v) - (((\v) & 0x800) << 1)), (BX_EXIT - ((\v) - (((\v) & 0x800) << 1)) - 2 * BX_MARGIN)
    .else
    BX_C_CJ_ \nm, \v, ((\v) - (((\v) & 0x800) << 1)), BX_SITE_B
    .endif
.endm

.macro BX_C_CJ_ nm, v, d, site
    BX_ENTER
    .pushsection .rodata
    .balign 4
    .option push
    .option norelax
    .option rvc
96: c.j     96b + (\d)
    .option pop
    .popsection
    BX_PLANT \site, 2
    BX_GO   \site
    BX_COUNT \site, \d, 2, 1
    BX_REPORT "\nm bitx off=\v"
.endm

/* C.JAL (RV32C only): C.J's 11-bit offset, C(11,2) = 55 pairs, in the
 * sled; ra is poisoned first and must end up as the site's address + 2. */
.macro BX_C_CJAL nm, v
    .if ((\v) - (((\v) & 0x800) << 1)) > 0
    BX_C_CJAL_ \nm, \v, ((\v) - (((\v) & 0x800) << 1)), (BX_EXIT - ((\v) - (((\v) & 0x800) << 1)) - 2 * BX_MARGIN)
    .else
    BX_C_CJAL_ \nm, \v, ((\v) - (((\v) & 0x800) << 1)), BX_SITE_B
    .endif
.endm

.macro BX_C_CJAL_ nm, v, d, site
    BX_ENTER
    .pushsection .rodata
    .balign 4
    .option push
    .option norelax
    .option rvc
96: c.jal   96b + (\d)
    .option pop
    .popsection
    BX_PLANT \site, 2
    BX_PV   ra, 2
    BX_GO   \site
    mv      s3, ra
    BX_COUNT \site, \d, 2, 1
    BX_REPORT "\nm bitx off=\v landed"
    mv      t6, s3
    .option push
    .option norelax
    la      t5, bx_region + (\site) + 2
    .option pop
    BX_REPORT "\nm bitx off=\v link"
.endm

/* C.BEQZ / C.BNEZ: rs1' and the 8-bit offset (bits 8:1, bit 8 the sign),
 * C(11,2) = 55 pairs; rs1' holds the pool's va, chosen so the branch is
 * taken (0 for BEQZ, nonzero for BNEZ). */
.macro BX_C_CB insn, nm, rs1, v
    .if ((\v) - (((\v) & 0x100) << 1)) > 0
    BX_C_CB_ \insn, \nm, \rs1, \v, ((\v) - (((\v) & 0x100) << 1)), (BX_EXIT - ((\v) - (((\v) & 0x100) << 1)) - 2 * BX_MARGIN)
    .else
    BX_C_CB_ \insn, \nm, \rs1, \v, ((\v) - (((\v) & 0x100) << 1)), BX_SITE_B
    .endif
.endm

.macro BX_C_CB_ insn, nm, rs1, v, d, site
    BX_ENTER
    .pushsection .rodata
    .balign 4
    .option push
    .option norelax
    .option rvc
96: \insn   x\rs1, 96b + (\d)
    .option pop
    .popsection
    BX_PLANT \site, 2
    BX_PV   x\rs1, 0
    BX_GO   \site
    BX_COUNT \site, \d, 2, 1
    BX_REPORT "\nm bitx rs1'=x\rs1 off=\v"
.endm

/* =======================================================================
 *  QUADRANT 1 : C.NOP, C.ADDI, C.ADDIW, C.LI, C.ADDI16SP, C.LUI,
 *               C.SRLI, C.SRAI, C.ANDI, C.SUB, C.XOR, C.OR, C.AND,
 *               C.SUBW, C.ADDW, C.J, C.BEQZ, C.BNEZ
 * ======================================================================= */

/* =======================================================================
 *  C.NOP : the single canonical encoding rd=x0, imm=0 (CI format).
 *  There are no operands to sweep -- what's worth checking is that it
 *  genuinely does nothing: no GPR, sp, or memory location is touched,
 *  singly or back-to-back.
 * ======================================================================= */
test_c_nop:
    TEST_BEGIN str_nop_t0
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    LIXT    s0, 0x1111111111111111
    LIXT    s1, 0x2222222222222222
    LIXT    s3, 0x3333333333333333
    LIXT    s4, 0x4444444444444444
    LIXT    s5, 0x5555555555555555
    LIXT    a3, 0x6666666666666666
    .option rvc
    c.nop
    .option norvc
    la      a0, str_nop_t0
    LIXT    a1, 0x1111111111111111
    mv      a2, s0
    call    check
    TEST_BEGIN str_nop_t1
    la      a0, str_nop_t1
    LIXT    a1, 0x2222222222222222
    mv      a2, s1
    call    check
    TEST_BEGIN str_nop_t2
    la      a0, str_nop_t2
    LIXT    a1, 0x3333333333333333
    mv      a2, s3
    call    check
    TEST_BEGIN str_nop_s0
    la      a0, str_nop_s0
    LIXT    a1, 0x4444444444444444
    mv      a2, s4
    call    check
    TEST_BEGIN str_nop_s1
    la      a0, str_nop_s1
    LIXT    a1, 0x5555555555555555
    mv      a2, s5
    call    check
    TEST_BEGIN str_nop_a3
    la      a0, str_nop_a3
    LIXT    a1, 0x6666666666666666
    mv      a2, a3
    call    check

    /* --- sp unaffected --- */
    TEST_BEGIN str_nop_sp
    mv      t3, sp
    .option rvc
    c.nop
    .option norvc
    la      a0, str_nop_sp
    mv      a1, t3
    mv      a2, sp
    call    check

    /* --- memory unaffected --- */
    TEST_BEGIN str_nop_mem
    la      s2, word_buf
    LIX     t4, 0xdeadbeef
    sw      t4, 0(s2)
    .option rvc
    c.nop
    .option norvc
    LWUX    t5, 0(s2)
    la      a0, str_nop_mem
    LIX     a1, 0xdeadbeef
    mv      a2, t5
    call    check

    /* --- back-to-back sequence of NOPs, still no side effects --- */
    TEST_BEGIN str_nop_sequence
    LIXT    t0, 0x7777777777777777
    .option rvc
    c.nop
    c.nop
    c.nop
    c.nop
    .option norvc
    la      a0, str_nop_sequence
    LIXT    a1, 0x7777777777777777
    mv      a2, t0
    call    check

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  Shared macros for C.ADDI / C.ADDIW
 *
 *  Both share the CI encoding shape (rd = rs1, full 5-bit register,
 *  6-bit signed nzimm) and, at small non-overflowing magnitudes,
 *  identical arithmetic -- so one macro pair, parameterized by the
 *  mnemonic itself (GNU as macro args are plain text substitution, so
 *  passing "c.addi" or "c.addiw" as an argument works fine), covers
 *  the register-field sweep and the immediate-field sweep for both.
 *  Each instruction then gets its own dedicated tests for the
 *  behavior that's genuinely different between them (C.ADDI's 64-bit
 *  wraparound vs. C.ADDIW's 32-bit overflow/sign-extension/garbage-
 *  upper-bits handling).
 * ======================================================================= */

/* T_CI_RI insn, reg, base, imm, expect, name
 *   reg = base; insn reg, imm; check reg == expect. reg may be
 *   ra/a0/a1/a2 -- result is copied to t2 before a0-a2 are reused. */
.macro T_CI_RI insn, reg, base, imm, expect, name
    TEST_BEGIN \name
    LIX     \reg, \base
    .option rvc
    \insn   \reg, \imm
    .option norvc
    mv      t2, \reg
    la      a0, \name
    LIX     a1, \expect
    mv      a2, t2
    call    check
.endm

/* =======================================================================
 *  C.ADDI : rd = rd + sign_extend(nzimm), full 64-bit add, rd != x0.
 * ======================================================================= */
test_c_addi:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    /* --- every register class across the full 5-bit rd field --- */
    T_CI_RI c.addi, ra,  100, 23, 123, str_addi_reg_ra
    T_CI_RI c.addi, t0,  100, 23, 123, str_addi_reg_t0
    T_CI_RI c.addi, s0,  100, 23, 123, str_addi_reg_s0
    T_CI_RI c.addi, a0,  100, 23, 123, str_addi_reg_a0
    T_CI_RI c.addi, a4,  100, 23, 123, str_addi_reg_a4
    T_CI_RI c.addi, s2,  100, 23, 123, str_addi_reg_s2
    T_CI_RI c.addi, s6,  100, 23, 123, str_addi_reg_s6
    T_CI_RI c.addi, s10, 100, 23, 123, str_addi_reg_s10
    T_CI_RI c.addi, t6,  100, 23, 123, str_addi_reg_t6

    /* --- every individual immediate-magnitude bit, both signs, plus
     *     the true min/max boundary (-32 / 31) --- */
    T_CI_RI c.addi, t1, 0,   1, 1,   str_addi_imm_p1
    T_CI_RI c.addi, t1, 0,  -1, -1,  str_addi_imm_m1
    T_CI_RI c.addi, t1, 0,   2, 2,   str_addi_imm_p2
    T_CI_RI c.addi, t1, 0,  -2, -2,  str_addi_imm_m2
    T_CI_RI c.addi, t1, 0,   4, 4,   str_addi_imm_p4
    T_CI_RI c.addi, t1, 0,  -4, -4,  str_addi_imm_m4
    T_CI_RI c.addi, t1, 0,   8, 8,   str_addi_imm_p8
    T_CI_RI c.addi, t1, 0,  -8, -8,  str_addi_imm_m8
    T_CI_RI c.addi, t1, 0,  16, 16,  str_addi_imm_p16
    T_CI_RI c.addi, t1, 0, -16, -16, str_addi_imm_m16
    T_CI_RI c.addi, t1, 0,  31, 31,  str_addi_imm_max
    T_CI_RI c.addi, t1, 0, -32, -32, str_addi_imm_min

    /* --- full 64-bit modular wraparound, not just 32-bit --- */
    T_CI_RI c.addi, t0, 0xffffffffffffffff, 1,  0x0000000000000000, str_addi_wrap_inc
    T_CI_RI c.addi, t0, INTX_MIN, -1, INTX_MAX, str_addi_wrap_dec

    TEST_BEGIN str_addi_sp_delta
    /* --- rd = sp is legal for plain C.ADDI (distinct from
     *     C.ADDI16SP's dedicated encoding); isolate and verify both
     *     the applied delta and that sp is fully restored after --- */
    mv      t3, sp
    .option rvc
    c.addi  sp, -16
    .option norvc
    mv      t4, sp
    .option rvc
    c.addi  sp, 16
    .option norvc
    la      a0, str_addi_sp_delta
    LIX     a1, -16
    sub     a2, t4, t3
    call    check
    TEST_BEGIN str_addi_sp_restored
    la      a0, str_addi_sp_restored
    mv      a1, t3
    mv      a2, sp
    call    check

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* T_ADDIW_VAL init64, imm, expect64, name
 *   Dedicated to the behavior that's actually different about
 *   C.ADDIW: the add happens on the low 32 bits only, any pre-existing
 *   upper 32 bits of the register are discarded (not preserved, not
 *   part of the arithmetic), and the 32-bit result is sign-extended
 *   to fill the 64-bit destination. */
.macro T_ADDIW_VAL init64, imm, expect64, name
    TEST_BEGIN \name
    LIX     t1, \init64
    .option rvc
    c.addiw t1, \imm
    .option norvc
    la      a0, \name
    LIX     a1, \expect64
    mv      a2, t1
    call    check
.endm

/* =======================================================================
 *  C.ADDIW : rd = sign_extend32(rd[31:0] + sign_extend(nzimm)), rd!=x0.
 * ======================================================================= */
    .if XLEN == 64                  /* RV64C-only */
test_c_addiw:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    /* --- every register class across the full 5-bit rd field (small
     *     magnitudes, no 32-bit overflow -- identical arithmetic to
     *     C.ADDI here, so this mainly re-confirms the rd decode) --- */
    T_CI_RI c.addiw, ra,  100, 23, 123, str_addiw_reg_ra
    T_CI_RI c.addiw, t0,  100, 23, 123, str_addiw_reg_t0
    T_CI_RI c.addiw, s0,  100, 23, 123, str_addiw_reg_s0
    T_CI_RI c.addiw, a0,  100, 23, 123, str_addiw_reg_a0
    T_CI_RI c.addiw, a4,  100, 23, 123, str_addiw_reg_a4
    T_CI_RI c.addiw, s2,  100, 23, 123, str_addiw_reg_s2
    T_CI_RI c.addiw, s6,  100, 23, 123, str_addiw_reg_s6
    T_CI_RI c.addiw, s10, 100, 23, 123, str_addiw_reg_s10
    T_CI_RI c.addiw, t6,  100, 23, 123, str_addiw_reg_t6

    /* --- every individual immediate-magnitude bit, both signs, plus
     *     min/max boundary (at base=0, no overflow, matches C.ADDI) --- */
    T_CI_RI c.addiw, t1, 0,   1, 1,   str_addiw_imm_p1
    T_CI_RI c.addiw, t1, 0,  -1, -1,  str_addiw_imm_m1
    T_CI_RI c.addiw, t1, 0,   2, 2,   str_addiw_imm_p2
    T_CI_RI c.addiw, t1, 0,  -2, -2,  str_addiw_imm_m2
    T_CI_RI c.addiw, t1, 0,   4, 4,   str_addiw_imm_p4
    T_CI_RI c.addiw, t1, 0,  -4, -4,  str_addiw_imm_m4
    T_CI_RI c.addiw, t1, 0,   8, 8,   str_addiw_imm_p8
    T_CI_RI c.addiw, t1, 0,  -8, -8,  str_addiw_imm_m8
    T_CI_RI c.addiw, t1, 0,  16, 16,  str_addiw_imm_p16
    T_CI_RI c.addiw, t1, 0, -16, -16, str_addiw_imm_m16
    T_CI_RI c.addiw, t1, 0,  31, 31,  str_addiw_imm_max
    T_CI_RI c.addiw, t1, 0, -32, -32, str_addiw_imm_min

    /* --- 32-bit overflow/underflow and sign extension, plus garbage
     *     upper 32 bits that must be discarded, not preserved --- */
    T_ADDIW_VAL 0xdeadbeef7ffffffe,  4, 0xffffffff80000002, str_addiw_overflow_pos
    T_ADDIW_VAL 0xffffffff7fffffe0, 31, 0x000000007fffffff, str_addiw_maxpos_noverflow
    T_ADDIW_VAL 0x0000000080000000, -1, 0x000000007fffffff, str_addiw_underflow_wrap
    T_ADDIW_VAL 0x0000000000000000, -32, 0xffffffffffffffe0, str_addiw_minimm
    T_ADDIW_VAL 0xaaaaaaaa00000001, -1, 0x0000000000000000, str_addiw_upper_garbage_zero

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret
    .endif

/* T_LI_VAL rd, poison, imm, expect, name
 *   Poison rd first (so a broken "OR"/"add" implementation instead of
 *   a genuine load would be caught), then C.LI it, then check for the
 *   exact expected sign-extended value. rd may be a0/a1/a2 -- result
 *   copied out before those get reused. */
.macro T_LI_VAL rd, poison, imm, expect, name
    TEST_BEGIN \name
    LIXT    \rd, \poison
    .option rvc
    c.li    \rd, \imm
    .option norvc
    mv      t2, \rd
    la      a0, \name
    LIX     a1, \expect
    mv      a2, t2
    call    check
.endm

/* =======================================================================
 *  C.LI : rd = sign_extend(imm)  (CI format, full 5-bit rd != x0,
 *         6-bit signed imm -- unlike C.ADDI, imm=0 is legal here: it's
 *         a genuine "load zero", not a NOP encoding.)
 * ======================================================================= */
test_c_li:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    /* --- every register class across the full 5-bit rd field --- */
    T_LI_VAL ra,  0xdeadbeefdeadbeef, -19, -19, str_li_reg_ra
    T_LI_VAL t0,  0xdeadbeefdeadbeef, -19, -19, str_li_reg_t0
    T_LI_VAL s0,  0xdeadbeefdeadbeef, -19, -19, str_li_reg_s0
    T_LI_VAL a0,  0xdeadbeefdeadbeef, -19, -19, str_li_reg_a0
    T_LI_VAL a4,  0xdeadbeefdeadbeef, -19, -19, str_li_reg_a4
    T_LI_VAL s2,  0xdeadbeefdeadbeef, -19, -19, str_li_reg_s2
    T_LI_VAL s6,  0xdeadbeefdeadbeef, -19, -19, str_li_reg_s6
    T_LI_VAL s10, 0xdeadbeefdeadbeef, -19, -19, str_li_reg_s10
    T_LI_VAL t6,  0xdeadbeefdeadbeef, -19, -19, str_li_reg_t6

    /* --- every individual immediate-magnitude bit, both signs, zero
     *     (legal for C.LI, unlike C.ADDI's nzimm), and the min/max
     *     boundary. Each poisoned first: proves C.LI truly overwrites
     *     rd rather than combining with its previous contents. --- */
    T_LI_VAL t1, 0xffffffffffffffff, 0,    0,   str_li_imm_zero
    T_LI_VAL t1, 0xffffffffffffffff, 1,    1,   str_li_imm_p1
    T_LI_VAL t1, 0xffffffffffffffff, -1,   -1,  str_li_imm_m1
    T_LI_VAL t1, 0xffffffffffffffff, 2,    2,   str_li_imm_p2
    T_LI_VAL t1, 0xffffffffffffffff, -2,   -2,  str_li_imm_m2
    T_LI_VAL t1, 0xffffffffffffffff, 4,    4,   str_li_imm_p4
    T_LI_VAL t1, 0xffffffffffffffff, -4,   -4,  str_li_imm_m4
    T_LI_VAL t1, 0xffffffffffffffff, 8,    8,   str_li_imm_p8
    T_LI_VAL t1, 0xffffffffffffffff, -8,   -8,  str_li_imm_m8
    T_LI_VAL t1, 0xffffffffffffffff, 16,   16,  str_li_imm_p16
    T_LI_VAL t1, 0xffffffffffffffff, -16,  -16, str_li_imm_m16
    T_LI_VAL t1, 0xffffffffffffffff, 31,   31,  str_li_imm_max
    T_LI_VAL t1, 0xffffffffffffffff, -32,  -32, str_li_imm_min

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* T_A16SP_DELTA delta, name
 *   sp += delta; check the applied delta is exactly right; sp -= delta
 *   to undo it immediately (keeping sp valid for the rest of the
 *   routine). Cumulative drift across all deltas is caught separately
 *   by a single final restoration check. */
.macro T_A16SP_DELTA delta, name
    TEST_BEGIN \name
    mv      t2, sp
    .option rvc
    c.addi16sp sp, \delta
    .option norvc
    mv      t3, sp
    .option rvc
    c.addi16sp sp, -(\delta)
    .option norvc
    la      a0, \name
    LIX     a1, \delta
    sub     a2, t3, t2
    call    check
.endm

/* =======================================================================
 *  C.ADDI16SP : sp += nzimm  (CI format, rd fixed = sp/x2, distinct
 *               encoding from C.LUI despite sharing funct3=011; nzimm
 *               is a nonzero multiple of 16 in [-512, 496], its 6 raw
 *               bits scrambled into the encoding as imm[9|4|6|8:7|5]).
 *               No register field to sweep (rd is always sp), so the
 *               coverage here is entirely about the scrambled
 *               immediate: every individual logical bit (16, 32, 64,
 *               128, 256, and the sign bit reachable only via -512),
 *               both boundaries, and a couple of mixed patterns.
 * ======================================================================= */
test_c_addi16sp:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)
    mv      s0, sp                  /* remember true original sp */

    T_A16SP_DELTA 16,   str_a16sp_p16     /* bit 4 */
    T_A16SP_DELTA 32,   str_a16sp_p32     /* bit 5 */
    T_A16SP_DELTA 64,   str_a16sp_p64     /* bit 6 */
    T_A16SP_DELTA 128,  str_a16sp_p128    /* bit 7 */
    T_A16SP_DELTA 256,  str_a16sp_p256    /* bit 8 */
    T_A16SP_DELTA 496,  str_a16sp_pmax    /* max positive, all low bits set */
    T_A16SP_DELTA -16,  str_a16sp_m16
    T_A16SP_DELTA -32,  str_a16sp_m32
    T_A16SP_DELTA -64,  str_a16sp_m64
    T_A16SP_DELTA -128, str_a16sp_m128
    T_A16SP_DELTA -256, str_a16sp_m256

    TEST_BEGIN str_a16sp_mmin
    /* -512 is the one boundary the generic macro can't self-undo: the
     * range is asymmetric (-512..496), so -(-512)=512 doesn't fit in
     * a single instruction. Undo it in two steps (+496, then +16)
     * instead. */
    mv      t2, sp
    .option rvc
    c.addi16sp sp, -512
    .option norvc
    mv      t3, sp
    .option rvc
    c.addi16sp sp, 496
    c.addi16sp sp, 16
    .option norvc
    la      a0, str_a16sp_mmin
    LIX     a1, -512
    sub     a2, t3, t2
    call    check

    T_A16SP_DELTA 208,  str_a16sp_mix1    /* nzimm/16 = 0b001101 */
    T_A16SP_DELTA -304, str_a16sp_mix2    /* nzimm/16 = 0b101101 (two's complement) */

    TEST_BEGIN str_a16sp_restored
    /* --- catches any cumulative drift the per-delta checks above,
     *     each individually self-cancelling, could not --- */
    la      a0, str_a16sp_restored
    mv      a1, s0
    mv      a2, sp
    call    check

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* T_LUI_VAL rd, poison, imm, expect, name
 *   Poison rd first (same rationale as T_LI_VAL -- C.LUI must fully
 *   replace rd, not combine with it). rd may be a0/a1/a2. */
.macro T_LUI_VAL rd, poison, imm, expect, name
    TEST_BEGIN \name
    LIX     \rd, \poison
    .option rvc
    c.lui   \rd, (\imm & 0xfffff)   /* GNU as wants c.lui's operand in the
                                      * same 20-bit space plain lui uses
                                      * (0x00000-0xfffff), not the compact
                                      * -32..31 range -- masking a signed
                                      * imm6 to 20 bits gives the right
                                      * encodable representation either way */
    .option norvc
    mv      t2, \rd
    la      a0, \name
    LIX     a1, \expect
    mv      a2, t2
    call    check
.endm

/* =======================================================================
 *  C.LUI : rd = sign_extend64((int64_t)imm6 << 12), full 5-bit rd,
 *          rd != {x0, x2} (x2 is C.ADDI16SP's encoding instead), imm6
 *          a nonzero signed 6-bit value.
 * ======================================================================= */
test_c_lui:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    /* --- every register class across the full 5-bit rd field
     *     (x0 and x2/sp excluded -- neither appears in this list) --- */
    T_LUI_VAL ra,  0, 0x15, 0x0000000000015000, str_lui_reg_ra
    T_LUI_VAL t0,  0, 0x15, 0x0000000000015000, str_lui_reg_t0
    T_LUI_VAL s0,  0, 0x15, 0x0000000000015000, str_lui_reg_s0
    T_LUI_VAL a0,  0, 0x15, 0x0000000000015000, str_lui_reg_a0
    T_LUI_VAL a4,  0, 0x15, 0x0000000000015000, str_lui_reg_a4
    T_LUI_VAL s2,  0, 0x15, 0x0000000000015000, str_lui_reg_s2
    T_LUI_VAL s6,  0, 0x15, 0x0000000000015000, str_lui_reg_s6
    T_LUI_VAL s10, 0, 0x15, 0x0000000000015000, str_lui_reg_s10
    T_LUI_VAL t6,  0, 0x15, 0x0000000000015000, str_lui_reg_t6

    /* --- every individual immediate-magnitude bit, both signs, plus
     *     the min/max boundary; poisoned first to prove full
     *     overwrite (not combine) semantics, same as C.LI --- */
    T_LUI_VAL t1, 0xffffffffffffffff, 1,   0x0000000000001000, str_lui_imm_p1
    T_LUI_VAL t1, 0xffffffffffffffff, -1,  0xfffffffffffff000, str_lui_imm_m1
    T_LUI_VAL t1, 0xffffffffffffffff, 2,   0x0000000000002000, str_lui_imm_p2
    T_LUI_VAL t1, 0xffffffffffffffff, -2,  0xffffffffffffe000, str_lui_imm_m2
    T_LUI_VAL t1, 0xffffffffffffffff, 4,   0x0000000000004000, str_lui_imm_p4
    T_LUI_VAL t1, 0xffffffffffffffff, -4,  0xffffffffffffc000, str_lui_imm_m4
    T_LUI_VAL t1, 0xffffffffffffffff, 8,   0x0000000000008000, str_lui_imm_p8
    T_LUI_VAL t1, 0xffffffffffffffff, -8,  0xffffffffffff8000, str_lui_imm_m8
    T_LUI_VAL t1, 0xffffffffffffffff, 16,  0x0000000000010000, str_lui_imm_p16
    T_LUI_VAL t1, 0xffffffffffffffff, -16, 0xffffffffffff0000, str_lui_imm_m16
    T_LUI_VAL t1, 0xffffffffffffffff, 31,  0x000000000001f000, str_lui_imm_max
    T_LUI_VAL t1, 0xffffffffffffffff, -32, 0xfffffffffffe0000, str_lui_imm_min

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* T_SRLI_REG reg, name -- sweep every legal rd'/rs1' (x8-x15; this
 * instruction has only one register field, self-referencing, so there
 * is exactly one sweep, not a separate rd/rs1 pair). Fixed shamt=4,
 * fixed walking-bit-pattern input so a shift-amount-off-by-one or a
 * bit-lane swap would show up immediately. */
.macro T_SRLI_REG reg, name
    TEST_BEGIN \name
    .if XLEN == 64
    LIX     \reg, 0xfedcba9876543210
    .else
    LIX     \reg, 0xfedcba98
    .endif
    .option rvc
    c.srli  \reg, 4
    .option norvc
    mv      t2, \reg                /* capture before a0-a2 are reused --
                                      * reg may itself be a0/a1/a2 */
    la      a0, \name
    .if XLEN == 64
    LIX     a1, 0x0fedcba987654321
    .else
    LIX     a1, 0x0fedcba9
    .endif
    mv      a2, t2
    call    check
.endm

/* T_SRLI_SHAMT shamt, name -- sweep every individual bit of the 6-bit
 * shamt field (plus 0 and 63 boundaries and two mixed patterns), fixed
 * register s0, input = all-ones so the number of zero bits shifted in
 * from the top is exactly readable off the expected value -- and,
 * since the input's top bit is set, this also confirms the shift is
 * logical (zero-fill) and not arithmetic (which C.SRAI covers). */
.macro T_SRLI_SHAMT shamt, expect, name
    TEST_BEGIN \name
    LIX     s0, 0xffffffffffffffff
    .option rvc
    c.srli  s0, \shamt
    .option norvc
    la      a0, \name
    LIX     a1, \expect
    mv      a2, s0
    call    check
.endm

/* =======================================================================
 *  C.SRLI : rd'/rs1' >>= shamt (logical, zero-fill). CB format,
 *           single self-referencing register field in x8-x15, shamt
 *           is a 6-bit unsigned field (0-63 for RV64C).
 * ======================================================================= */
test_c_srli:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    /* --- every legal register --- */
    T_SRLI_REG s0, str_srli_reg_s0
    T_SRLI_REG s1, str_srli_reg_s1
    T_SRLI_REG a0, str_srli_reg_a0
    T_SRLI_REG a1, str_srli_reg_a1
    T_SRLI_REG a2, str_srli_reg_a2
    T_SRLI_REG a3, str_srli_reg_a3
    T_SRLI_REG a4, str_srli_reg_a4
    T_SRLI_REG a5, str_srli_reg_a5

    /* --- every individual shamt-field bit, boundaries, mixed patterns.
     *     Note: shamt=0, though permitted by the RV64C spec text, is
     *     rejected by this assembler as a reserved/illegal operand
     *     (it enforces a nonzero shift amount), so 1 stands in as the
     *     smallest tested magnitude instead. --- */
    .if XLEN == 64
    T_SRLI_SHAMT 1,  0x7fffffffffffffff, str_srli_sh1
    T_SRLI_SHAMT 2,  0x3fffffffffffffff, str_srli_sh2
    T_SRLI_SHAMT 4,  0x0fffffffffffffff, str_srli_sh4
    T_SRLI_SHAMT 8,  0x00ffffffffffffff, str_srli_sh8
    T_SRLI_SHAMT 16, 0x0000ffffffffffff, str_srli_sh16
    T_SRLI_SHAMT 32, 0x00000000ffffffff, str_srli_sh32
    T_SRLI_SHAMT 63, 0x0000000000000001, str_srli_sh63   /* max */
    T_SRLI_SHAMT 21, 0x000007ffffffffff, str_srli_sh21   /* 0b010101 */
    T_SRLI_SHAMT 42, 0x00000000003fffff, str_srli_sh42   /* 0b101010 */
    .else                           /* RV32C: 5-bit shamt */
    T_SRLI_SHAMT 1, 0x7fffffff, str_srli_sh1
    T_SRLI_SHAMT 2, 0x3fffffff, str_srli_sh2
    T_SRLI_SHAMT 4, 0x0fffffff, str_srli_sh4
    T_SRLI_SHAMT 8, 0x00ffffff, str_srli_sh8
    T_SRLI_SHAMT 16, 0x0000ffff, str_srli_sh16
    T_SRLI_SHAMT 31, 0x00000001, str_srli_sh31   /* max */
    T_SRLI_SHAMT 21, 0x000007ff, str_srli_sh21   /* 0b10101 */
    T_SRLI_SHAMT 10, 0x003fffff, str_srli_sh10   /* 0b01010 */
    .endif

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* T_SRAI_REG reg, name -- sweep every legal register (self-referencing
 * rd'/rs1' field, same as C.SRLI). Fixed shamt=4, input has its top
 * bit set so the arithmetic (sign-preserving) fill is exercised. */
.macro T_SRAI_REG reg, name
    TEST_BEGIN \name
    .if XLEN == 64
    LIX     \reg, 0xfedcba9876543210
    .else
    LIX     \reg, 0xfedcba98
    .endif
    .option rvc
    c.srai  \reg, 4
    .option norvc
    mv      t2, \reg                /* capture before a0-a2 are reused --
                                      * reg may itself be a0/a1/a2 */
    la      a0, \name
    .if XLEN == 64
    LIX     a1, 0xffedcba987654321
    .else
    LIX     a1, 0xffedcba9
    .endif
    mv      a2, t2
    call    check
.endm

/* T_SRAI_SHAMT shamt, expect, name -- sweep every individual bit of
 * the shamt field (plus max and two mixed patterns; shamt=0 is
 * skipped for the same assembler-level reason as C.SRLI). Fixed
 * register s0, input = sign bit alone, so each expected value directly
 * shows how many 1-bits get shifted in from the top. */
.macro T_SRAI_SHAMT shamt, expect, name
    TEST_BEGIN \name
    LIX     s0, INTX_MIN
    .option rvc
    c.srai  s0, \shamt
    .option norvc
    la      a0, \name
    LIX     a1, \expect
    mv      a2, s0
    call    check
.endm

/* =======================================================================
 *  C.SRAI : rd'/rs1' >>= shamt (arithmetic, sign-fill). Same CB format
 *           and register/shamt-field shape as C.SRLI; the only
 *           semantic difference is what fills in from the top, so the
 *           coverage plan mirrors C.SRLI's with the fill polarity
 *           flipped, plus one explicit check that a positive input
 *           (sign bit clear) needs no sign-extension at all.
 * ======================================================================= */
test_c_srai:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    /* --- every legal register --- */
    T_SRAI_REG s0, str_srai_reg_s0
    T_SRAI_REG s1, str_srai_reg_s1
    T_SRAI_REG a0, str_srai_reg_a0
    T_SRAI_REG a1, str_srai_reg_a1
    T_SRAI_REG a2, str_srai_reg_a2
    T_SRAI_REG a3, str_srai_reg_a3
    T_SRAI_REG a4, str_srai_reg_a4
    T_SRAI_REG a5, str_srai_reg_a5

    /* --- every individual shamt-field bit, boundary, mixed patterns --- */
    .if XLEN == 64
    T_SRAI_SHAMT 1,  0xc000000000000000, str_srai_sh1
    T_SRAI_SHAMT 2,  0xe000000000000000, str_srai_sh2
    T_SRAI_SHAMT 4,  0xf800000000000000, str_srai_sh4
    T_SRAI_SHAMT 8,  0xff80000000000000, str_srai_sh8
    T_SRAI_SHAMT 16, 0xffff800000000000, str_srai_sh16
    T_SRAI_SHAMT 32, 0xffffffff80000000, str_srai_sh32
    T_SRAI_SHAMT 63, 0xffffffffffffffff, str_srai_sh63
    T_SRAI_SHAMT 21, 0xfffffc0000000000, str_srai_sh21
    T_SRAI_SHAMT 42, 0xffffffffffe00000, str_srai_sh42
    .else                           /* RV32C: 5-bit shamt */
    T_SRAI_SHAMT 1, 0xc0000000, str_srai_sh1
    T_SRAI_SHAMT 2, 0xe0000000, str_srai_sh2
    T_SRAI_SHAMT 4, 0xf8000000, str_srai_sh4
    T_SRAI_SHAMT 8, 0xff800000, str_srai_sh8
    T_SRAI_SHAMT 16, 0xffff8000, str_srai_sh16
    T_SRAI_SHAMT 31, 0xffffffff, str_srai_sh31   /* max */
    T_SRAI_SHAMT 21, 0xfffffc00, str_srai_sh21   /* 0b10101 */
    T_SRAI_SHAMT 10, 0xffe00000, str_srai_sh10   /* 0b01010 */
    .endif

    TEST_BEGIN str_srai_positive
    /* --- positive input (sign bit clear): arithmetic shift needs no
     *     sign-extension at all, behaves exactly like C.SRLI here --- */
    LIX     s0, INTX_MAX
    .option rvc
    c.srai  s0, 4
    .option norvc
    la      a0, str_srai_positive
    LIX     a1, (INTX_MAX >> 4)
    mv      a2, s0
    call    check

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* T_ANDI_REG rd, name -- sweep every legal rd'/rs1' (fixed imm=0x0f,
 * fixed input=0x7f). */
.macro T_ANDI_REG reg, name
    TEST_BEGIN \name
    LIX     \reg, 0x7f
    .option rvc
    c.andi  \reg, 0x0f
    .option norvc
    mv      t2, \reg                /* capture before a0-a2 are reused --
                                      * reg may itself be a0/a1/a2 */
    la      a0, \name
    LIX     a1, 0x0f
    mv      a2, t2
    call    check
.endm

/* T_ANDI_IMM imm, expect, name -- sweep every individual bit of the
 * signed 6-bit immediate field (both signs), fixed rd'/rs1'=s0, fixed
 * walking-pattern input. Since the immediate is sign-extended before
 * the AND, the negative-immediate cases ("mostly ones" masks, close
 * to identity) and positive cases ("mostly zeros" masks) exercise
 * genuinely different behavior, not just a sign-flipped magnitude. */
.macro T_ANDI_IMM imm, expect, name
    TEST_BEGIN \name
    LIXT    s0, 0xfedcba9876543210
    .option rvc
    c.andi  s0, \imm
    .option norvc
    la      a0, \name
    LIXT    a1, \expect
    mv      a2, s0
    call    check
.endm

/* =======================================================================
 *  C.ANDI : rd'/rs1' &= sign_extend(imm6). CB format, same single
 *           self-referencing register field as C.SRLI/C.SRAI, x8-x15
 *           only. Unlike C.ADDI's nzimm, imm=0 is legal here (a
 *           genuine "clear to zero", not a NOP/HINT encoding).
 * ======================================================================= */
test_c_andi:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    /* --- every legal register --- */
    T_ANDI_REG s0, str_andi_reg_s0
    T_ANDI_REG s1, str_andi_reg_s1
    T_ANDI_REG a0, str_andi_reg_a0
    T_ANDI_REG a1, str_andi_reg_a1
    T_ANDI_REG a2, str_andi_reg_a2
    T_ANDI_REG a3, str_andi_reg_a3
    T_ANDI_REG a4, str_andi_reg_a4
    T_ANDI_REG a5, str_andi_reg_a5

    /* --- every individual immediate-magnitude bit, both signs, the
     *     min/max boundary, and imm=0 (legal, unlike C.ADDI) --- */
    T_ANDI_IMM -1,  0xfedcba9876543210, str_andi_imm_m1    /* identity: all-ones mask */
    T_ANDI_IMM 0,   0x0000000000000000, str_andi_imm_zero  /* clears everything */
    T_ANDI_IMM 1,   0x0000000000000000, str_andi_imm_p1
    T_ANDI_IMM 2,   0x0000000000000000, str_andi_imm_p2
    T_ANDI_IMM 4,   0x0000000000000000, str_andi_imm_p4
    T_ANDI_IMM 8,   0x0000000000000000, str_andi_imm_p8
    T_ANDI_IMM 16,  0x0000000000000010, str_andi_imm_p16
    T_ANDI_IMM 31,  0x0000000000000010, str_andi_imm_max
    T_ANDI_IMM -2,  0xfedcba9876543210, str_andi_imm_m2
    T_ANDI_IMM -4,  0xfedcba9876543210, str_andi_imm_m4
    T_ANDI_IMM -8,  0xfedcba9876543210, str_andi_imm_m8
    T_ANDI_IMM -16, 0xfedcba9876543210, str_andi_imm_m16
    T_ANDI_IMM -32, 0xfedcba9876543200, str_andi_imm_min

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  Shared macros for C.SUB / C.SUBW / C.ADDW
 *
 *  All three are CA format: a self-referencing rd'/rs1' field combined
 *  with rs2', both in x8-x15. As with C.SW/C.SD, a store-shaped
 *  aliasing problem shows up here too, but for a different reason:
 *  since rd'/rs1' is both read and written, rd'==rs2' aliasing means
 *  the single shared register's value is used as both operands *and*
 *  ends up holding the result -- for C.SUB(W) that collapses to
 *  "always 0" regardless of the operand value, which is still a
 *  meaningful thing to check, just structurally different from the
 *  general case. So, same pattern as C.SW: each sweep macro excludes
 *  its counterpart's fixed register, and one dedicated aliasing test
 *  per register fills each gap.
 * ======================================================================= */

/* T_CA_RS1 insn, reg, base, other, expect, name -- sweep the
 * rd'/rs1' field; "other" (rs2') is fixed at a4, so this must not be
 * called with reg=a4 (see the matching T_CA_ALIAS a4 test instead). */
.macro T_CA_RS1 insn, reg, base, other, expect, name
    TEST_BEGIN \name
    LIX     \reg, \base
    LIX     a4, \other
    .option rvc
    \insn   \reg, a4
    .option norvc
    mv      t2, \reg
    la      a0, \name
    LIX     a1, \expect
    mv      a2, t2
    call    check
.endm

/* T_CA_RS2 insn, reg, base, other, expect, name -- sweep rs2'; rd'/rs1'
 * is fixed at s0, so this must not be called with reg=s0 (see the
 * matching T_CA_ALIAS s0 test instead). */
.macro T_CA_RS2 insn, reg, base, other, expect, name
    TEST_BEGIN \name
    LIXT    s0, \base
    LIXT    \reg, \other
    .option rvc
    \insn   s0, \reg
    .option norvc
    la      a0, \name
    LIXT    a1, \expect
    mv      a2, s0
    call    check
.endm

/* T_CA_ALIAS insn, reg, val, expect, name -- rd'==rs1'==rs2' aliasing:
 * the one shared register is simultaneously both operands. */
.macro T_CA_ALIAS insn, reg, val, expect, name
    TEST_BEGIN \name
    LIXT    \reg, \val
    .option rvc
    \insn   \reg, \reg
    .option norvc
    mv      t2, \reg
    la      a0, \name
    LIXT    a1, \expect
    mv      a2, t2
    call    check
.endm

/* =======================================================================
 *  C.SUB : rd'/rs1' -= rs2'  (full 64-bit, no overflow/sign-extension
 *          concerns -- the register width already is the operation
 *          width).
 * ======================================================================= */
test_c_sub:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    /* --- every legal rd'/rs1' (except a4, see alias test) --- */
    T_CA_RS1 c.sub, s0, 50, 8, 42, str_sub_rs1_s0
    T_CA_RS1 c.sub, s1, 50, 8, 42, str_sub_rs1_s1
    T_CA_RS1 c.sub, a0, 50, 8, 42, str_sub_rs1_a0
    T_CA_RS1 c.sub, a1, 50, 8, 42, str_sub_rs1_a1
    T_CA_RS1 c.sub, a2, 50, 8, 42, str_sub_rs1_a2
    T_CA_RS1 c.sub, a3, 50, 8, 42, str_sub_rs1_a3
    T_CA_RS1 c.sub, a5, 50, 8, 42, str_sub_rs1_a5

    /* --- every legal rs2' (except s0, see alias test) --- */
    T_CA_RS2 c.sub, s1, 50, 8, 42, str_sub_rs2_s1
    T_CA_RS2 c.sub, a0, 50, 8, 42, str_sub_rs2_a0
    T_CA_RS2 c.sub, a1, 50, 8, 42, str_sub_rs2_a1
    T_CA_RS2 c.sub, a2, 50, 8, 42, str_sub_rs2_a2
    T_CA_RS2 c.sub, a3, 50, 8, 42, str_sub_rs2_a3
    T_CA_RS2 c.sub, a4, 50, 8, 42, str_sub_rs2_a4
    T_CA_RS2 c.sub, a5, 50, 8, 42, str_sub_rs2_a5

    /* --- rd'==rs1'==rs2' aliasing: always 0, regardless of value --- */
    T_CA_ALIAS c.sub, s0, 12345, 0, str_sub_alias_s0
    T_CA_ALIAS c.sub, a4, 67890, 0, str_sub_alias_a4

    /* --- data patterns: 64-bit underflow wrap and bit-pattern checks --- */
    T_CA_RS2 c.sub, a4, 0x0000000000000000, 0x0000000000000000, 0x0000000000000000, str_sub_val_zero
    T_CA_RS2 c.sub, a4, 0x0000000000000000, 0x0000000000000001, 0xffffffffffffffff, str_sub_val_underflow
    T_CA_RS2 c.sub, a4, INTX_MIN, 1, INTX_MAX, str_sub_val_minwrap
    T_CA_RS2 c.sub, a4, 0xffffffffffffffff, 0xffffffffffffffff, 0x0000000000000000, str_sub_val_selfequal
    T_CA_RS2 c.sub, a4, 0xaaaaaaaaaaaaaaaa, 0x5555555555555555, 0x5555555555555555, str_sub_val_alt1
    T_CA_RS2 c.sub, a4, 0x5555555555555555, 0xaaaaaaaaaaaaaaaa, 0xaaaaaaaaaaaaaaab, str_sub_val_alt2

    /* --- invariant: C.SUB must not modify rs2' --- */
    TEST_BEGIN str_sub_rs2_preserved
    LIX     s0, 100
    LIX     a4, 30
    mv      t1, a4
    .option rvc
    c.sub   s0, a4
    .option norvc
    la      a0, str_sub_rs2_preserved
    mv      a1, t1
    mv      a2, a4
    call    check

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  C.AND : rd'/rs1' &= rs2'. Same CA format/register shape as C.SUB;
 *          reuses T_CA_RS1/T_CA_RS2/T_CA_ALIAS. Aliasing (rd==rs2)
 *          collapses to "reg & reg = reg" (identity), unlike C.SUB's
 *          "always 0" -- a genuinely different, operation-specific
 *          case worth checking explicitly.
 * ======================================================================= */
test_c_and:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    T_CA_RS1 c.and, s0, 0x7f, 0x0f, 0x0f, str_and_rs1_s0
    T_CA_RS1 c.and, s1, 0x7f, 0x0f, 0x0f, str_and_rs1_s1
    T_CA_RS1 c.and, a0, 0x7f, 0x0f, 0x0f, str_and_rs1_a0
    T_CA_RS1 c.and, a1, 0x7f, 0x0f, 0x0f, str_and_rs1_a1
    T_CA_RS1 c.and, a2, 0x7f, 0x0f, 0x0f, str_and_rs1_a2
    T_CA_RS1 c.and, a3, 0x7f, 0x0f, 0x0f, str_and_rs1_a3
    T_CA_RS1 c.and, a5, 0x7f, 0x0f, 0x0f, str_and_rs1_a5

    T_CA_RS2 c.and, s1, 0x7f, 0x0f, 0x0f, str_and_rs2_s1
    T_CA_RS2 c.and, a0, 0x7f, 0x0f, 0x0f, str_and_rs2_a0
    T_CA_RS2 c.and, a1, 0x7f, 0x0f, 0x0f, str_and_rs2_a1
    T_CA_RS2 c.and, a2, 0x7f, 0x0f, 0x0f, str_and_rs2_a2
    T_CA_RS2 c.and, a3, 0x7f, 0x0f, 0x0f, str_and_rs2_a3
    T_CA_RS2 c.and, a4, 0x7f, 0x0f, 0x0f, str_and_rs2_a4
    T_CA_RS2 c.and, a5, 0x7f, 0x0f, 0x0f, str_and_rs2_a5

    /* --- rd==rs1==rs2 aliasing: reg & reg = reg (identity) --- */
    T_CA_ALIAS c.and, s0, 0x123456789abcdef0, 0x123456789abcdef0, str_and_alias_s0
    T_CA_ALIAS c.and, a4, 0x123456789abcdef0, 0x123456789abcdef0, str_and_alias_a4

    /* --- data patterns --- */
    T_CA_RS2 c.and, a4, 0xffffffffffffffff, 0xfedcba9876543210, 0xfedcba9876543210, str_and_val_identity
    T_CA_RS2 c.and, a4, 0xfedcba9876543210, 0x0000000000000000, 0x0000000000000000, str_and_val_zero
    T_CA_RS2 c.and, a4, 0xaaaaaaaaaaaaaaaa, 0x5555555555555555, 0x0000000000000000, str_and_val_complementary
    T_CA_RS2 c.and, a4, 0xfedcba9876543210, 0x123456789abcdef0, 0x1214121812141210, str_and_val_walking

    /* --- invariant: C.AND must not modify rs2' --- */
    TEST_BEGIN str_and_rs2_preserved
    LIX     s0, 0xff
    LIX     a4, 0x1c
    mv      t1, a4
    .option rvc
    c.and   s0, a4
    .option norvc
    la      a0, str_and_rs2_preserved
    mv      a1, t1
    mv      a2, a4
    call    check

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  C.XOR : rd'/rs1' ^= rs2'. Same CA format/register shape as C.SUB.
 *          Aliasing (rd==rs2) collapses to "reg ^ reg = 0", same shape
 *          as C.SUB's self-op case but for a different reason (XOR
 *          identity vs. subtraction identity).
 * ======================================================================= */
test_c_xor:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    T_CA_RS1 c.xor, s0, 0xff, 0x0f, 0xf0, str_xor_rs1_s0
    T_CA_RS1 c.xor, s1, 0xff, 0x0f, 0xf0, str_xor_rs1_s1
    T_CA_RS1 c.xor, a0, 0xff, 0x0f, 0xf0, str_xor_rs1_a0
    T_CA_RS1 c.xor, a1, 0xff, 0x0f, 0xf0, str_xor_rs1_a1
    T_CA_RS1 c.xor, a2, 0xff, 0x0f, 0xf0, str_xor_rs1_a2
    T_CA_RS1 c.xor, a3, 0xff, 0x0f, 0xf0, str_xor_rs1_a3
    T_CA_RS1 c.xor, a5, 0xff, 0x0f, 0xf0, str_xor_rs1_a5

    T_CA_RS2 c.xor, s1, 0xff, 0x0f, 0xf0, str_xor_rs2_s1
    T_CA_RS2 c.xor, a0, 0xff, 0x0f, 0xf0, str_xor_rs2_a0
    T_CA_RS2 c.xor, a1, 0xff, 0x0f, 0xf0, str_xor_rs2_a1
    T_CA_RS2 c.xor, a2, 0xff, 0x0f, 0xf0, str_xor_rs2_a2
    T_CA_RS2 c.xor, a3, 0xff, 0x0f, 0xf0, str_xor_rs2_a3
    T_CA_RS2 c.xor, a4, 0xff, 0x0f, 0xf0, str_xor_rs2_a4
    T_CA_RS2 c.xor, a5, 0xff, 0x0f, 0xf0, str_xor_rs2_a5

    /* --- rd==rs1==rs2 aliasing: reg ^ reg = 0, regardless of value --- */
    T_CA_ALIAS c.xor, s0, 0x123456789abcdef0, 0, str_xor_alias_s0
    T_CA_ALIAS c.xor, a4, 0x123456789abcdef0, 0, str_xor_alias_a4

    /* --- data patterns --- */
    T_CA_RS2 c.xor, a4, 0xfedcba9876543210, 0x0000000000000000, 0xfedcba9876543210, str_xor_val_identity
    T_CA_RS2 c.xor, a4, 0xffffffffffffffff, 0xfedcba9876543210, 0x0123456789abcdef, str_xor_val_complement
    T_CA_RS2 c.xor, a4, 0xaaaaaaaaaaaaaaaa, 0x5555555555555555, 0xffffffffffffffff, str_xor_val_complementary
    T_CA_RS2 c.xor, a4, 0xfedcba9876543210, 0x123456789abcdef0, 0xece8ece0ece8ece0, str_xor_val_walking

    /* --- invariant: C.XOR must not modify rs2' --- */
    TEST_BEGIN str_xor_rs2_preserved
    LIX     s0, 0xff
    LIX     a4, 0x0f
    mv      t1, a4
    .option rvc
    c.xor   s0, a4
    .option norvc
    la      a0, str_xor_rs2_preserved
    mv      a1, t1
    mv      a2, a4
    call    check

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  C.OR : rd'/rs1' |= rs2'. Same CA format/register shape as C.SUB.
 *         Aliasing (rd==rs2) collapses to "reg | reg = reg" (identity,
 *         same shape as C.AND's self-op case but for OR's identity).
 * ======================================================================= */
test_c_or:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    T_CA_RS1 c.or, s0, 0xf0, 0x0f, 0xff, str_or_rs1_s0
    T_CA_RS1 c.or, s1, 0xf0, 0x0f, 0xff, str_or_rs1_s1
    T_CA_RS1 c.or, a0, 0xf0, 0x0f, 0xff, str_or_rs1_a0
    T_CA_RS1 c.or, a1, 0xf0, 0x0f, 0xff, str_or_rs1_a1
    T_CA_RS1 c.or, a2, 0xf0, 0x0f, 0xff, str_or_rs1_a2
    T_CA_RS1 c.or, a3, 0xf0, 0x0f, 0xff, str_or_rs1_a3
    T_CA_RS1 c.or, a5, 0xf0, 0x0f, 0xff, str_or_rs1_a5

    T_CA_RS2 c.or, s1, 0xf0, 0x0f, 0xff, str_or_rs2_s1
    T_CA_RS2 c.or, a0, 0xf0, 0x0f, 0xff, str_or_rs2_a0
    T_CA_RS2 c.or, a1, 0xf0, 0x0f, 0xff, str_or_rs2_a1
    T_CA_RS2 c.or, a2, 0xf0, 0x0f, 0xff, str_or_rs2_a2
    T_CA_RS2 c.or, a3, 0xf0, 0x0f, 0xff, str_or_rs2_a3
    T_CA_RS2 c.or, a4, 0xf0, 0x0f, 0xff, str_or_rs2_a4
    T_CA_RS2 c.or, a5, 0xf0, 0x0f, 0xff, str_or_rs2_a5

    /* --- rd==rs1==rs2 aliasing: reg | reg = reg (identity) --- */
    T_CA_ALIAS c.or, s0, 0x123456789abcdef0, 0x123456789abcdef0, str_or_alias_s0
    T_CA_ALIAS c.or, a4, 0x123456789abcdef0, 0x123456789abcdef0, str_or_alias_a4

    /* --- data patterns --- */
    T_CA_RS2 c.or, a4, 0xfedcba9876543210, 0x0000000000000000, 0xfedcba9876543210, str_or_val_identity
    T_CA_RS2 c.or, a4, 0xfedcba9876543210, 0xffffffffffffffff, 0xffffffffffffffff, str_or_val_allones
    T_CA_RS2 c.or, a4, 0xaaaaaaaaaaaaaaaa, 0x5555555555555555, 0xffffffffffffffff, str_or_val_complementary
    T_CA_RS2 c.or, a4, 0xfedcba9876543210, 0x123456789abcdef0, 0xfefcfef8fefcfef0, str_or_val_walking

    /* --- invariant: C.OR must not modify rs2' --- */
    TEST_BEGIN str_or_rs2_preserved
    LIX     s0, 0xf0
    LIX     a4, 0x0f
    mv      t1, a4
    .option rvc
    c.or    s0, a4
    .option norvc
    la      a0, str_or_rs2_preserved
    mv      a1, t1
    mv      a2, a4
    call    check

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  C.SUBW : rd'/rs1' = sign_extend32(rd'[31:0] - rs2'[31:0]). Like
 *           C.ADDIW, the arithmetic happens on the low 32 bits only,
 *           with the result sign-extended -- and, since there are two
 *           register operands here instead of one, garbage upper bits
 *           can leak in from *either* rd' or rs2', not just one place.
 * ======================================================================= */
    .if XLEN == 64                  /* RV64C-only */
test_c_subw:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    T_CA_RS1 c.subw, s0, 50, 8, 42, str_subw_rs1_s0
    T_CA_RS1 c.subw, s1, 50, 8, 42, str_subw_rs1_s1
    T_CA_RS1 c.subw, a0, 50, 8, 42, str_subw_rs1_a0
    T_CA_RS1 c.subw, a1, 50, 8, 42, str_subw_rs1_a1
    T_CA_RS1 c.subw, a2, 50, 8, 42, str_subw_rs1_a2
    T_CA_RS1 c.subw, a3, 50, 8, 42, str_subw_rs1_a3
    T_CA_RS1 c.subw, a5, 50, 8, 42, str_subw_rs1_a5

    T_CA_RS2 c.subw, s1, 50, 8, 42, str_subw_rs2_s1
    T_CA_RS2 c.subw, a0, 50, 8, 42, str_subw_rs2_a0
    T_CA_RS2 c.subw, a1, 50, 8, 42, str_subw_rs2_a1
    T_CA_RS2 c.subw, a2, 50, 8, 42, str_subw_rs2_a2
    T_CA_RS2 c.subw, a3, 50, 8, 42, str_subw_rs2_a3
    T_CA_RS2 c.subw, a4, 50, 8, 42, str_subw_rs2_a4
    T_CA_RS2 c.subw, a5, 50, 8, 42, str_subw_rs2_a5

    T_CA_ALIAS c.subw, s0, 12345, 0, str_subw_alias_s0
    T_CA_ALIAS c.subw, a4, 67890, 0, str_subw_alias_a4

    /* --- 32-bit underflow/overflow and sign extension --- */
    T_CA_RS2 c.subw, a4, 0x0000000000000000, 0x0000000000000001, 0xffffffffffffffff, str_subw_underflow
    T_CA_RS2 c.subw, a4, 0x0000000080000000, 0x0000000000000001, 0x000000007fffffff, str_subw_minwrap
    T_CA_RS2 c.subw, a4, 0x000000007fffffff, 0x00000000ffffffff, 0xffffffff80000000, str_subw_overflow_neg

    /* --- garbage upper 32 bits, on rd' and on rs2' independently,
     *     must both be discarded --- */
    T_CA_RS1 c.subw, s0, 0xdeadbeef00000005, 3, 2, str_subw_rd_garbage_upper
    T_CA_RS2 c.subw, a4, 5, 0xcafebabe00000003, 2, str_subw_rs2_garbage_upper

    /* --- invariant: C.SUBW must not modify rs2' --- */
    TEST_BEGIN str_subw_rs2_preserved
    LIX     s0, 100
    LIX     a4, 30
    mv      t1, a4
    .option rvc
    c.subw  s0, a4
    .option norvc
    la      a0, str_subw_rs2_preserved
    mv      a1, t1
    mv      a2, a4
    call    check

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret
    .endif

/* =======================================================================
 *  C.ADDW : rd'/rs1' = sign_extend32(rd'[31:0] + rs2'[31:0]).
 * ======================================================================= */
    .if XLEN == 64                  /* RV64C-only */
test_c_addw:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    T_CA_RS1 c.addw, s0, 50, 8, 58, str_addw_rs1_s0
    T_CA_RS1 c.addw, s1, 50, 8, 58, str_addw_rs1_s1
    T_CA_RS1 c.addw, a0, 50, 8, 58, str_addw_rs1_a0
    T_CA_RS1 c.addw, a1, 50, 8, 58, str_addw_rs1_a1
    T_CA_RS1 c.addw, a2, 50, 8, 58, str_addw_rs1_a2
    T_CA_RS1 c.addw, a3, 50, 8, 58, str_addw_rs1_a3
    T_CA_RS1 c.addw, a5, 50, 8, 58, str_addw_rs1_a5

    T_CA_RS2 c.addw, s1, 50, 8, 58, str_addw_rs2_s1
    T_CA_RS2 c.addw, a0, 50, 8, 58, str_addw_rs2_a0
    T_CA_RS2 c.addw, a1, 50, 8, 58, str_addw_rs2_a1
    T_CA_RS2 c.addw, a2, 50, 8, 58, str_addw_rs2_a2
    T_CA_RS2 c.addw, a3, 50, 8, 58, str_addw_rs2_a3
    T_CA_RS2 c.addw, a4, 50, 8, 58, str_addw_rs2_a4
    T_CA_RS2 c.addw, a5, 50, 8, 58, str_addw_rs2_a5

    /* --- rd'==rs1'==rs2' aliasing: reg = 2*reg (32-bit, sign-extended) --- */
    T_CA_ALIAS c.addw, s0, 0x40000000, 0xffffffff80000000, str_addw_alias_s0
    T_CA_ALIAS c.addw, a4, 0x40000000, 0xffffffff80000000, str_addw_alias_a4

    /* --- 32-bit overflow/underflow and sign extension --- */
    T_CA_RS2 c.addw, a4, 0x000000007fffffff, 0x0000000000000001, 0xffffffff80000000, str_addw_overflow_neg
    T_CA_RS2 c.addw, a4, 0x00000000ffffffff, 0x0000000000000001, 0x0000000000000000, str_addw_wrap_zero
    T_CA_RS2 c.addw, a4, 0x0000000080000000, 0x00000000ffffffff, 0x000000007fffffff, str_addw_underflow

    /* --- garbage upper 32 bits, on rd' and on rs2' independently --- */
    T_CA_RS1 c.addw, s0, 0xdeadbeef00000005, 3, 8, str_addw_rd_garbage_upper
    T_CA_RS2 c.addw, a4, 5, 0xcafebabe00000003, 8, str_addw_rs2_garbage_upper

    /* --- invariant: C.ADDW must not modify rs2' --- */
    TEST_BEGIN str_addw_rs2_preserved
    LIX     s0, 100
    LIX     a4, 30
    mv      t1, a4
    .option rvc
    c.addw  s0, a4
    .option norvc
    la      a0, str_addw_rs2_preserved
    mv      a1, t1
    mv      a2, a4
    call    check

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret
    .endif

/* T_J_FWD dist, name -- unconditional forward jump of exactly "dist"
 * bytes (even, >=4). Structure: c.j(2) + c.li poison(2) + N c.nop
 * fillers(2N), landing exactly on the label after all of it, i.e.
 * dist = 4 + 2N. The poison sits immediately after the jump (not
 * buried in the filler run) so any decode error that lands even
 * slightly short is very likely to hit it rather than coincidentally
 * land on a harmless c.nop. */
.macro T_J_FWD dist, name
    TEST_BEGIN \name
    LIX     s2, 0
    .option rvc
    c.j     1f
    c.li    s2, -1                  /* poison: only hit if C.J landed wrong */
    .rept (\dist - 4) / 2
    c.nop
    .endr
1:
    .option norvc
    la      a0, \name
    LIX     a1, 0
    mv      a2, s2
    call    check
.endm

/* T_J_BWD dist, name -- unconditional backward jump of exactly "dist"
 * bytes (even, >=6). Jumps ahead first (plain 4-byte jal, not under
 * test) to reach the filler run without falling into the target
 * linearly, then the real C.J jumps back over that filler run to the
 * success marker. dist = 6 + 2N (2 for the c.li marker, 4 for the
 * bookkeeping jal, 2N for N c.nop fillers). */
.macro T_J_BWD dist, name
    TEST_BEGIN \name
    LIX     s2, 0
    j       5f
4:
    .option rvc
    c.li    s2, 1                   /* success marker: the true target */
    .option norvc
    j       6f
5:
    .option rvc
    .rept (\dist - 6) / 2
    c.nop
    .endr
    c.j     4b
    .option norvc
    LIX     s2, 99                  /* poison: only hit if C.J landed wrong */
6:
    la      a0, \name
    LIX     a1, 1
    mv      a2, s2
    call    check
.endm

/* =======================================================================
 *  C.J : CJ format, no register field at all (unconditional, does not
 *        link ra -- that's C.JALR's job) -- so unlike every other
 *        instruction in this suite, there is no register axis to
 *        sweep. The 11-bit signed byte offset is the *only* thing to
 *        test, and it's the single most heavily scrambled immediate
 *        encoding in all of RVC (imm[11|4|9:8|10|6|7|3:1|5]): every
 *        individual magnitude bit gets its own forward and backward
 *        jump, built with the same discipline the C.BEQZ/C.BNEZ
 *        near-max cases required -- every distance here was confirmed
 *        via objdump to actually land as a genuine 2-byte c.j, not a
 *        silently-widened jal, before being relied on.
 * ======================================================================= */
test_c_j:
    TEST_BEGIN str_j_min
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    /* --- minimum legal distance: jumps to literally the very next
     *     instruction. There's no room for a poison at this size (the
     *     jump itself already fills the whole 2-byte gap), so this
     *     only confirms it doesn't crash/hang and execution continues
     *     with sane register state. --- */
    LIX     s2, 0
    .option rvc
    c.j     1f
1:
    .option norvc
    la      a0, str_j_min
    LIX     a1, 0
    mv      a2, s2
    call    check

    /* --- every individual forward offset-field bit --- */
    T_J_FWD 4,    str_j_fwd4
    T_J_FWD 8,    str_j_fwd8
    T_J_FWD 16,   str_j_fwd16
    T_J_FWD 32,   str_j_fwd32
    T_J_FWD 64,   str_j_fwd64
    T_J_FWD 128,  str_j_fwd128
    T_J_FWD 256,  str_j_fwd256
    T_J_FWD 512,  str_j_fwd512
    T_J_FWD 1024, str_j_fwd1024
    T_J_FWD 2044, str_j_fwdmax    /* near-max forward (true max is +2046) */

    /* --- every individual backward offset-field bit --- */
    T_J_BWD 8,    str_j_bwd8
    T_J_BWD 16,   str_j_bwd16
    T_J_BWD 32,   str_j_bwd32
    T_J_BWD 64,   str_j_bwd64
    T_J_BWD 128,  str_j_bwd128
    T_J_BWD 256,  str_j_bwd256
    T_J_BWD 512,  str_j_bwd512
    T_J_BWD 1024, str_j_bwd1024
    T_J_BWD 2044, str_j_bwdmax    /* near-max backward (true min is -2048) */

    TEST_BEGIN str_j_loop
    /* --- repeated use as a loop's "continue" edge: a real backward
     *     jump exercised on every iteration but one, not just a
     *     single one-shot distance --- */
    LIX     s0, 0                   /* iteration counter */
2:
    addi    s0, s0, 1
    LIX     t0, 4
    beq     s0, t0, 3f              /* plain beq: not the instruction under test */
    .option rvc
    c.j     2b
    .option norvc
3:
    la      a0, str_j_loop
    LIX     a1, 4
    mv      a2, s0
    call    check

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

    .if XLEN == 32                  /* C.JAL is RV32C-only */
/* =======================================================================
 *  C.JAL : CJ format, RV32C only -- on RV64C the same encoding is
 *          C.ADDIW. Exactly C.J (same scrambled 11-bit offset,
 *          imm[11|4|9:8|10|6|7|3:1|5]) plus a link: ra = the address of
 *          the C.JAL + 2 (not + 4 as for JAL -- the link is the address
 *          of the *next* instruction, and a compressed one is 2 bytes).
 *
 *  So the coverage mirrors C.J's distance for distance (built the same
 *  way, with the same one-slot safety margin at the +-2046/-2048
 *  boundary -- see the README's note on relaxation) and adds a link
 *  check after every jump. The link is captured into s4 immediately,
 *  since the first check() call overwrites ra.
 * ======================================================================= */

/* T_CJAL_FWD dist, name, lname -- forward, as T_J_FWD, plus the link. */
.macro T_CJAL_FWD dist, name, lname
    TEST_BEGIN \name
    LIX     s2, 0
    .option rvc
7:  c.jal   1f
    c.li    s2, -1                  /* poison: only hit if C.JAL landed wrong */
    .rept (\dist - 4) / 2
    c.nop
    .endr
1:
    .option norvc
    mv      s4, ra
    la      a0, \name
    LIX     a1, 0
    mv      a2, s2
    call    check
    TEST_BEGIN \lname
    la      a1, 7b
    addi    a1, a1, 2
    la      a0, \lname
    mv      a2, s4
    call    check
.endm

/* T_CJAL_BWD dist, name, lname -- backward, as T_J_BWD, plus the link. */
.macro T_CJAL_BWD dist, name, lname
    TEST_BEGIN \name
    LIX     s2, 0
    j       5f
4:
    .option rvc
    c.li    s2, 1                   /* success marker: the true target */
    .option norvc
    j       6f
5:
    .option rvc
    .rept (\dist - 6) / 2
    c.nop
    .endr
7:  c.jal   4b
    .option norvc
    LIX     s2, 99                  /* poison: only hit if C.JAL landed wrong */
6:
    mv      s4, ra
    la      a0, \name
    LIX     a1, 1
    mv      a2, s2
    call    check
    TEST_BEGIN \lname
    la      a1, 7b
    addi    a1, a1, 2
    la      a0, \lname
    mv      a2, s4
    call    check
.endm

test_c_jal:
    TEST_BEGIN str_cjal_min_link
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    /* --- minimum distance: to the very next instruction; only the link
     *     is observable --- */
    .option rvc
7:  c.jal   1f
1:
    .option norvc
    mv      s4, ra
    la      a1, 7b
    addi    a1, a1, 2
    la      a0, str_cjal_min_link
    mv      a2, s4
    call    check

    /* --- every individual forward offset-field bit --- */
    T_CJAL_FWD 4,    str_cjal_fwd4,    str_cjal_fwd4_link
    T_CJAL_FWD 8,    str_cjal_fwd8,    str_cjal_fwd8_link
    T_CJAL_FWD 16,   str_cjal_fwd16,   str_cjal_fwd16_link
    T_CJAL_FWD 32,   str_cjal_fwd32,   str_cjal_fwd32_link
    T_CJAL_FWD 64,   str_cjal_fwd64,   str_cjal_fwd64_link
    T_CJAL_FWD 128,  str_cjal_fwd128,  str_cjal_fwd128_link
    T_CJAL_FWD 256,  str_cjal_fwd256,  str_cjal_fwd256_link
    T_CJAL_FWD 512,  str_cjal_fwd512,  str_cjal_fwd512_link
    T_CJAL_FWD 1024, str_cjal_fwd1024, str_cjal_fwd1024_link
    T_CJAL_FWD 2044, str_cjal_fwdmax,  str_cjal_fwdmax_link   /* near-max (true max +2046) */

    /* --- every individual backward offset-field bit --- */
    T_CJAL_BWD 8,    str_cjal_bwd8,    str_cjal_bwd8_link
    T_CJAL_BWD 16,   str_cjal_bwd16,   str_cjal_bwd16_link
    T_CJAL_BWD 32,   str_cjal_bwd32,   str_cjal_bwd32_link
    T_CJAL_BWD 64,   str_cjal_bwd64,   str_cjal_bwd64_link
    T_CJAL_BWD 128,  str_cjal_bwd128,  str_cjal_bwd128_link
    T_CJAL_BWD 256,  str_cjal_bwd256,  str_cjal_bwd256_link
    T_CJAL_BWD 512,  str_cjal_bwd512,  str_cjal_bwd512_link
    T_CJAL_BWD 1024, str_cjal_bwd1024, str_cjal_bwd1024_link
    T_CJAL_BWD 2044, str_cjal_bwdmax,  str_cjal_bwdmax_link   /* near-max (true min -2048) */

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret
    .endif                          /* XLEN == 32: C.JAL */

/* =======================================================================
 *  C.BEQZ / C.BNEZ : CB format, rs1' restricted to x8-x15 (no rd -- these
 *  are pure conditional branches), 9-bit signed byte offset (always
 *  even; encoded as 8 scrambled bits scaled by 2), range [-256, 254].
 *
 *  Neither instruction has an "immediate value" to sweep the way an
 *  ALU op does -- there's no meaningful numeric payload beyond taken/
 *  not-taken. What's worth exercising instead:
 *    - every legal rs1' register, in both the taken and not-taken
 *      condition, to catch a wrong bit in the 3-bit register decode
 *      (a bug that branches on the wrong register would otherwise be
 *      invisible if only one register were ever tested)
 *    - a genuine backward branch, evaluated repeatedly in a small loop
 *      (forward-only coverage would miss a sign-handling bug in the
 *      offset decode)
 *    - the true encoding boundaries, +254 (max forward) and -256 (max
 *      backward) -- the only offsets that exercise every immediate
 *      bit being 1 simultaneously. These are built from a "poison"
 *      instruction placed so it's skipped when the branch is correctly
 *      taken and hit when it (buggily) isn't; the byte counts were
 *      verified with objdump against a standalone probe before use,
 *      since getting them wrong by even 2 bytes would either silently
 *      widen the instruction to an uncompressed 4-byte branch (a
 *      different bug for a different instruction) or land 2 bytes
 *      short/long of the true boundary.
 * ======================================================================= */

.macro T_BEQZ_TAKEN reg, name
    TEST_BEGIN \name
    LIX     \reg, 0
    LIX     s5, 0
    .option rvc
    c.beqz  \reg, 1f
    .option norvc
    LIX     s5, 99                  /* poison: only hit if NOT taken */
1:
    la      a0, \name
    LIX     a1, 0
    mv      a2, s5
    call    check
.endm

.macro T_BEQZ_NOTTAKEN reg, name
    TEST_BEGIN \name
    LIX     \reg, 0xdeadbeef
    LIX     s5, 0
    .option rvc
    c.beqz  \reg, 1f
    .option norvc
    LIX     s5, 1                   /* expected: falls through, hits this */
1:
    la      a0, \name
    LIX     a1, 1
    mv      a2, s5
    call    check
.endm

test_c_beqz:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    /* --- every legal register, taken (reg == 0) --- */
    T_BEQZ_TAKEN s0, str_beqz_taken_s0
    T_BEQZ_TAKEN s1, str_beqz_taken_s1
    T_BEQZ_TAKEN a0, str_beqz_taken_a0
    T_BEQZ_TAKEN a1, str_beqz_taken_a1
    T_BEQZ_TAKEN a2, str_beqz_taken_a2
    T_BEQZ_TAKEN a3, str_beqz_taken_a3
    T_BEQZ_TAKEN a4, str_beqz_taken_a4
    T_BEQZ_TAKEN a5, str_beqz_taken_a5

    /* --- every legal register, not taken (reg != 0) --- */
    T_BEQZ_NOTTAKEN s0, str_beqz_nottaken_s0
    T_BEQZ_NOTTAKEN s1, str_beqz_nottaken_s1
    T_BEQZ_NOTTAKEN a0, str_beqz_nottaken_a0
    T_BEQZ_NOTTAKEN a1, str_beqz_nottaken_a1
    T_BEQZ_NOTTAKEN a2, str_beqz_nottaken_a2
    T_BEQZ_NOTTAKEN a3, str_beqz_nottaken_a3
    T_BEQZ_NOTTAKEN a4, str_beqz_nottaken_a4
    T_BEQZ_NOTTAKEN a5, str_beqz_nottaken_a5

    TEST_BEGIN str_beqz_loop
    /* --- backward branch, evaluated repeatedly: loop "while not done",
     *     where "done" is set on the 3rd iteration --- */
    LIX     s0, 0                   /* not-done flag */
    LIX     s5, 0                   /* iteration counter */
    LIX     s6, 3                   /* target iteration count */
1:
    addi    s5, s5, 1
    bne     s5, s6, 2f
    LIX     s0, 1                   /* reached target: mark done */
2:
    .option rvc
    c.beqz  s0, 1b                  /* loop while s0 == 0 (not done) */
    .option norvc
    la      a0, str_beqz_loop
    LIX     a1, 3
    mv      a2, s5
    call    check

    TEST_BEGIN str_beqz_maxfwd
    /* --- max forward offset: branch skips filler C.NOPs plus a
     *     trailing poison instruction. Note: 124 fillers is what the
     *     arithmetic for the true +254 boundary calls for, but at
     *     that exact knife-edge this assembler's branch relaxation
     *     converges to the wrong fixed point in this file's context
     *     (confirmed empirically via objdump -- it silently widens to
     *     a 4-byte `beq`, defeating the point of the test) even though
     *     an otherwise-identical minimal reproduction assembles fine.
     *     123 fillers (+252) lands one nop short of the true edge but
     *     reliably stays inside the safe/unambiguous relaxation
     *     region, confirmed compressed via objdump before relying on
     *     it here. --- */
    LIX     s0, 0
    LIX     s5, 0
    .option rvc
    c.beqz  s0, 3f
    .rept 123
    c.nop
    .endr
    .option norvc
    LIX     s5, 99                  /* poison: only hit if NOT taken */
3:
    la      a0, str_beqz_maxfwd
    LIX     a1, 0
    mv      a2, s5
    call    check

    TEST_BEGIN str_beqz_maxbwd
    /* --- max backward offset (-256): jump past the target block on
     *     the way down, run 124 filler C.NOPs, then branch back --- */
    LIX     s0, 0
    LIX     s5, 0
    j       5f
4:
    LIX     s5, 1                   /* success marker */
    j       6f
5:
    .option rvc
    .rept 124
    c.nop
    .endr
    c.beqz  s0, 4b
    .option norvc
    LIX     s5, 99                  /* poison: only hit if NOT taken */
6:
    la      a0, str_beqz_maxbwd
    LIX     a1, 1
    mv      a2, s5
    call    check

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

.macro T_BNEZ_TAKEN reg, name
    TEST_BEGIN \name
    LIX     \reg, 0xdeadbeef
    LIX     s5, 0
    .option rvc
    c.bnez  \reg, 1f
    .option norvc
    LIX     s5, 99
1:
    la      a0, \name
    LIX     a1, 0
    mv      a2, s5
    call    check
.endm

.macro T_BNEZ_NOTTAKEN reg, name
    TEST_BEGIN \name
    LIX     \reg, 0
    LIX     s5, 0
    .option rvc
    c.bnez  \reg, 1f
    .option norvc
    LIX     s5, 1
1:
    la      a0, \name
    LIX     a1, 1
    mv      a2, s5
    call    check
.endm

test_c_bnez:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    /* --- every legal register, taken (reg != 0) --- */
    T_BNEZ_TAKEN s0, str_bnez_taken_s0
    T_BNEZ_TAKEN s1, str_bnez_taken_s1
    T_BNEZ_TAKEN a0, str_bnez_taken_a0
    T_BNEZ_TAKEN a1, str_bnez_taken_a1
    T_BNEZ_TAKEN a2, str_bnez_taken_a2
    T_BNEZ_TAKEN a3, str_bnez_taken_a3
    T_BNEZ_TAKEN a4, str_bnez_taken_a4
    T_BNEZ_TAKEN a5, str_bnez_taken_a5

    /* --- every legal register, not taken (reg == 0) --- */
    T_BNEZ_NOTTAKEN s0, str_bnez_nottaken_s0
    T_BNEZ_NOTTAKEN s1, str_bnez_nottaken_s1
    T_BNEZ_NOTTAKEN a0, str_bnez_nottaken_a0
    T_BNEZ_NOTTAKEN a1, str_bnez_nottaken_a1
    T_BNEZ_NOTTAKEN a2, str_bnez_nottaken_a2
    T_BNEZ_NOTTAKEN a3, str_bnez_nottaken_a3
    T_BNEZ_NOTTAKEN a4, str_bnez_nottaken_a4
    T_BNEZ_NOTTAKEN a5, str_bnez_nottaken_a5

    TEST_BEGIN str_bnez_loop
    /* --- backward branch, evaluated repeatedly: natural countdown
     *     loop, "while nonzero, decrement" --- */
    LIX     s0, 5                   /* loop count */
    LIX     s5, 0                   /* iteration counter */
1:
    addi    s5, s5, 1
    addi    s0, s0, -1
    .option rvc
    c.bnez  s0, 1b
    .option norvc
    la      a0, str_bnez_loop
    LIX     a1, 5
    mv      a2, s5
    call    check

    TEST_BEGIN str_bnez_maxfwd
    /* --- max forward offset: see the identical BEQZ case above for
     *     why 123 fillers (+252), not the theoretical 124 (+254). --- */
    LIX     s0, 0xdeadbeef
    LIX     s5, 0
    .option rvc
    c.bnez  s0, 3f
    .rept 123
    c.nop
    .endr
    .option norvc
    LIX     s5, 99
3:
    la      a0, str_bnez_maxfwd
    LIX     a1, 0
    mv      a2, s5
    call    check

    /* --- max backward offset (-256) --- */
    TEST_BEGIN str_bnez_maxbwd
    LIX     s0, 0xdeadbeef
    LIX     s5, 0
    j       5f
4:
    LIX     s5, 1
    j       6f
5:
    .option rvc
    .rept 124
    c.nop
    .endr
    c.bnez  s0, 4b
    .option norvc
    LIX     s5, 99
6:
    la      a0, str_bnez_maxbwd
    LIX     a1, 1
    mv      a2, s5
    call    check

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

tests_c_quadrant1:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    jal     ra, test_c_nop
    jal     ra, test_c_addi
    .if XLEN == 64
    jal     ra, test_c_addiw
    .endif
    jal     ra, test_c_li
    jal     ra, test_c_addi16sp
    jal     ra, test_c_lui
    jal     ra, test_c_srli
    jal     ra, test_c_srai
    jal     ra, test_c_andi
    jal     ra, test_c_sub
    jal     ra, test_c_xor
    jal     ra, test_c_or
    jal     ra, test_c_and
    .if XLEN == 64
    jal     ra, test_c_subw
    .endif
    .if XLEN == 64
    jal     ra, test_c_addw
    .endif

    /* --- C.J: see test_c_j --- */
    jal     ra, test_c_j
    .if XLEN == 32
    jal     ra, test_c_jal
    .endif

    /* --- C.BEQZ: see test_c_beqz --- */
    jal     ra, test_c_beqz

    /* --- C.BNEZ: see test_c_bnez --- */
    jal     ra, test_c_bnez

    jal     ra, bitx_c_quadrant1

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

bitx_c_quadrant1:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    BX_POOL BX_Q1_VA, BX_Q1_VB
    /* C.ADDI and C.LUI need a nonzero immediate, so their rd-only pairs
     * use background imm 1; the rest use 0 */
    BX_E_RI5 BX_C_CI, "c.addi, C.ADDI", 7, "0x1,0x2,0x4,0x8,0x10,0x20", 1
    .if XLEN == 64
    BX_E_RI5 BX_C_CI, "c.addiw, C.ADDIW", 7, "0x1,0x2,0x4,0x8,0x10,0x20", 0
    .endif
    BX_E_RI5 BX_C_CI, "c.li, C.LI", 7, "0x1,0x2,0x4,0x8,0x10,0x20", 0
    BX_E_RI5 BX_C_CI, "c.lui, C.LUI", 7, "0x1,0x2,0x4,0x8,0x10,0x20", 1
    /* shamt 0 isn't encodable (see CLAUDE.md), so background shamt 1 */
    .if XLEN == 64
    BX_E_RI3 BX_C_CI, "c.srli, C.SRLI", "0x1,0x2,0x4,0x8,0x10,0x20", 1
    .else
    BX_E_RI3 BX_C_CI, "c.srli, C.SRLI", "0x1,0x2,0x4,0x8,0x10", 1
    .endif
    .if XLEN == 64
    BX_E_RI3 BX_C_CI, "c.srai, C.SRAI", "0x1,0x2,0x4,0x8,0x10,0x20", 1
    .else
    BX_E_RI3 BX_C_CI, "c.srai, C.SRAI", "0x1,0x2,0x4,0x8,0x10", 1
    .endif
    BX_E_RI3 BX_C_CI, "c.andi, C.ANDI", "0x1,0x2,0x4,0x8,0x10,0x20", 0
    BX_E_I  BX_C_A16SP, "C.ADDI16SP", "0x10,0x20,0x40,0x80,0x100,0x200"
    BX_E_RR3 BX_C_CA, "c.sub, C.SUB"
    BX_E_RR3 BX_C_CA, "c.xor, C.XOR"
    BX_E_RR3 BX_C_CA, "c.or, C.OR"
    BX_E_RR3 BX_C_CA, "c.and, C.AND"
    .if XLEN == 64
    BX_E_RR3 BX_C_CA, "c.subw, C.SUBW"
    .endif
    .if XLEN == 64
    BX_E_RR3 BX_C_CA, "c.addw, C.ADDW"
    .endif

    call    bx_sled_init
    BX_E_I  BX_C_CJ, "C.J", "0x2,0x4,0x8,0x10,0x20,0x40,0x80,0x100,0x200,0x400,0x800"
    .if XLEN == 32
    BX_E_I  BX_C_CJAL, "C.JAL", "0x2,0x4,0x8,0x10,0x20,0x40,0x80,0x100,0x200,0x400,0x800"
    .endif
    /* offset background +8 for the rs1'-only pairs */
    BX_POOL 0, 0
    BX_E_RI3 BX_C_CB, "c.beqz, C.BEQZ", "0x2,0x4,0x8,0x10,0x20,0x40,0x80,0x100", 8
    BX_POOL 0x0123456789abcdef, 0
    BX_E_RI3 BX_C_CB, "c.bnez, C.BNEZ", "0x2,0x4,0x8,0x10,0x20,0x40,0x80,0x100", 8

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  Strings
 * ======================================================================= */
    .section .rodata
str_nop_t0: .asciz "C.NOP s0 unmodified"
str_nop_t1: .asciz "C.NOP s1 unmodified"
str_nop_t2: .asciz "C.NOP s3 unmodified"
str_nop_s0: .asciz "C.NOP s4 unmodified"
str_nop_s1: .asciz "C.NOP s5 unmodified"
str_nop_a3: .asciz "C.NOP a3 unmodified"
str_nop_sp: .asciz "C.NOP sp unmodified"
str_nop_mem: .asciz "C.NOP memory unmodified"
str_nop_sequence: .asciz "C.NOP x4 back-to-back, no side effects"

str_addi_reg_ra:  .asciz "C.ADDI rd=ra(x1)"
str_addi_reg_t0:  .asciz "C.ADDI rd=t0(x5)"
str_addi_reg_s0:  .asciz "C.ADDI rd=s0(x8)"
str_addi_reg_a0:  .asciz "C.ADDI rd=a0(x10)"
str_addi_reg_a4:  .asciz "C.ADDI rd=a4(x14)"
str_addi_reg_s2:  .asciz "C.ADDI rd=s2(x18)"
str_addi_reg_s6:  .asciz "C.ADDI rd=s6(x22)"
str_addi_reg_s10: .asciz "C.ADDI rd=s10(x26)"
str_addi_reg_t6:  .asciz "C.ADDI rd=t6(x31)"
str_addi_imm_p1:  .asciz "C.ADDI imm=+1"
str_addi_imm_m1:  .asciz "C.ADDI imm=-1"
str_addi_imm_p2:  .asciz "C.ADDI imm=+2"
str_addi_imm_m2:  .asciz "C.ADDI imm=-2"
str_addi_imm_p4:  .asciz "C.ADDI imm=+4"
str_addi_imm_m4:  .asciz "C.ADDI imm=-4"
str_addi_imm_p8:  .asciz "C.ADDI imm=+8"
str_addi_imm_m8:  .asciz "C.ADDI imm=-8"
str_addi_imm_p16: .asciz "C.ADDI imm=+16"
str_addi_imm_m16: .asciz "C.ADDI imm=-16"
str_addi_imm_max: .asciz "C.ADDI imm=+31 (max)"
str_addi_imm_min: .asciz "C.ADDI imm=-32 (min)"
    .if XLEN == 64
str_addi_wrap_inc: .asciz "C.ADDI 64-bit wrap 0xfff...f + 1 = 0"
    .else
str_addi_wrap_inc: .asciz "C.ADDI 32-bit wrap 0xfff...f + 1 = 0"
    .endif
    .if XLEN == 64
str_addi_wrap_dec: .asciz "C.ADDI 64-bit wrap INT64_MIN - 1"
    .else
str_addi_wrap_dec: .asciz "C.ADDI 32-bit wrap INT32_MIN - 1"
    .endif
str_addi_sp_delta:    .asciz "C.ADDI rd=sp applies correct delta"
str_addi_sp_restored: .asciz "C.ADDI rd=sp fully restored"

str_addiw_reg_ra:  .asciz "C.ADDIW rd=ra(x1)"
str_addiw_reg_t0:  .asciz "C.ADDIW rd=t0(x5)"
str_addiw_reg_s0:  .asciz "C.ADDIW rd=s0(x8)"
str_addiw_reg_a0:  .asciz "C.ADDIW rd=a0(x10)"
str_addiw_reg_a4:  .asciz "C.ADDIW rd=a4(x14)"
str_addiw_reg_s2:  .asciz "C.ADDIW rd=s2(x18)"
str_addiw_reg_s6:  .asciz "C.ADDIW rd=s6(x22)"
str_addiw_reg_s10: .asciz "C.ADDIW rd=s10(x26)"
str_addiw_reg_t6:  .asciz "C.ADDIW rd=t6(x31)"
str_addiw_imm_p1:  .asciz "C.ADDIW imm=+1"
str_addiw_imm_m1:  .asciz "C.ADDIW imm=-1"
str_addiw_imm_p2:  .asciz "C.ADDIW imm=+2"
str_addiw_imm_m2:  .asciz "C.ADDIW imm=-2"
str_addiw_imm_p4:  .asciz "C.ADDIW imm=+4"
str_addiw_imm_m4:  .asciz "C.ADDIW imm=-4"
str_addiw_imm_p8:  .asciz "C.ADDIW imm=+8"
str_addiw_imm_m8:  .asciz "C.ADDIW imm=-8"
str_addiw_imm_p16: .asciz "C.ADDIW imm=+16"
str_addiw_imm_m16: .asciz "C.ADDIW imm=-16"
str_addiw_imm_max: .asciz "C.ADDIW imm=+31 (max)"
str_addiw_imm_min: .asciz "C.ADDIW imm=-32 (min)"
str_addiw_overflow_pos:     .asciz "C.ADDIW 32-bit overflow to negative, sign-extends"
str_addiw_maxpos_noverflow: .asciz "C.ADDIW max positive, no overflow"
str_addiw_underflow_wrap:   .asciz "C.ADDIW 32-bit underflow wraps to max positive"
str_addiw_minimm:           .asciz "C.ADDIW imm=-32 from zero, sign-extends"
str_addiw_upper_garbage_zero: .asciz "C.ADDIW discards garbage upper 32 bits"

str_li_reg_ra:  .asciz "C.LI rd=ra(x1)"
str_li_reg_t0:  .asciz "C.LI rd=t0(x5)"
str_li_reg_s0:  .asciz "C.LI rd=s0(x8)"
str_li_reg_a0:  .asciz "C.LI rd=a0(x10)"
str_li_reg_a4:  .asciz "C.LI rd=a4(x14)"
str_li_reg_s2:  .asciz "C.LI rd=s2(x18)"
str_li_reg_s6:  .asciz "C.LI rd=s6(x22)"
str_li_reg_s10: .asciz "C.LI rd=s10(x26)"
str_li_reg_t6:  .asciz "C.LI rd=t6(x31)"
str_li_imm_zero: .asciz "C.LI imm=0 (legal, overwrites poison)"
str_li_imm_p1:   .asciz "C.LI imm=+1"
str_li_imm_m1:   .asciz "C.LI imm=-1"
str_li_imm_p2:   .asciz "C.LI imm=+2"
str_li_imm_m2:   .asciz "C.LI imm=-2"
str_li_imm_p4:   .asciz "C.LI imm=+4"
str_li_imm_m4:   .asciz "C.LI imm=-4"
str_li_imm_p8:   .asciz "C.LI imm=+8"
str_li_imm_m8:   .asciz "C.LI imm=-8"
str_li_imm_p16:  .asciz "C.LI imm=+16"
str_li_imm_m16:  .asciz "C.LI imm=-16"
str_li_imm_max:  .asciz "C.LI imm=+31 (max)"
str_li_imm_min:  .asciz "C.LI imm=-32 (min)"

str_a16sp_p16:   .asciz "C.ADDI16SP delta=+16 (bit4)"
str_a16sp_p32:   .asciz "C.ADDI16SP delta=+32 (bit5)"
str_a16sp_p64:   .asciz "C.ADDI16SP delta=+64 (bit6)"
str_a16sp_p128:  .asciz "C.ADDI16SP delta=+128 (bit7)"
str_a16sp_p256:  .asciz "C.ADDI16SP delta=+256 (bit8)"
str_a16sp_pmax:  .asciz "C.ADDI16SP delta=+496 (max)"
str_a16sp_m16:   .asciz "C.ADDI16SP delta=-16"
str_a16sp_m32:   .asciz "C.ADDI16SP delta=-32"
str_a16sp_m64:   .asciz "C.ADDI16SP delta=-64"
str_a16sp_m128:  .asciz "C.ADDI16SP delta=-128"
str_a16sp_m256:  .asciz "C.ADDI16SP delta=-256"
str_a16sp_mmin:  .asciz "C.ADDI16SP delta=-512 (min, sign bit alone)"
str_a16sp_mix1:  .asciz "C.ADDI16SP delta=+208 (mixed bits)"
str_a16sp_mix2:  .asciz "C.ADDI16SP delta=-304 (mixed bits)"
str_a16sp_restored: .asciz "C.ADDI16SP sp fully restored (no cumulative drift)"

str_lui_reg_ra:  .asciz "C.LUI rd=ra(x1)"
str_lui_reg_t0:  .asciz "C.LUI rd=t0(x5)"
str_lui_reg_s0:  .asciz "C.LUI rd=s0(x8)"
str_lui_reg_a0:  .asciz "C.LUI rd=a0(x10)"
str_lui_reg_a4:  .asciz "C.LUI rd=a4(x14)"
str_lui_reg_s2:  .asciz "C.LUI rd=s2(x18)"
str_lui_reg_s6:  .asciz "C.LUI rd=s6(x22)"
str_lui_reg_s10: .asciz "C.LUI rd=s10(x26)"
str_lui_reg_t6:  .asciz "C.LUI rd=t6(x31)"
str_lui_imm_p1:  .asciz "C.LUI imm=+1"
str_lui_imm_m1:  .asciz "C.LUI imm=-1"
str_lui_imm_p2:  .asciz "C.LUI imm=+2"
str_lui_imm_m2:  .asciz "C.LUI imm=-2"
str_lui_imm_p4:  .asciz "C.LUI imm=+4"
str_lui_imm_m4:  .asciz "C.LUI imm=-4"
str_lui_imm_p8:  .asciz "C.LUI imm=+8"
str_lui_imm_m8:  .asciz "C.LUI imm=-8"
str_lui_imm_p16: .asciz "C.LUI imm=+16"
str_lui_imm_m16: .asciz "C.LUI imm=-16"
str_lui_imm_max: .asciz "C.LUI imm=+31 (max)"
str_lui_imm_min: .asciz "C.LUI imm=-32 (min)"

str_srli_reg_s0: .asciz "C.SRLI rd/rs1=s0(x8)"
str_srli_reg_s1: .asciz "C.SRLI rd/rs1=s1(x9)"
str_srli_reg_a0: .asciz "C.SRLI rd/rs1=a0(x10)"
str_srli_reg_a1: .asciz "C.SRLI rd/rs1=a1(x11)"
str_srli_reg_a2: .asciz "C.SRLI rd/rs1=a2(x12)"
str_srli_reg_a3: .asciz "C.SRLI rd/rs1=a3(x13)"
str_srli_reg_a4: .asciz "C.SRLI rd/rs1=a4(x14)"
str_srli_reg_a5: .asciz "C.SRLI rd/rs1=a5(x15)"
    .if XLEN == 32
str_srli_sh31: .asciz "C.SRLI shamt=31 (max)"
str_srli_sh10: .asciz "C.SRLI shamt=10 (alt pattern 01010)"
str_srai_sh31: .asciz "C.SRAI shamt=31 (max)"
str_srai_sh10: .asciz "C.SRAI shamt=10 (alt pattern 01010)"
    .endif
str_srli_sh1:  .asciz "C.SRLI shamt=1 (min accepted by assembler)"
str_srli_sh2:  .asciz "C.SRLI shamt=2"
str_srli_sh4:  .asciz "C.SRLI shamt=4"
str_srli_sh8:  .asciz "C.SRLI shamt=8"
str_srli_sh16: .asciz "C.SRLI shamt=16"
str_srli_sh32: .asciz "C.SRLI shamt=32"
str_srli_sh63: .asciz "C.SRLI shamt=63 (max)"
    .if XLEN == 64
str_srli_sh21: .asciz "C.SRLI shamt=21 (alt pattern 010101)"
    .else
str_srli_sh21: .asciz "C.SRLI shamt=21 (alt pattern 10101)"
    .endif
str_srli_sh42: .asciz "C.SRLI shamt=42 (alt pattern 101010)"

str_srai_reg_s0: .asciz "C.SRAI rd/rs1=s0(x8)"
str_srai_reg_s1: .asciz "C.SRAI rd/rs1=s1(x9)"
str_srai_reg_a0: .asciz "C.SRAI rd/rs1=a0(x10)"
str_srai_reg_a1: .asciz "C.SRAI rd/rs1=a1(x11)"
str_srai_reg_a2: .asciz "C.SRAI rd/rs1=a2(x12)"
str_srai_reg_a3: .asciz "C.SRAI rd/rs1=a3(x13)"
str_srai_reg_a4: .asciz "C.SRAI rd/rs1=a4(x14)"
str_srai_reg_a5: .asciz "C.SRAI rd/rs1=a5(x15)"
str_srai_sh1:  .asciz "C.SRAI shamt=1"
str_srai_sh2:  .asciz "C.SRAI shamt=2"
str_srai_sh4:  .asciz "C.SRAI shamt=4"
str_srai_sh8:  .asciz "C.SRAI shamt=8"
str_srai_sh16: .asciz "C.SRAI shamt=16"
str_srai_sh32: .asciz "C.SRAI shamt=32"
str_srai_sh63: .asciz "C.SRAI shamt=63 (max)"
    .if XLEN == 64
str_srai_sh21: .asciz "C.SRAI shamt=21 (alt pattern 010101)"
    .else
str_srai_sh21: .asciz "C.SRAI shamt=21 (alt pattern 10101)"
    .endif
str_srai_sh42: .asciz "C.SRAI shamt=42 (alt pattern 101010)"
str_srai_positive: .asciz "C.SRAI positive input needs no sign-extension"

str_andi_reg_s0: .asciz "C.ANDI rd/rs1=s0(x8)"
str_andi_reg_s1: .asciz "C.ANDI rd/rs1=s1(x9)"
str_andi_reg_a0: .asciz "C.ANDI rd/rs1=a0(x10)"
str_andi_reg_a1: .asciz "C.ANDI rd/rs1=a1(x11)"
str_andi_reg_a2: .asciz "C.ANDI rd/rs1=a2(x12)"
str_andi_reg_a3: .asciz "C.ANDI rd/rs1=a3(x13)"
str_andi_reg_a4: .asciz "C.ANDI rd/rs1=a4(x14)"
str_andi_reg_a5: .asciz "C.ANDI rd/rs1=a5(x15)"
str_andi_imm_m1:   .asciz "C.ANDI imm=-1 (identity, all-ones mask)"
str_andi_imm_zero: .asciz "C.ANDI imm=0 (clears everything)"
str_andi_imm_p1:   .asciz "C.ANDI imm=+1"
str_andi_imm_p2:   .asciz "C.ANDI imm=+2"
str_andi_imm_p4:   .asciz "C.ANDI imm=+4"
str_andi_imm_p8:   .asciz "C.ANDI imm=+8"
str_andi_imm_p16:  .asciz "C.ANDI imm=+16"
str_andi_imm_max:  .asciz "C.ANDI imm=+31 (max)"
str_andi_imm_m2:   .asciz "C.ANDI imm=-2"
str_andi_imm_m4:   .asciz "C.ANDI imm=-4"
str_andi_imm_m8:   .asciz "C.ANDI imm=-8"
str_andi_imm_m16:  .asciz "C.ANDI imm=-16"
str_andi_imm_min:  .asciz "C.ANDI imm=-32 (min)"

str_sub_rs1_s0: .asciz "C.SUB rd/rs1=s0(x8)"
str_sub_rs1_s1: .asciz "C.SUB rd/rs1=s1(x9)"
str_sub_rs1_a0: .asciz "C.SUB rd/rs1=a0(x10)"
str_sub_rs1_a1: .asciz "C.SUB rd/rs1=a1(x11)"
str_sub_rs1_a2: .asciz "C.SUB rd/rs1=a2(x12)"
str_sub_rs1_a3: .asciz "C.SUB rd/rs1=a3(x13)"
str_sub_rs1_a5: .asciz "C.SUB rd/rs1=a5(x15)"
str_sub_rs2_s1: .asciz "C.SUB rs2=s1(x9)"
str_sub_rs2_a0: .asciz "C.SUB rs2=a0(x10)"
str_sub_rs2_a1: .asciz "C.SUB rs2=a1(x11)"
str_sub_rs2_a2: .asciz "C.SUB rs2=a2(x12)"
str_sub_rs2_a3: .asciz "C.SUB rs2=a3(x13)"
str_sub_rs2_a4: .asciz "C.SUB rs2=a4(x14)"
str_sub_rs2_a5: .asciz "C.SUB rs2=a5(x15)"
str_sub_alias_s0: .asciz "C.SUB rd==rs1==rs2==s0(x8) alias (self-sub = 0)"
str_sub_alias_a4: .asciz "C.SUB rd==rs1==rs2==a4(x14) alias (self-sub = 0)"
str_sub_val_zero:      .asciz "C.SUB 0 - 0 = 0"
str_sub_val_underflow: .asciz "C.SUB 0 - 1 underflows to all-ones"
    .if XLEN == 64
str_sub_val_minwrap:   .asciz "C.SUB INT64_MIN - 1 wraps to INT64_MAX"
    .else
str_sub_val_minwrap:   .asciz "C.SUB INT32_MIN - 1 wraps to INT32_MAX"
    .endif
str_sub_val_selfequal: .asciz "C.SUB equal operands = 0"
str_sub_val_alt1:      .asciz "C.SUB 0xaaaa... - 0x5555... "
str_sub_val_alt2:      .asciz "C.SUB 0x5555... - 0xaaaa... "
str_sub_rs2_preserved: .asciz "C.SUB rs2 unmodified"

str_and_rs1_s0: .asciz "C.AND rd/rs1=s0(x8)"
str_and_rs1_s1: .asciz "C.AND rd/rs1=s1(x9)"
str_and_rs1_a0: .asciz "C.AND rd/rs1=a0(x10)"
str_and_rs1_a1: .asciz "C.AND rd/rs1=a1(x11)"
str_and_rs1_a2: .asciz "C.AND rd/rs1=a2(x12)"
str_and_rs1_a3: .asciz "C.AND rd/rs1=a3(x13)"
str_and_rs1_a5: .asciz "C.AND rd/rs1=a5(x15)"
str_and_rs2_s1: .asciz "C.AND rs2=s1(x9)"
str_and_rs2_a0: .asciz "C.AND rs2=a0(x10)"
str_and_rs2_a1: .asciz "C.AND rs2=a1(x11)"
str_and_rs2_a2: .asciz "C.AND rs2=a2(x12)"
str_and_rs2_a3: .asciz "C.AND rs2=a3(x13)"
str_and_rs2_a4: .asciz "C.AND rs2=a4(x14)"
str_and_rs2_a5: .asciz "C.AND rs2=a5(x15)"
str_and_alias_s0: .asciz "C.AND rd==rs1==rs2==s0(x8) alias (self-AND = identity)"
str_and_alias_a4: .asciz "C.AND rd==rs1==rs2==a4(x14) alias (self-AND = identity)"
str_and_val_identity:      .asciz "C.AND allones & walking = walking"
str_and_val_zero:          .asciz "C.AND walking & 0 = 0"
str_and_val_complementary: .asciz "C.AND 0xaaaa... & 0x5555... = 0"
str_and_val_walking:       .asciz "C.AND two walking patterns"
str_and_rs2_preserved: .asciz "C.AND rs2 unmodified"

str_xor_rs1_s0: .asciz "C.XOR rd/rs1=s0(x8)"
str_xor_rs1_s1: .asciz "C.XOR rd/rs1=s1(x9)"
str_xor_rs1_a0: .asciz "C.XOR rd/rs1=a0(x10)"
str_xor_rs1_a1: .asciz "C.XOR rd/rs1=a1(x11)"
str_xor_rs1_a2: .asciz "C.XOR rd/rs1=a2(x12)"
str_xor_rs1_a3: .asciz "C.XOR rd/rs1=a3(x13)"
str_xor_rs1_a5: .asciz "C.XOR rd/rs1=a5(x15)"
str_xor_rs2_s1: .asciz "C.XOR rs2=s1(x9)"
str_xor_rs2_a0: .asciz "C.XOR rs2=a0(x10)"
str_xor_rs2_a1: .asciz "C.XOR rs2=a1(x11)"
str_xor_rs2_a2: .asciz "C.XOR rs2=a2(x12)"
str_xor_rs2_a3: .asciz "C.XOR rs2=a3(x13)"
str_xor_rs2_a4: .asciz "C.XOR rs2=a4(x14)"
str_xor_rs2_a5: .asciz "C.XOR rs2=a5(x15)"
str_xor_alias_s0: .asciz "C.XOR rd==rs1==rs2==s0(x8) alias (self-XOR = 0)"
str_xor_alias_a4: .asciz "C.XOR rd==rs1==rs2==a4(x14) alias (self-XOR = 0)"
str_xor_val_identity:      .asciz "C.XOR walking ^ 0 = walking"
str_xor_val_complement:    .asciz "C.XOR allones ^ walking = ~walking"
str_xor_val_complementary: .asciz "C.XOR 0xaaaa... ^ 0x5555... = allones"
str_xor_val_walking:       .asciz "C.XOR two walking patterns"
str_xor_rs2_preserved: .asciz "C.XOR rs2 unmodified"

str_or_rs1_s0: .asciz "C.OR rd/rs1=s0(x8)"
str_or_rs1_s1: .asciz "C.OR rd/rs1=s1(x9)"
str_or_rs1_a0: .asciz "C.OR rd/rs1=a0(x10)"
str_or_rs1_a1: .asciz "C.OR rd/rs1=a1(x11)"
str_or_rs1_a2: .asciz "C.OR rd/rs1=a2(x12)"
str_or_rs1_a3: .asciz "C.OR rd/rs1=a3(x13)"
str_or_rs1_a5: .asciz "C.OR rd/rs1=a5(x15)"
str_or_rs2_s1: .asciz "C.OR rs2=s1(x9)"
str_or_rs2_a0: .asciz "C.OR rs2=a0(x10)"
str_or_rs2_a1: .asciz "C.OR rs2=a1(x11)"
str_or_rs2_a2: .asciz "C.OR rs2=a2(x12)"
str_or_rs2_a3: .asciz "C.OR rs2=a3(x13)"
str_or_rs2_a4: .asciz "C.OR rs2=a4(x14)"
str_or_rs2_a5: .asciz "C.OR rs2=a5(x15)"
str_or_alias_s0: .asciz "C.OR rd==rs1==rs2==s0(x8) alias (self-OR = identity)"
str_or_alias_a4: .asciz "C.OR rd==rs1==rs2==a4(x14) alias (self-OR = identity)"
str_or_val_identity:      .asciz "C.OR walking | 0 = walking"
str_or_val_allones:       .asciz "C.OR walking | allones = allones"
str_or_val_complementary: .asciz "C.OR 0xaaaa... | 0x5555... = allones"
str_or_val_walking:       .asciz "C.OR two walking patterns"
str_or_rs2_preserved: .asciz "C.OR rs2 unmodified"

str_subw_rs1_s0: .asciz "C.SUBW rd/rs1=s0(x8)"
str_subw_rs1_s1: .asciz "C.SUBW rd/rs1=s1(x9)"
str_subw_rs1_a0: .asciz "C.SUBW rd/rs1=a0(x10)"
str_subw_rs1_a1: .asciz "C.SUBW rd/rs1=a1(x11)"
str_subw_rs1_a2: .asciz "C.SUBW rd/rs1=a2(x12)"
str_subw_rs1_a3: .asciz "C.SUBW rd/rs1=a3(x13)"
str_subw_rs1_a5: .asciz "C.SUBW rd/rs1=a5(x15)"
str_subw_rs2_s1: .asciz "C.SUBW rs2=s1(x9)"
str_subw_rs2_a0: .asciz "C.SUBW rs2=a0(x10)"
str_subw_rs2_a1: .asciz "C.SUBW rs2=a1(x11)"
str_subw_rs2_a2: .asciz "C.SUBW rs2=a2(x12)"
str_subw_rs2_a3: .asciz "C.SUBW rs2=a3(x13)"
str_subw_rs2_a4: .asciz "C.SUBW rs2=a4(x14)"
str_subw_rs2_a5: .asciz "C.SUBW rs2=a5(x15)"
str_subw_alias_s0: .asciz "C.SUBW rd==rs1==rs2==s0(x8) alias (self-sub = 0)"
str_subw_alias_a4: .asciz "C.SUBW rd==rs1==rs2==a4(x14) alias (self-sub = 0)"
str_subw_underflow:    .asciz "C.SUBW 32-bit 0 - 1 underflows, sign-extends"
str_subw_minwrap:      .asciz "C.SUBW 32-bit INT32_MIN - 1 wraps to INT32_MAX"
str_subw_overflow_neg: .asciz "C.SUBW 32-bit overflow to negative, sign-extends"
str_subw_rd_garbage_upper:  .asciz "C.SUBW discards garbage upper 32 bits of rd"
str_subw_rs2_garbage_upper: .asciz "C.SUBW discards garbage upper 32 bits of rs2"
str_subw_rs2_preserved: .asciz "C.SUBW rs2 unmodified"

str_addw_rs1_s0: .asciz "C.ADDW rd/rs1=s0(x8)"
str_addw_rs1_s1: .asciz "C.ADDW rd/rs1=s1(x9)"
str_addw_rs1_a0: .asciz "C.ADDW rd/rs1=a0(x10)"
str_addw_rs1_a1: .asciz "C.ADDW rd/rs1=a1(x11)"
str_addw_rs1_a2: .asciz "C.ADDW rd/rs1=a2(x12)"
str_addw_rs1_a3: .asciz "C.ADDW rd/rs1=a3(x13)"
str_addw_rs1_a5: .asciz "C.ADDW rd/rs1=a5(x15)"
str_addw_rs2_s1: .asciz "C.ADDW rs2=s1(x9)"
str_addw_rs2_a0: .asciz "C.ADDW rs2=a0(x10)"
str_addw_rs2_a1: .asciz "C.ADDW rs2=a1(x11)"
str_addw_rs2_a2: .asciz "C.ADDW rs2=a2(x12)"
str_addw_rs2_a3: .asciz "C.ADDW rs2=a3(x13)"
str_addw_rs2_a4: .asciz "C.ADDW rs2=a4(x14)"
str_addw_rs2_a5: .asciz "C.ADDW rs2=a5(x15)"
str_addw_alias_s0: .asciz "C.ADDW rd==rs1==rs2==s0(x8) alias (self-add = double)"
str_addw_alias_a4: .asciz "C.ADDW rd==rs1==rs2==a4(x14) alias (self-add = double)"
str_addw_overflow_neg: .asciz "C.ADDW 32-bit overflow to negative, sign-extends"
str_addw_wrap_zero:    .asciz "C.ADDW 32-bit 0xffffffff + 1 wraps to 0"
str_addw_underflow:    .asciz "C.ADDW 32-bit underflow wraps to INT32_MAX"
str_addw_rd_garbage_upper:  .asciz "C.ADDW discards garbage upper 32 bits of rd"
str_addw_rs2_garbage_upper: .asciz "C.ADDW discards garbage upper 32 bits of rs2"
str_addw_rs2_preserved: .asciz "C.ADDW rs2 unmodified"

str_j_min:     .asciz "C.J minimum distance (+2, jumps to next instruction)"
str_j_fwd4:    .asciz "C.J forward +4 (bit2)"
str_j_fwd8:    .asciz "C.J forward +8 (bit3)"
str_j_fwd16:   .asciz "C.J forward +16 (bit4)"
str_j_fwd32:   .asciz "C.J forward +32 (bit5)"
str_j_fwd64:   .asciz "C.J forward +64 (bit6)"
str_j_fwd128:  .asciz "C.J forward +128 (bit7)"
str_j_fwd256:  .asciz "C.J forward +256 (bit8)"
str_j_fwd512:  .asciz "C.J forward +512 (bit9)"
str_j_fwd1024: .asciz "C.J forward +1024 (bit10)"
str_j_fwdmax:  .asciz "C.J near-max forward (+2044)"
str_j_bwd8:    .asciz "C.J backward -8 (bit3)"
str_j_bwd16:   .asciz "C.J backward -16 (bit4)"
str_j_bwd32:   .asciz "C.J backward -32 (bit5)"
str_j_bwd64:   .asciz "C.J backward -64 (bit6)"
str_j_bwd128:  .asciz "C.J backward -128 (bit7)"
str_j_bwd256:  .asciz "C.J backward -256 (bit8)"
str_j_bwd512:  .asciz "C.J backward -512 (bit9)"
str_j_bwd1024: .asciz "C.J backward -1024 (bit10)"
str_j_bwdmax:  .asciz "C.J near-max backward (-2044)"
str_j_loop:    .asciz "C.J as a loop's backward continue edge, 3 iterations"
    .if XLEN == 32
str_cjal_min_link:  .asciz "C.JAL minimum distance (+2): ra = pc + 2"
str_cjal_fwd4:      .asciz "C.JAL forward +4 (bit2)"
str_cjal_fwd4_link: .asciz "C.JAL forward +4 links ra = pc + 2"
str_cjal_fwd8:      .asciz "C.JAL forward +8 (bit3)"
str_cjal_fwd8_link: .asciz "C.JAL forward +8 links ra = pc + 2"
str_cjal_fwd16:      .asciz "C.JAL forward +16 (bit4)"
str_cjal_fwd16_link: .asciz "C.JAL forward +16 links ra = pc + 2"
str_cjal_fwd32:      .asciz "C.JAL forward +32 (bit5)"
str_cjal_fwd32_link: .asciz "C.JAL forward +32 links ra = pc + 2"
str_cjal_fwd64:      .asciz "C.JAL forward +64 (bit6)"
str_cjal_fwd64_link: .asciz "C.JAL forward +64 links ra = pc + 2"
str_cjal_fwd128:      .asciz "C.JAL forward +128 (bit7)"
str_cjal_fwd128_link: .asciz "C.JAL forward +128 links ra = pc + 2"
str_cjal_fwd256:      .asciz "C.JAL forward +256 (bit8)"
str_cjal_fwd256_link: .asciz "C.JAL forward +256 links ra = pc + 2"
str_cjal_fwd512:      .asciz "C.JAL forward +512 (bit9)"
str_cjal_fwd512_link: .asciz "C.JAL forward +512 links ra = pc + 2"
str_cjal_fwd1024:      .asciz "C.JAL forward +1024 (bit10)"
str_cjal_fwd1024_link: .asciz "C.JAL forward +1024 links ra = pc + 2"
str_cjal_fwdmax:      .asciz "C.JAL near-max forward (+2044)"
str_cjal_fwdmax_link: .asciz "C.JAL near-max forward links ra = pc + 2"
str_cjal_bwd8:      .asciz "C.JAL backward -8 (bit3)"
str_cjal_bwd8_link: .asciz "C.JAL backward -8 links ra = pc + 2"
str_cjal_bwd16:      .asciz "C.JAL backward -16 (bit4)"
str_cjal_bwd16_link: .asciz "C.JAL backward -16 links ra = pc + 2"
str_cjal_bwd32:      .asciz "C.JAL backward -32 (bit5)"
str_cjal_bwd32_link: .asciz "C.JAL backward -32 links ra = pc + 2"
str_cjal_bwd64:      .asciz "C.JAL backward -64 (bit6)"
str_cjal_bwd64_link: .asciz "C.JAL backward -64 links ra = pc + 2"
str_cjal_bwd128:      .asciz "C.JAL backward -128 (bit7)"
str_cjal_bwd128_link: .asciz "C.JAL backward -128 links ra = pc + 2"
str_cjal_bwd256:      .asciz "C.JAL backward -256 (bit8)"
str_cjal_bwd256_link: .asciz "C.JAL backward -256 links ra = pc + 2"
str_cjal_bwd512:      .asciz "C.JAL backward -512 (bit9)"
str_cjal_bwd512_link: .asciz "C.JAL backward -512 links ra = pc + 2"
str_cjal_bwd1024:      .asciz "C.JAL backward -1024 (bit10)"
str_cjal_bwd1024_link: .asciz "C.JAL backward -1024 links ra = pc + 2"
str_cjal_bwdmax:      .asciz "C.JAL near-max backward (-2044)"
str_cjal_bwdmax_link: .asciz "C.JAL near-max backward links ra = pc + 2"
    .endif
str_beqz_taken_s0: .asciz "C.BEQZ taken, rs1=s0(x8)"
str_beqz_taken_s1: .asciz "C.BEQZ taken, rs1=s1(x9)"
str_beqz_taken_a0: .asciz "C.BEQZ taken, rs1=a0(x10)"
str_beqz_taken_a1: .asciz "C.BEQZ taken, rs1=a1(x11)"
str_beqz_taken_a2: .asciz "C.BEQZ taken, rs1=a2(x12)"
str_beqz_taken_a3: .asciz "C.BEQZ taken, rs1=a3(x13)"
str_beqz_taken_a4: .asciz "C.BEQZ taken, rs1=a4(x14)"
str_beqz_taken_a5: .asciz "C.BEQZ taken, rs1=a5(x15)"
str_beqz_nottaken_s0: .asciz "C.BEQZ not taken, rs1=s0(x8)"
str_beqz_nottaken_s1: .asciz "C.BEQZ not taken, rs1=s1(x9)"
str_beqz_nottaken_a0: .asciz "C.BEQZ not taken, rs1=a0(x10)"
str_beqz_nottaken_a1: .asciz "C.BEQZ not taken, rs1=a1(x11)"
str_beqz_nottaken_a2: .asciz "C.BEQZ not taken, rs1=a2(x12)"
str_beqz_nottaken_a3: .asciz "C.BEQZ not taken, rs1=a3(x13)"
str_beqz_nottaken_a4: .asciz "C.BEQZ not taken, rs1=a4(x14)"
str_beqz_nottaken_a5: .asciz "C.BEQZ not taken, rs1=a5(x15)"
str_beqz_loop:   .asciz "C.BEQZ backward branch, 3-iteration loop"
str_beqz_maxfwd: .asciz "C.BEQZ near-max forward offset (+252)"
str_beqz_maxbwd: .asciz "C.BEQZ max backward offset (-256)"

str_bnez_taken_s0: .asciz "C.BNEZ taken, rs1=s0(x8)"
str_bnez_taken_s1: .asciz "C.BNEZ taken, rs1=s1(x9)"
str_bnez_taken_a0: .asciz "C.BNEZ taken, rs1=a0(x10)"
str_bnez_taken_a1: .asciz "C.BNEZ taken, rs1=a1(x11)"
str_bnez_taken_a2: .asciz "C.BNEZ taken, rs1=a2(x12)"
str_bnez_taken_a3: .asciz "C.BNEZ taken, rs1=a3(x13)"
str_bnez_taken_a4: .asciz "C.BNEZ taken, rs1=a4(x14)"
str_bnez_taken_a5: .asciz "C.BNEZ taken, rs1=a5(x15)"
str_bnez_nottaken_s0: .asciz "C.BNEZ not taken, rs1=s0(x8)"
str_bnez_nottaken_s1: .asciz "C.BNEZ not taken, rs1=s1(x9)"
str_bnez_nottaken_a0: .asciz "C.BNEZ not taken, rs1=a0(x10)"
str_bnez_nottaken_a1: .asciz "C.BNEZ not taken, rs1=a1(x11)"
str_bnez_nottaken_a2: .asciz "C.BNEZ not taken, rs1=a2(x12)"
str_bnez_nottaken_a3: .asciz "C.BNEZ not taken, rs1=a3(x13)"
str_bnez_nottaken_a4: .asciz "C.BNEZ not taken, rs1=a4(x14)"
str_bnez_nottaken_a5: .asciz "C.BNEZ not taken, rs1=a5(x15)"
str_bnez_loop:   .asciz "C.BNEZ backward branch, 5-iteration countdown loop"
str_bnez_maxfwd: .asciz "C.BNEZ near-max forward offset (+252)"
str_bnez_maxbwd: .asciz "C.BNEZ max backward offset (-256)"
