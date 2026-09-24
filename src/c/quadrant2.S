/* =====================================================================
 * c/quadrant2.S  --  RVC quadrant 2 (compressed opcode bits[1:0]=10):
 *                       C.SLLI, C.LWSP, C.LDSP, C.JR, C.MV, C.EBREAK,
 *                       C.JALR, C.ADD, C.SWSP, C.SDSP
 *
 * Part of the RV64C test suite; see c/tests.S for the overall
 * structure and common.S for the boot/UART/reporting harness this
 * builds on ("check", "uart_puts", "ebreak_flag", etc. are provided
 * there). This file's only entry point called from outside is
 * tests_c_quadrant2, invoked once by run_tests (in c/tests.S).
 *
 * Bit independence across fields (bitx_c_quadrant2, called last): every
 * bit pair among each instruction's variable fields set together, for
 * every instruction here except C.EBREAK (no variable fields): 55
 * cases for C.SLLI and the four SP-relative loads/stores, 45 for C.MV
 * and C.ADD, 10 for C.JR and C.JALR (a single register field). See the
 * bit-independence block below and bitx.inc.
 *
 * RV32 image (xlen.inc): C.LDSP and C.SDSP are RV64C-only and left out
 * (C.FLWSP/C.FSWSP on RV32C); C.SLLI takes a 5-bit shamt (45
 * bit-independence cases).
 * ===================================================================== */

    .include "xlen.inc"
    .include "harness.inc"

    .option norvc

    .include "bitx.inc"

    .global tests_c_quadrant2

    .section .text

/* =======================================================================
 *  Bit-independence cases (bitx.inc, bitx.S)
 * ======================================================================= */
    .equ BX_Q2_VA, 0x8123456789abcdef
    .equ BX_Q2_VB, 0x0fedcba987654321

/* C.SLLI: rd (5-bit) and the 6-bit shamt, C(11,2) = 55 pairs; rd starts
 * as BX_Q2_VA, and the expected value is an assemble-time constant. */
.macro BX_C_SLLI nm, rd, v
    BX_ENTER
    BX_LDC  t5, (BX_Q2_VA << (\v))
    BX_PV   x\rd, 0
    .option push
    .option rvc
    c.slli  x\rd, (\v)
    .option pop
    mv      t6, x\rd
    BX_REPORT "\nm bitx rd=x\rd shamt=\v"
.endm

/* C.LWSP / C.LDSP: rd (5-bit) and the 6-bit scaled offset, 55 pairs. sp
 * is pointed at a BX_PATTERN buffer (and restored by BX_REPORT); the
 * expected value is the 4-byte LW/LD from the precomputed address with
 * offset 0. rd = x2 loads into sp itself, which is fine. */
.macro BX_C_LSP insn, linsn, nm, rd, v
    BX_ENTER
    .option push
    .option norelax
    la      t3, bx_q2_ld + (\v)
    .option pop
    \linsn  t2, 0(t3)
    mv      t5, t2
    BX_PV   x\rd, 2
    .option push
    .option norelax
    la      sp, bx_q2_ld
    .option rvc
    \insn   x\rd, (\v)(sp)
    .option pop
    mv      t6, x\rd
    BX_REPORT "\nm bitx rd=x\rd off=\v"
.endm

/* C.SWSP / C.SDSP: rs2 (5-bit) and the 6-bit scaled offset, 55 pairs,
 * through BX_ST_PREP / BX_ST_CHECK. rs2 = x2 stores sp, i.e. the buffer
 * address. */
.macro BX_C_SSP insn, w, nm, rs2, v
    BX_ENTER
    BX_ST_PREP bx_q2_st, (\v)
    BX_PV   x\rs2, 0
    .option push
    .option norelax
    la      sp, bx_q2_st
    .option rvc
    \insn   x\rs2, (\v)(sp)
    .option pop
    BX_ST_CHECK bx_q2_st, (\v), \w, (\rs2 == 2), bx_q2_st, 0
    BX_REPORT "\nm bitx rs2=x\rs2 off=\v"
.endm

/* C.MV / C.ADD: rd and rs2 (both 5-bit, neither x0), C(10,2) = 45
 * pairs. rd = VA (C.ADD reads it; for C.MV it's just a value that must
 * be overwritten), then rs2 = VB, so aliasing makes both VB. */
.macro BX_C_CR insn, nm, rd, rs2
    BX_ENTER
    .ifc \insn, c.mv
    BX_LDC  t5, BX_Q2_VB
    .else
    .if \rd == \rs2
    BX_LDC  t5, (BX_Q2_VB + BX_Q2_VB)
    .else
    BX_LDC  t5, (BX_Q2_VA + BX_Q2_VB)
    .endif
    .endif
    BX_PV   x\rd, 0
    BX_PV   x\rs2, 1
    .option push
    .option rvc
    \insn   x\rd, x\rs2
    .option pop
    mv      t6, x\rd
    BX_REPORT "\nm bitx rd=x\rd rs2=x\rs2"
.endm

/* C.JR / C.JALR: rs1 is the only field, so its C(5,2) = 10 two-bit
 * register numbers. rs1 holds BX_TARGET in the counting sled; C.JALR
 * must also leave the site's address + 2 in ra (poisoned first). */
.macro BX_C_CJR insn, nm, rs1
    BX_ENTER
    .pushsection .rodata
    .balign 4
    .option push
    .option rvc
96: \insn   x\rs1
    .option pop
    .popsection
    BX_PLANT BX_SITE_F, 2
    BX_PV   ra, 2
    .option push
    .option norelax
    la      x\rs1, bx_region + BX_TARGET
    .option pop
    BX_GO   BX_SITE_F
    mv      s3, ra
    BX_LDC  t5, BX_MARGIN
    BX_REPORT "\nm bitx rs1=x\rs1 landed"
    .ifc \insn, c.jalr
    mv      t6, s3
    .option push
    .option norelax
    la      t5, bx_region + BX_SITE_F + 2
    .option pop
    BX_REPORT "\nm bitx rs1=x\rs1 link"
    .endif
.endm

/* =======================================================================
 *  Reusable per-instruction test macros
 * ======================================================================= */

    /* T_MV_RD rdreg, name -- sweep every register in the full 5-bit rd
     * field (not restricted to x8-x15, unlike quadrant 0/1's CB/CA/CL/
     * CS-format instructions). Fixed rs2=a6 (deliberately outside the
     * sweep set, so it never collides with rdreg), poisoned rd first
     * so a "leave unchanged" bug would be caught, not just a "combine"
     * bug. rdreg may itself be a0/a1/a2. */
    .macro T_MV_RD rdreg, name
    TEST_BEGIN \name
    LIXT    a6, 0x1122334455667788
    LIXT    \rdreg, 0xdeadbeefdeadbeef
    .option rvc
    c.mv    \rdreg, a6
    .option norvc
    mv      t2, \rdreg
    la      a0, \name
    LIXT    a1, 0x1122334455667788
    mv      a2, t2
    call    check
    .endm

    /* T_MV_RS2 rs2reg, name -- sweep every register in the full 5-bit
     * rs2 field, fixed rd=t1. rs2reg's value is consumed by c.mv
     * itself before a0-a2 are touched, so rs2reg may safely be
     * a0/a1/a2 with no separate capture needed. */
    .macro T_MV_RS2 rs2reg, name
    TEST_BEGIN \name
    LIXT    \rs2reg, 0x1122334455667788
    LIXT    t1, 0xdeadbeefdeadbeef
    .option rvc
    c.mv    t1, \rs2reg
    .option norvc
    la      a0, \name
    LIXT    a1, 0x1122334455667788
    mv      a2, t1
    call    check
    .endm

    /* T_MV_ALIAS reg, name -- rd==rs2: "mv reg,reg" is a true identity,
     * not a hazard (unlike the CA-format ops' rd==rs2 aliasing, there
     * is no separate combine step here to collapse). */
    .macro T_MV_ALIAS reg, name
    TEST_BEGIN \name
    LIXT    \reg, 0x123456789abcdef0
    .option rvc
    c.mv    \reg, \reg
    .option norvc
    mv      t2, \reg
    la      a0, \name
    LIXT    a1, 0x123456789abcdef0
    mv      a2, t2
    call    check
    .endm

    /* T_MV_VAL val, name -- data-pattern sweep, fixed rd=t1/rs2=t2,
     * rd poisoned first each time. The main risk C.MV specifically
     * needs to rule out is truncation (e.g. only copying 32 of 64
     * bits), so the values here are chosen to make that visible. */
    .macro T_MV_VAL val, name
    TEST_BEGIN \name
    LIXT    t2, \val
    LIXT    t1, 0xdeadbeefdeadbeef
    .option rvc
    c.mv    t1, t2
    .option norvc
    la      a0, \name
    LIXT    a1, \val
    mv      a2, t1
    call    check
    .endm

/* =======================================================================
 *  C.MV : rd = rs2  (CR format, rd and rs2 both full 5-bit, non-zero;
 *         rs1 is unused/ignored in this encoding). A pure copy, so
 *         besides the usual register sweeps the main things worth
 *         nailing down are: full 64-bit width (no truncation), rd==rs2
 *         being a genuine no-op, and rs2 being left untouched.
 * ======================================================================= */
test_c_mv:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    /* --- every register in the full 5-bit rd field --- */
    T_MV_RD ra,  str_mv_rd_ra
    T_MV_RD t0,  str_mv_rd_t0
    T_MV_RD s0,  str_mv_rd_s0
    T_MV_RD a0,  str_mv_rd_a0
    T_MV_RD a4,  str_mv_rd_a4
    T_MV_RD s2,  str_mv_rd_s2
    T_MV_RD s6,  str_mv_rd_s6
    T_MV_RD s10, str_mv_rd_s10
    T_MV_RD t6,  str_mv_rd_t6

    /* --- every register in the full 5-bit rs2 field --- */
    T_MV_RS2 ra,  str_mv_rs2_ra
    T_MV_RS2 t0,  str_mv_rs2_t0
    T_MV_RS2 s0,  str_mv_rs2_s0
    T_MV_RS2 a0,  str_mv_rs2_a0
    T_MV_RS2 a4,  str_mv_rs2_a4
    T_MV_RS2 s2,  str_mv_rs2_s2
    T_MV_RS2 s6,  str_mv_rs2_s6
    T_MV_RS2 s10, str_mv_rs2_s10
    T_MV_RS2 t6,  str_mv_rs2_t6

    /* --- rd==rs2: true identity, value unchanged --- */
    T_MV_ALIAS s0, str_mv_alias_s0
    T_MV_ALIAS a4, str_mv_alias_a4

    /* --- data patterns: rule out any partial-width copy --- */
    T_MV_VAL 0x0000000000000000, str_mv_val_zero
    T_MV_VAL 0xffffffffffffffff, str_mv_val_allones
    T_MV_VAL INTX_MIN, str_mv_val_signbit
    T_MV_VAL 0x123456789abcdef0, str_mv_val_walking
    T_MV_VAL 0x0000000000000001, str_mv_val_one

    /* --- invariant: C.MV must not modify rs2 --- */
    TEST_BEGIN str_mv_rs2_preserved
    LIX     t1, 0
    LIX     t2, 0x99999999
    mv      t3, t2
    .option rvc
    c.mv    t1, t2
    .option norvc
    la      a0, str_mv_rs2_preserved
    mv      a1, t3
    mv      a2, t2
    call    check

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

    /* T_ADD_RD rdreg, name -- sweep the full 5-bit rd field. Fixed
     * rs2=a6 (outside the sweep set). rdreg may be a0/a1/a2. */
    .macro T_ADD_RD rdreg, name
    TEST_BEGIN \name
    LIX     a6, 23
    LIX     \rdreg, 100
    .option rvc
    c.add   \rdreg, a6
    .option norvc
    mv      t2, \rdreg
    la      a0, \name
    LIX     a1, 123
    mv      a2, t2
    call    check
    .endm

    /* T_ADD_RS2 rs2reg, name -- sweep the full 5-bit rs2 field, fixed
     * rd=t1. rs2reg is consumed by c.add before a0-a2 are touched. */
    .macro T_ADD_RS2 rs2reg, name
    TEST_BEGIN \name
    LIX     \rs2reg, 23
    LIX     t1, 100
    .option rvc
    c.add   t1, \rs2reg
    .option norvc
    la      a0, \name
    LIX     a1, 123
    mv      a2, t1
    call    check
    .endm

    /* T_ADD_ALIAS reg, val, expect, name -- rd==rs2: reg += reg, i.e.
     * doubling. Two cases below cover both a clean double and one that
     * overflows 64 bits, so this also re-confirms full-width wraparound
     * (not just C.ADD's general value sweep) at the aliased encoding
     * specifically. */
    .macro T_ADD_ALIAS reg, val, expect, name
    TEST_BEGIN \name
    LIXT    \reg, \val
    .option rvc
    c.add   \reg, \reg
    .option norvc
    mv      t2, \reg
    la      a0, \name
    LIXT    a1, \expect
    mv      a2, t2
    call    check
    .endm

    /* T_ADD_VAL base, other, expect, name -- data-pattern sweep, fixed
     * rd=t1/rs2=t2. */
    .macro T_ADD_VAL base, other, expect, name
    TEST_BEGIN \name
    LIXT    t1, \base
    LIXT    t2, \other
    .option rvc
    c.add   t1, t2
    .option norvc
    la      a0, \name
    LIXT    a1, \expect
    mv      a2, t1
    call    check
    .endm

/* =======================================================================
 *  C.ADD : rd += rs2  (CR format, rd and rs2 both full 5-bit, non-zero;
 *          full 64-bit add, so -- unlike C.ADDW -- there's no 32-bit
 *          overflow/sign-extension question, just plain 64-bit modular
 *          wraparound to verify).
 * ======================================================================= */
test_c_add:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    /* --- every register in the full 5-bit rd field --- */
    T_ADD_RD ra,  str_add_rd_ra
    T_ADD_RD t0,  str_add_rd_t0
    T_ADD_RD s0,  str_add_rd_s0
    T_ADD_RD a0,  str_add_rd_a0
    T_ADD_RD a4,  str_add_rd_a4
    T_ADD_RD s2,  str_add_rd_s2
    T_ADD_RD s6,  str_add_rd_s6
    T_ADD_RD s10, str_add_rd_s10
    T_ADD_RD t6,  str_add_rd_t6

    /* --- every register in the full 5-bit rs2 field --- */
    T_ADD_RS2 ra,  str_add_rs2_ra
    T_ADD_RS2 t0,  str_add_rs2_t0
    T_ADD_RS2 s0,  str_add_rs2_s0
    T_ADD_RS2 a0,  str_add_rs2_a0
    T_ADD_RS2 a4,  str_add_rs2_a4
    T_ADD_RS2 s2,  str_add_rs2_s2
    T_ADD_RS2 s6,  str_add_rs2_s6
    T_ADD_RS2 s10, str_add_rs2_s10
    T_ADD_RS2 t6,  str_add_rs2_t6

    /* --- rd==rs2: doubling, both clean and 64-bit-overflowing --- */
    T_ADD_ALIAS s0, 0x123456789abcdef0, 0x2468acf13579bde0, str_add_alias_s0
    T_ADD_ALIAS a4, 0x8000000000000001, 0x0000000000000002, str_add_alias_a4

    /* --- data patterns: 64-bit wraparound and bit-pattern checks --- */
    T_ADD_VAL 0xffffffffffffffff, 0x0000000000000001, 0x0000000000000000, str_add_val_wrap
    T_ADD_VAL INTX_MAX, 1, INTX_MIN, str_add_val_maxpos
    T_ADD_VAL 0xfedcba9876543210, 0x123456789abcdef0, 0x1111111111111100, str_add_val_walking
    T_ADD_VAL 0xaaaaaaaaaaaaaaaa, 0x5555555555555555, 0xffffffffffffffff, str_add_val_complementary

    /* --- invariant: C.ADD must not modify rs2 --- */
    TEST_BEGIN str_add_rs2_preserved
    LIX     t1, 5
    LIX     t2, 7
    mv      t3, t2
    .option rvc
    c.add   t1, t2
    .option norvc
    la      a0, str_add_rs2_preserved
    mv      a1, t3
    mv      a2, t2
    call    check

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

    /* T_SLLI_REG reg, name -- sweep the full 5-bit rd(==rs1) field
     * (not restricted to x8-x15, unlike C.SRLI/C.SRAI's CB format).
     * Fixed shamt=8, walking-bit-pattern input. reg may be a0/a1/a2. */
    .macro T_SLLI_REG reg, name
    TEST_BEGIN \name
    LIXT    \reg, 0x0123456789abcdef
    .option rvc
    c.slli  \reg, 8
    .option norvc
    mv      t2, \reg
    la      a0, \name
    LIXT    a1, 0x23456789abcdef00
    mv      a2, t2
    call    check
    .endm

    /* T_SLLI_SHAMT shamt, expect, name -- sweep every individual bit of
     * the 6-bit shamt field (plus max and two mixed patterns; shamt=0,
     * though permitted by the RV64C spec text, is rejected by this
     * assembler as an illegal operand, same restriction already found
     * for C.SRLI/C.SRAI, so 1 is the smallest tested magnitude), fixed
     * register t1, input = all-ones so the number of zero bits shifted
     * in from the bottom is exactly readable off the expected value. */
    .macro T_SLLI_SHAMT shamt, expect, name
    TEST_BEGIN \name
    LIX     t1, 0xffffffffffffffff
    .option rvc
    c.slli  t1, \shamt
    .option norvc
    la      a0, \name
    LIX     a1, \expect
    mv      a2, t1
    call    check
    .endm

/* =======================================================================
 *  C.SLLI : rd/rs1 <<= shamt (logical, zero-fill from the bottom; bits
 *           shifted past bit 63 are discarded, not rotated). CI format,
 *           full 5-bit self-referencing register field (rd != x0),
 *           shamt is a 6-bit unsigned field (1-63 accepted here).
 * ======================================================================= */
test_c_slli:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    /* --- every register in the full 5-bit rd/rs1 field --- */
    T_SLLI_REG ra,  str_slli_reg_ra
    T_SLLI_REG t0,  str_slli_reg_t0
    T_SLLI_REG s0,  str_slli_reg_s0
    T_SLLI_REG a0,  str_slli_reg_a0
    T_SLLI_REG a4,  str_slli_reg_a4
    T_SLLI_REG s2,  str_slli_reg_s2
    T_SLLI_REG s6,  str_slli_reg_s6
    T_SLLI_REG s10, str_slli_reg_s10
    T_SLLI_REG t6,  str_slli_reg_t6

    /* --- every individual shamt-field bit, boundary, mixed patterns --- */
    T_SLLI_SHAMT 1,  0xfffffffffffffffe, str_slli_sh1  /* min accepted by assembler */
    T_SLLI_SHAMT 2,  0xfffffffffffffffc, str_slli_sh2
    T_SLLI_SHAMT 4,  0xfffffffffffffff0, str_slli_sh4
    T_SLLI_SHAMT 8,  0xffffffffffffff00, str_slli_sh8
    T_SLLI_SHAMT 16, 0xffffffffffff0000, str_slli_sh16
    .if XLEN == 64
    T_SLLI_SHAMT 32, 0xffffffff00000000, str_slli_sh32
    T_SLLI_SHAMT 63, 0x8000000000000000, str_slli_sh63  /* max */
    T_SLLI_SHAMT 21, 0xffffffffffe00000, str_slli_sh21  /* alt pattern 010101 */
    T_SLLI_SHAMT 42, 0xfffffc0000000000, str_slli_sh42  /* alt pattern 101010 */
    .else                               /* RV32C: 5-bit shamt (shamt[5] reserved) */
    T_SLLI_SHAMT 31, 0x80000000, str_slli_sh31  /* max */
    T_SLLI_SHAMT 21, 0xffe00000, str_slli_sh21  /* alt pattern 10101 */
    T_SLLI_SHAMT 10, 0xfffffc00, str_slli_sh10  /* alt pattern 01010 */
    .endif

    TEST_BEGIN str_slli_truncates
    /* --- truncation, not rotation: the bit shifted past bit 63 must be
     *     discarded, never reappear at bit 0 --- */
    LIX     t1, INTX_MIN | 1
    .option rvc
    c.slli  t1, 1
    .option norvc
    la      a0, str_slli_truncates
    LIX     a1, 0x0000000000000002
    mv      a2, t1
    call    check

    TEST_BEGIN str_slli_bit0_to_top
    /* --- complementary case: a single bit walking all the way from
     *     bit 0 to bit 63 --- */
    LIX     t1, 0x0000000000000001
    .option rvc
    c.slli  t1, XLEN - 1
    .option norvc
    la      a0, str_slli_bit0_to_top
    LIX     a1, INTX_MIN
    mv      a2, t1
    call    check

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  C.LWSP : rd = sign_extend32(*(uint32_t *)(sp + uimm)), rd != x0,
 *           full 5-bit rd field. CI format, uimm is an unsigned
 *           multiple of 4 in [0, 252] (6 bits, wider than C.LW's 5-bit
 *           field, scrambled as imm[5]|imm[4:2|7:6]).
 * ======================================================================= */

.macro T_LWSP_RD rdreg, name
    TEST_BEGIN \name
    LIX     t0, 0x11223344
    sw      t0, 0(sp)
    .option rvc
    c.lwsp  \rdreg, 0(sp)
    .option norvc
    mv      t2, \rdreg               /* capture before a0-a2 are reused */
    la      a0, \name
    LIX     a1, 0x11223344
    mv      a2, t2
    call    check
.endm

.macro T_LWSP_OFF off, name
    TEST_BEGIN \name
    LIX     t0, 0x11223344
    sw      t0, \off(sp)
    .option rvc
    c.lwsp  t1, \off(sp)
    .option norvc
    la      a0, \name
    LIX     a1, 0x11223344
    mv      a2, t1
    call    check
.endm

.macro T_LWSP_VAL val, expect64, name
    TEST_BEGIN \name
    LIX     t0, \val
    sw      t0, 0(sp)
    .option rvc
    c.lwsp  t1, 0(sp)
    .option norvc
    la      a0, \name
    LIX     a1, \expect64
    mv      a2, t1
    call    check
.endm

test_c_lwsp:
    addi    sp, sp, -336            /* room for test offsets 0-252(+4); ra
                                      * saved at the top of the frame (328)
                                      * so it can't collide with any
                                      * fixed-offset-0 test data below */
    REG_S   ra, 328(sp)

    /* --- every register in the full 5-bit rd field --- */
    T_LWSP_RD ra,  str_lwsp_rd_ra
    T_LWSP_RD t0,  str_lwsp_rd_t0
    T_LWSP_RD s0,  str_lwsp_rd_s0
    T_LWSP_RD a0,  str_lwsp_rd_a0
    T_LWSP_RD a4,  str_lwsp_rd_a4
    T_LWSP_RD s2,  str_lwsp_rd_s2
    T_LWSP_RD s6,  str_lwsp_rd_s6
    T_LWSP_RD s10, str_lwsp_rd_s10
    T_LWSP_RD t6,  str_lwsp_rd_t6

    /* --- every individual offset-field bit, boundary, mixed patterns --- */
    T_LWSP_OFF 4,   str_lwsp_off4     /* bit0 of uimm/4 */
    T_LWSP_OFF 8,   str_lwsp_off8
    T_LWSP_OFF 16,  str_lwsp_off16
    T_LWSP_OFF 32,  str_lwsp_off32
    T_LWSP_OFF 64,  str_lwsp_off64
    T_LWSP_OFF 128, str_lwsp_off128   /* max single bit */
    T_LWSP_OFF 252, str_lwsp_off252   /* max, all bits set */
    T_LWSP_OFF 84,  str_lwsp_off84    /* uimm/4 = 0b010101 */
    T_LWSP_OFF 168, str_lwsp_off168   /* uimm/4 = 0b101010 */

    /* --- data patterns: verify sign extension, same as C.LW --- */
    T_LWSP_VAL 0x00000000, 0x0000000000000000, str_lwsp_val_zero
    T_LWSP_VAL 0xffffffff, 0xffffffffffffffff, str_lwsp_val_allones
    T_LWSP_VAL 0x7fffffff, 0x000000007fffffff, str_lwsp_val_maxpos
    T_LWSP_VAL 0x80000000, 0xffffffff80000000, str_lwsp_val_minneg
    T_LWSP_VAL 0xaaaaaaaa, 0xffffffffaaaaaaaa, str_lwsp_val_alt1
    T_LWSP_VAL 0x55555555, 0x0000000055555555, str_lwsp_val_alt0
    T_LWSP_VAL 0xdeadbeef, 0xffffffffdeadbeef, str_lwsp_val_deadbeef
    T_LWSP_VAL 0x00000001, 0x0000000000000001, str_lwsp_val_one

    /* --- invariant: C.LWSP must not modify sp itself (pure read) --- */
    TEST_BEGIN str_lwsp_sp_preserved
    mv      t3, sp
    .option rvc
    c.lwsp  t1, 0(sp)
    .option norvc
    la      a0, str_lwsp_sp_preserved
    mv      a1, t3
    mv      a2, sp
    call    check

    REG_L   ra, 328(sp)
    addi    sp, sp, 336
    ret

/* =======================================================================
 *  C.SWSP : *(uint32_t *)(sp + uimm) = rs2[31:0], rs2 full 5-bit field
 *           (including x0, unlike C.LWSP's rd -- storing the
 *           always-zero register is legal and common). Same offset
 *           field as C.LWSP.
 * ======================================================================= */

.macro T_SWSP_RS2 rs2reg, name
    TEST_BEGIN \name
    LIX     \rs2reg, 0x11223344
    .option rvc
    c.swsp  \rs2reg, 0(sp)
    .option norvc
    LWUX    t2, 0(sp)
    la      a0, \name
    LIX     a1, 0x11223344
    mv      a2, t2
    call    check
.endm

.macro T_SWSP_OFF off, name
    TEST_BEGIN \name
    LIX     t1, 0x11223344
    .option rvc
    c.swsp  t1, \off(sp)
    .option norvc
    LWUX    t2, \off(sp)
    la      a0, \name
    LIX     a1, 0x11223344
    mv      a2, t2
    call    check
.endm

.macro T_SWSP_VAL val, name
    TEST_BEGIN \name
    LIX     t1, \val
    .option rvc
    c.swsp  t1, 0(sp)
    .option norvc
    LWUX    t2, 0(sp)
    la      a0, \name
    LIX     a1, \val
    mv      a2, t2
    call    check
.endm

test_c_swsp:
    addi    sp, sp, -336
    REG_S   ra, 328(sp)             /* saved above the test-offset range,
                                      * same rationale as test_c_lwsp */

    /* --- every register in the full 5-bit rs2 field --- */
    T_SWSP_RS2 ra,  str_swsp_rs2_ra
    T_SWSP_RS2 t0,  str_swsp_rs2_t0
    T_SWSP_RS2 s0,  str_swsp_rs2_s0
    T_SWSP_RS2 a0,  str_swsp_rs2_a0
    T_SWSP_RS2 a4,  str_swsp_rs2_a4
    T_SWSP_RS2 s2,  str_swsp_rs2_s2
    T_SWSP_RS2 s6,  str_swsp_rs2_s6
    T_SWSP_RS2 s10, str_swsp_rs2_s10
    T_SWSP_RS2 t6,  str_swsp_rs2_t6

    TEST_BEGIN str_swsp_rs2_x0
    /* --- rs2=x0: storing the always-zero register is a distinct,
     *     legal case C.LWSP's rd sweep can't cover (rd=x0 is rejected
     *     there) --- */
    LIX     t0, 0xdeadbeef
    sw      t0, 0(sp)
    .option rvc
    c.swsp  x0, 0(sp)
    .option norvc
    LWUX    t2, 0(sp)
    la      a0, str_swsp_rs2_x0
    LIX     a1, 0
    mv      a2, t2
    call    check

    /* --- every individual offset-field bit, boundary, mixed patterns --- */
    T_SWSP_OFF 4,   str_swsp_off4
    T_SWSP_OFF 8,   str_swsp_off8
    T_SWSP_OFF 16,  str_swsp_off16
    T_SWSP_OFF 32,  str_swsp_off32
    T_SWSP_OFF 64,  str_swsp_off64
    T_SWSP_OFF 128, str_swsp_off128
    T_SWSP_OFF 252, str_swsp_off252
    T_SWSP_OFF 84,  str_swsp_off84
    T_SWSP_OFF 168, str_swsp_off168

    /* --- data patterns --- */
    T_SWSP_VAL 0x00000000, str_swsp_val_zero
    T_SWSP_VAL 0xffffffff, str_swsp_val_allones
    T_SWSP_VAL 0x7fffffff, str_swsp_val_maxpos
    T_SWSP_VAL 0x80000000, str_swsp_val_minneg
    T_SWSP_VAL 0xaaaaaaaa, str_swsp_val_alt1
    T_SWSP_VAL 0x55555555, str_swsp_val_alt0
    T_SWSP_VAL 0xdeadbeef, str_swsp_val_deadbeef
    T_SWSP_VAL 0x00000001, str_swsp_val_one

    /* --- invariant: C.SWSP must not modify sp itself --- */
    TEST_BEGIN str_swsp_sp_preserved
    mv      t3, sp
    LIX     t1, 0x11223344
    .option rvc
    c.swsp  t1, 0(sp)
    .option norvc
    la      a0, str_swsp_sp_preserved
    mv      a1, t3
    mv      a2, sp
    call    check

    REG_L   ra, 328(sp)
    addi    sp, sp, 336
    ret

/* =======================================================================
 *  C.LDSP : rd = *(uint64_t *)(sp + uimm), rd != x0, full 5-bit rd
 *           field. CI format, uimm is an unsigned multiple of 8 in
 *           [0, 504] (6 bits, scrambled as imm[5]|imm[4:3|8:6]). No
 *           sign-extension question -- the full 64 bits load exactly.
 * ======================================================================= */

.macro T_LDSP_RD rdreg, name
    TEST_BEGIN \name
    LIX     t0, 0x1122334455667788
    REG_S   t0, 0(sp)
    .option rvc
    c.ldsp  \rdreg, 0(sp)
    .option norvc
    mv      t2, \rdreg
    la      a0, \name
    LIX     a1, 0x1122334455667788
    mv      a2, t2
    call    check
.endm

.macro T_LDSP_OFF off, name
    TEST_BEGIN \name
    LIX     t0, 0x1122334455667788
    sd      t0, \off(sp)
    .option rvc
    c.ldsp  t1, \off(sp)
    .option norvc
    la      a0, \name
    LIX     a1, 0x1122334455667788
    mv      a2, t1
    call    check
.endm

.macro T_LDSP_VAL val, name
    TEST_BEGIN \name
    LIX     t0, \val
    REG_S   t0, 0(sp)
    .option rvc
    c.ldsp  t1, 0(sp)
    .option norvc
    la      a0, \name
    LIX     a1, \val
    mv      a2, t1
    call    check
.endm

    .if XLEN == 64                  /* RV64C-only (C.FLWSP/C.FSWSP on RV32) */
test_c_ldsp:
    addi    sp, sp, -640            /* room for test offsets 0-504(+8); ra
                                      * saved at the top of the frame (632) */
    REG_S   ra, 632(sp)

    /* --- every register in the full 5-bit rd field --- */
    T_LDSP_RD ra,  str_ldsp_rd_ra
    T_LDSP_RD t0,  str_ldsp_rd_t0
    T_LDSP_RD s0,  str_ldsp_rd_s0
    T_LDSP_RD a0,  str_ldsp_rd_a0
    T_LDSP_RD a4,  str_ldsp_rd_a4
    T_LDSP_RD s2,  str_ldsp_rd_s2
    T_LDSP_RD s6,  str_ldsp_rd_s6
    T_LDSP_RD s10, str_ldsp_rd_s10
    T_LDSP_RD t6,  str_ldsp_rd_t6

    /* --- every individual offset-field bit, boundary, mixed patterns --- */
    T_LDSP_OFF 8,   str_ldsp_off8
    T_LDSP_OFF 16,  str_ldsp_off16
    T_LDSP_OFF 32,  str_ldsp_off32
    T_LDSP_OFF 64,  str_ldsp_off64
    T_LDSP_OFF 128, str_ldsp_off128
    T_LDSP_OFF 256, str_ldsp_off256   /* max single bit */
    T_LDSP_OFF 504, str_ldsp_off504   /* max, all bits set */
    T_LDSP_OFF 168, str_ldsp_off168   /* uimm/8 = 0b010101 */
    T_LDSP_OFF 336, str_ldsp_off336   /* uimm/8 = 0b101010 */

    /* --- data patterns --- */
    T_LDSP_VAL 0x0000000000000000, str_ldsp_val_zero
    T_LDSP_VAL 0xffffffffffffffff, str_ldsp_val_allones
    T_LDSP_VAL 0x7fffffffffffffff, str_ldsp_val_maxpos
    T_LDSP_VAL 0x8000000000000000, str_ldsp_val_minneg
    T_LDSP_VAL 0xaaaaaaaaaaaaaaaa, str_ldsp_val_alt1
    T_LDSP_VAL 0x5555555555555555, str_ldsp_val_alt0
    T_LDSP_VAL 0x0123456789abcdef, str_ldsp_val_walking
    T_LDSP_VAL 0x0000000000000001, str_ldsp_val_one

    /* --- invariant: C.LDSP must not modify sp itself (pure read) --- */
    TEST_BEGIN str_ldsp_sp_preserved
    mv      t3, sp
    .option rvc
    c.ldsp  t1, 0(sp)
    .option norvc
    la      a0, str_ldsp_sp_preserved
    mv      a1, t3
    mv      a2, sp
    call    check

    REG_L   ra, 632(sp)
    addi    sp, sp, 640
    ret

    .endif

/* =======================================================================
 *  C.SDSP : *(uint64_t *)(sp + uimm) = rs2, rs2 full 5-bit field
 *           (including x0). Same offset field as C.LDSP.
 * ======================================================================= */

.macro T_SDSP_RS2 rs2reg, name
    TEST_BEGIN \name
    LIX     \rs2reg, 0x1122334455667788
    .option rvc
    c.sdsp  \rs2reg, 0(sp)
    .option norvc
    REG_L   t2, 0(sp)
    la      a0, \name
    LIX     a1, 0x1122334455667788
    mv      a2, t2
    call    check
.endm

.macro T_SDSP_OFF off, name
    TEST_BEGIN \name
    LIX     t1, 0x1122334455667788
    .option rvc
    c.sdsp  t1, \off(sp)
    .option norvc
    ld      t2, \off(sp)
    la      a0, \name
    LIX     a1, 0x1122334455667788
    mv      a2, t2
    call    check
.endm

.macro T_SDSP_VAL val, name
    TEST_BEGIN \name
    LIX     t1, \val
    .option rvc
    c.sdsp  t1, 0(sp)
    .option norvc
    REG_L   t2, 0(sp)
    la      a0, \name
    LIX     a1, \val
    mv      a2, t2
    call    check
.endm

    .if XLEN == 64                  /* RV64C-only (C.FLWSP/C.FSWSP on RV32) */
test_c_sdsp:
    addi    sp, sp, -640
    REG_S   ra, 632(sp)             /* saved above the test-offset range */

    /* --- every register in the full 5-bit rs2 field --- */
    T_SDSP_RS2 ra,  str_sdsp_rs2_ra
    T_SDSP_RS2 t0,  str_sdsp_rs2_t0
    T_SDSP_RS2 s0,  str_sdsp_rs2_s0
    T_SDSP_RS2 a0,  str_sdsp_rs2_a0
    T_SDSP_RS2 a4,  str_sdsp_rs2_a4
    T_SDSP_RS2 s2,  str_sdsp_rs2_s2
    T_SDSP_RS2 s6,  str_sdsp_rs2_s6
    T_SDSP_RS2 s10, str_sdsp_rs2_s10
    T_SDSP_RS2 t6,  str_sdsp_rs2_t6

    /* --- rs2=x0: storing the always-zero register --- */
    TEST_BEGIN str_sdsp_rs2_x0
    LIXT    t0, 0xdeadbeefdeadbeef
    REG_S   t0, 0(sp)
    .option rvc
    c.sdsp  x0, 0(sp)
    .option norvc
    REG_L   t2, 0(sp)
    la      a0, str_sdsp_rs2_x0
    LIX     a1, 0
    mv      a2, t2
    call    check

    /* --- every individual offset-field bit, boundary, mixed patterns --- */
    T_SDSP_OFF 8,   str_sdsp_off8
    T_SDSP_OFF 16,  str_sdsp_off16
    T_SDSP_OFF 32,  str_sdsp_off32
    T_SDSP_OFF 64,  str_sdsp_off64
    T_SDSP_OFF 128, str_sdsp_off128
    T_SDSP_OFF 256, str_sdsp_off256
    T_SDSP_OFF 504, str_sdsp_off504
    T_SDSP_OFF 168, str_sdsp_off168
    T_SDSP_OFF 336, str_sdsp_off336

    /* --- data patterns --- */
    T_SDSP_VAL 0x0000000000000000, str_sdsp_val_zero
    T_SDSP_VAL 0xffffffffffffffff, str_sdsp_val_allones
    T_SDSP_VAL 0x7fffffffffffffff, str_sdsp_val_maxpos
    T_SDSP_VAL 0x8000000000000000, str_sdsp_val_minneg
    T_SDSP_VAL 0xaaaaaaaaaaaaaaaa, str_sdsp_val_alt1
    T_SDSP_VAL 0x5555555555555555, str_sdsp_val_alt0
    T_SDSP_VAL 0x0123456789abcdef, str_sdsp_val_walking
    T_SDSP_VAL 0x0000000000000001, str_sdsp_val_one

    /* --- invariant: C.SDSP must not modify sp itself --- */
    TEST_BEGIN str_sdsp_sp_preserved
    mv      t3, sp
    LIX     t1, 0x1122334455667788
    .option rvc
    c.sdsp  t1, 0(sp)
    .option norvc
    la      a0, str_sdsp_sp_preserved
    mv      a1, t3
    mv      a2, sp
    call    check

    REG_L   ra, 632(sp)
    addi    sp, sp, 640
    ret

    .endif

/* =======================================================================
 *  C.EBREAK : CR format, single fixed encoding (rd/rs1=0, rs2=0) --
 *  there is no register or immediate field to sweep, so "coverage"
 *  here means checking the architectural invariants a debugger relies
 *  on rather than walking operand combinations:
 *    - the trap really fires, with mcause reporting exactly 3
 *      (breakpoint), not some other/wrong cause
 *    - mepc lands exactly on the C.EBREAK instruction itself (not off
 *      by one in either direction) -- this is the property a real
 *      debugger needs to correctly identify and single-step over the
 *      breakpoint
 *    - registers uninvolved in the trap survive the full trap
 *      round-trip (M-mode entry, handler, mret) untouched
 *    - execution resumes at exactly the next instruction, exactly
 *      once per EBREAK -- checked by firing it three times in a row,
 *      each followed by a counter bump, and separately cross-checking
 *      common.S's own ebreak_hit_count (bumped once per trap by the
 *      handler) advanced by exactly the same amount
 * ======================================================================= */
test_c_ebreak:
    TEST_BEGIN str_ebreak_caught
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    /* --- basic catch: flag gets set, execution resumes --- */
    la      t0, ebreak_flag
    sw      zero, 0(t0)
    .option rvc
    c.ebreak
    .option norvc
    la      t0, ebreak_flag
    lw      t1, 0(t0)
    la      a0, str_ebreak_caught
    LIX     a1, 1
    mv      a2, t1
    call    check

    /* --- mcause reports exactly 3 (breakpoint) --- */
    TEST_BEGIN str_ebreak_mcause
    la      t0, ebreak_mcause
    lw      t1, 0(t0)
    la      a0, str_ebreak_mcause
    LIX     a1, 3
    mv      a2, t1
    call    check

    /* --- mepc lands exactly on the C.EBREAK instruction that faulted --- */
    TEST_BEGIN str_ebreak_mepc
.Lebreak_pc_marker:
    .option rvc
    c.ebreak
    .option norvc
    la      t0, ebreak_mepc
    REG_L   t1, 0(t0)
    la      a0, str_ebreak_mepc
    la      a1, .Lebreak_pc_marker
    mv      a2, t1
    call    check

    /* --- registers uninvolved in the trap survive the round-trip --- */
    TEST_BEGIN str_ebreak_regs_s0
    LIXT    s0, 0x1111111111111111
    LIXT    s1, 0x2222222222222222
    LIXT    s3, 0x3333333333333333
    .option rvc
    c.ebreak
    .option norvc
    la      a0, str_ebreak_regs_s0
    LIXT    a1, 0x1111111111111111
    mv      a2, s0
    call    check
    TEST_BEGIN str_ebreak_regs_s1
    la      a0, str_ebreak_regs_s1
    LIXT    a1, 0x2222222222222222
    mv      a2, s1
    call    check
    TEST_BEGIN str_ebreak_regs_s3
    la      a0, str_ebreak_regs_s3
    LIXT    a1, 0x3333333333333333
    mv      a2, s3
    call    check

    TEST_BEGIN str_ebreak_resume_count
    /* --- three EBREAKs in a row, each must fire and resume exactly
     *     once, both from this test's own point of view (a local
     *     counter bumped after each one) and from the trap handler's
     *     point of view (ebreak_hit_count's delta) --- */
    la      t0, ebreak_hit_count
    lw      t2, 0(t0)               /* baseline hit count */
    LIX     s4, 0                   /* local "resumed N times" counter */
    .option rvc
    c.ebreak
    .option norvc
    addi    s4, s4, 1
    .option rvc
    c.ebreak
    .option norvc
    addi    s4, s4, 1
    .option rvc
    c.ebreak
    .option norvc
    addi    s4, s4, 1
    la      a0, str_ebreak_resume_count
    LIX     a1, 3
    mv      a2, s4
    call    check

    TEST_BEGIN str_ebreak_hit_delta
    la      t0, ebreak_hit_count
    lw      t3, 0(t0)
    sub     t3, t3, t2              /* delta since baseline */
    la      a0, str_ebreak_hit_delta
    LIX     a1, 3
    mv      a2, t3
    call    check

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* T_JR_REG reg, name -- sweep the full 5-bit rs1 field (rs1 != x0;
 * not restricted to x8-x15). Loads reg with a local target address
 * and confirms C.JR actually lands there. reg may be ra -- s4 (the
 * "did we land correctly" marker) is used instead of a0-a2 so there's
 * no collision to worry about regardless of which register is under
 * test, and s4 survives check() calls (check() only ever touches
 * t0-t6/a0-a2, plus explicitly saves/restores s0/s1). */
.macro T_JR_REG reg, name
    TEST_BEGIN \name
    LIX     s4, 0
    la      \reg, 1f
    .option rvc
    c.jr    \reg
    .option norvc
    LIX     s4, 999                 /* poison: only hit if C.JR failed to jump */
1:
    la      a0, \name
    LIX     a1, 0
    mv      a2, s4
    call    check
.endm

/* =======================================================================
 *  C.JR : CR format, rd=x0/rs2=x0 implied, rs1 != x0 is the sole
 *         operand -- full 5-bit register field (unlike the CB/CA/CL
 *         formats elsewhere, this isn't restricted to x8-x15).
 *         Unconditional jump to the address in rs1; unlike C.JALR it
 *         does not link ra, which is the one behavioral property that
 *         actually distinguishes the two encodings and is worth
 *         checking explicitly rather than assuming.
 * ======================================================================= */
test_c_jr:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    /* --- every register in the full 5-bit rs1 field --- */
    T_JR_REG ra,  str_jr_reg_ra
    T_JR_REG t0,  str_jr_reg_t0
    T_JR_REG s0,  str_jr_reg_s0
    T_JR_REG a0,  str_jr_reg_a0
    T_JR_REG a4,  str_jr_reg_a4
    T_JR_REG s2,  str_jr_reg_s2
    T_JR_REG s6,  str_jr_reg_s6
    T_JR_REG s10, str_jr_reg_s10
    T_JR_REG t6,  str_jr_reg_t6

    TEST_BEGIN str_jr_rs1_preserved
    /* --- invariant: rs1 itself is unmodified (pure read of the
     *     target address, no write-back) --- */
    la      t1, 1f
    mv      t2, t1                  /* remember the address we loaded */
    .option rvc
    c.jr    t1
    .option norvc
    LIX     s4, 999
1:
    la      a0, str_jr_rs1_preserved
    mv      a1, t2
    mv      a2, t1
    call    check

    TEST_BEGIN str_jr_no_link
    /* --- invariant: C.JR does NOT link -- ra must be untouched when
     *     jumping via a different register. This is the one property
     *     that actually separates C.JR from C.JALR. --- */
    la      t1, 1f
    LIXT    ra, 0x1234567812345678  /* poison ra directly */
    .option rvc
    c.jr    t1                      /* jump via t1, NOT ra */
    .option norvc
    LIX     s4, 999                 /* unreachable: the jump is unconditional */
1:
    mv      t2, ra                  /* capture before the next jal clobbers it */
    la      a0, str_jr_no_link
    LIXT    a1, 0x1234567812345678
    mv      a2, t2
    call    check

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* T_JALR_REG reg, name_landed, name_link -- sweep the full 5-bit rs1
 * field. Verifies two independent things per register: (1) execution
 * actually lands at the target, and (2) ra ends up holding exactly
 * the address of the instruction immediately following the C.JALR
 * (pc+2). reg may be ra itself -- that's the rd==rs1 aliasing case
 * (rd is always ra for C.JALR): the old rs1 value must be read as the
 * jump target *before* rd=ra is overwritten with the link address, so
 * including ra in this sweep exercises that ordering directly rather
 * than needing a separate dedicated test. The link value is captured
 * into s5 (not a t-register) since it must survive across two check()
 * calls, and check() clobbers t0-t6. */
.macro T_JALR_REG reg, name_landed, name_link
    TEST_BEGIN \name_landed
    LIX     s4, 0
    la      \reg, 1f
    .option rvc
    c.jalr  \reg
    .option norvc
.Ljalr_retaddr\@:
    LIX     s4, 999                 /* poison: only hit if C.JALR failed to jump */
1:
    mv      s5, ra                  /* capture link value; survives check() calls */
    la      a0, \name_landed
    LIX     a1, 0
    mv      a2, s4
    call    check

    TEST_BEGIN \name_link
    la      a0, \name_link
    la      a1, .Ljalr_retaddr\@
    mv      a2, s5
    call    check
.endm

/* =======================================================================
 *  C.JALR : CR format, rd=ra/rs2=x0 implied, rs1 != x0 is the sole
 *           operand -- full 5-bit register field, like C.JR. Jumps to
 *           the address in rs1 *and* links ra = pc+2, which is the
 *           one behavioral property that actually distinguishes it
 *           from C.JR (checked directly, per register, rather than
 *           just trusting the jump landed somewhere sensible).
 * ======================================================================= */
test_c_jalr:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    /* --- every register in the full 5-bit rs1 field, including ra
     *     itself (the rd==rs1 aliasing case) --- */
    T_JALR_REG ra,  str_jalr_landed_ra,  str_jalr_link_ra
    T_JALR_REG t0,  str_jalr_landed_t0,  str_jalr_link_t0
    T_JALR_REG s0,  str_jalr_landed_s0,  str_jalr_link_s0
    T_JALR_REG a0,  str_jalr_landed_a0,  str_jalr_link_a0
    T_JALR_REG a4,  str_jalr_landed_a4,  str_jalr_link_a4
    T_JALR_REG s2,  str_jalr_landed_s2,  str_jalr_link_s2
    T_JALR_REG s6,  str_jalr_landed_s6,  str_jalr_link_s6
    T_JALR_REG s10, str_jalr_landed_s10, str_jalr_link_s10
    T_JALR_REG t6,  str_jalr_landed_t6,  str_jalr_link_t6

    TEST_BEGIN str_jalr_rs1_preserved
    /* --- invariant: when rs1 != ra, rs1 itself is unmodified (only
     *     rd=ra is written; rs1 is purely read for the jump target) --- */
    la      t1, 1f
    mv      t2, t1                  /* remember the address we loaded */
    .option rvc
    c.jalr  t1
    .option norvc
    LIX     s4, 999
1:
    la      a0, str_jalr_rs1_preserved
    mv      a1, t2
    mv      a2, t1
    call    check

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  QUADRANT 2 : C.SLLI, C.LWSP, C.LDSP, C.JR, C.MV, C.EBREAK, C.JALR,
 *               C.ADD, C.SWSP, C.SDSP
 * ======================================================================= */
tests_c_quadrant2:
    addi    sp, sp, -80          /* JR/JALR/EBREAK below don't need much stack;
                                   * the *WSP/*SP tests allocate their own much
                                   * larger frames internally (see test_c_lwsp
                                   * etc.) rather than relying on this one */
    REG_S   ra, 0(sp)

    /* --- C.SLLI: see test_c_slli --- */
    jal     ra, test_c_slli

    /* --- C.SWSP: see test_c_swsp --- */
    jal     ra, test_c_swsp

    /* --- C.LWSP: see test_c_lwsp --- */
    jal     ra, test_c_lwsp

    /* --- C.SDSP: see test_c_sdsp --- */
    .if XLEN == 64
    jal     ra, test_c_sdsp
    .endif

    /* --- C.LDSP: see test_c_ldsp --- */
    .if XLEN == 64
    jal     ra, test_c_ldsp
    .endif

    jal     ra, test_c_mv
    jal     ra, test_c_add


    /* --- C.JR: see test_c_jr --- */
    jal     ra, test_c_jr

    /* --- C.JALR: see test_c_jalr --- */
    jal     ra, test_c_jalr

    /* --- C.EBREAK: see test_c_ebreak --- */
    jal     ra, test_c_ebreak

    jal     ra, bitx_c_quadrant2

    REG_L   ra, 0(sp)
    addi    sp, sp, 80
    ret

bitx_c_quadrant2:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    BX_POOL BX_Q2_VA, BX_Q2_VB
    /* shamt 0 isn't encodable, so background shamt 1 */
    .if XLEN == 64
    BX_E_RI5 BX_C_SLLI, "C.SLLI", 7, "0x1,0x2,0x4,0x8,0x10,0x20", 1
    .else
    BX_E_RI5 BX_C_SLLI, "C.SLLI", 7, "0x1,0x2,0x4,0x8,0x10", 1
    .endif
    BX_E_RI5 BX_C_LSP, "c.lwsp, lw, C.LWSP", 7, "0x4,0x8,0x10,0x20,0x40,0x80", 0
    .if XLEN == 64
    BX_E_RI5 BX_C_LSP, "c.ldsp, ld, C.LDSP", 7, "0x8,0x10,0x20,0x40,0x80,0x100", 0
    .endif
    BX_E_RI5 BX_C_SSP, "c.swsp, 4, C.SWSP", 29, "0x4,0x8,0x10,0x20,0x40,0x80", 0
    .if XLEN == 64
    BX_E_RI5 BX_C_SSP, "c.sdsp, 8, C.SDSP", 29, "0x8,0x10,0x20,0x40,0x80,0x100", 0
    .endif
    BX_E_RR5 BX_C_CR, "c.mv, C.MV", 7, 29
    BX_E_RR5 BX_C_CR, "c.add, C.ADD", 7, 29
    call    bx_sled_init
    BX_E_R5 BX_C_CJR, "c.jr, C.JR"
    BX_E_R5 BX_C_CJR, "c.jalr, C.JALR"

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  Strings
 * ======================================================================= */
    .section .rodata
str_slli_reg_ra:  .asciz "C.SLLI rd=ra(x1)"
str_slli_reg_t0:  .asciz "C.SLLI rd=t0(x5)"
str_slli_reg_s0:  .asciz "C.SLLI rd=s0(x8)"
str_slli_reg_a0:  .asciz "C.SLLI rd=a0(x10)"
str_slli_reg_a4:  .asciz "C.SLLI rd=a4(x14)"
str_slli_reg_s2:  .asciz "C.SLLI rd=s2(x18)"
str_slli_reg_s6:  .asciz "C.SLLI rd=s6(x22)"
str_slli_reg_s10: .asciz "C.SLLI rd=s10(x26)"
str_slli_reg_t6:  .asciz "C.SLLI rd=t6(x31)"
    .if XLEN == 32
str_slli_sh31: .asciz "C.SLLI shamt=31 (max)"
str_slli_sh10: .asciz "C.SLLI shamt=10 (alt pattern 01010)"
    .endif
str_slli_sh1:  .asciz "C.SLLI shamt=1 (min accepted by assembler)"
str_slli_sh2:  .asciz "C.SLLI shamt=2"
str_slli_sh4:  .asciz "C.SLLI shamt=4"
str_slli_sh8:  .asciz "C.SLLI shamt=8"
str_slli_sh16: .asciz "C.SLLI shamt=16"
str_slli_sh32: .asciz "C.SLLI shamt=32"
str_slli_sh63: .asciz "C.SLLI shamt=63 (max)"
str_slli_sh21: .asciz "C.SLLI shamt=21 (alt pattern 010101)"
str_slli_sh42: .asciz "C.SLLI shamt=42 (alt pattern 101010)"
str_slli_truncates:   .asciz "C.SLLI truncates, does not rotate"
    .if XLEN == 64
str_slli_bit0_to_top: .asciz "C.SLLI bit0 walks to bit63 at shamt=63"
    .else
str_slli_bit0_to_top: .asciz "C.SLLI bit0 walks to bit31 at shamt=31"
    .endif

str_lwsp_rd_ra:  .asciz "C.LWSP rd=ra(x1)"
str_lwsp_rd_t0:  .asciz "C.LWSP rd=t0(x5)"
str_lwsp_rd_s0:  .asciz "C.LWSP rd=s0(x8)"
str_lwsp_rd_a0:  .asciz "C.LWSP rd=a0(x10)"
str_lwsp_rd_a4:  .asciz "C.LWSP rd=a4(x14)"
str_lwsp_rd_s2:  .asciz "C.LWSP rd=s2(x18)"
str_lwsp_rd_s6:  .asciz "C.LWSP rd=s6(x22)"
str_lwsp_rd_s10: .asciz "C.LWSP rd=s10(x26)"
str_lwsp_rd_t6:  .asciz "C.LWSP rd=t6(x31)"
str_lwsp_off4:   .asciz "C.LWSP offset=4"
str_lwsp_off8:   .asciz "C.LWSP offset=8"
str_lwsp_off16:  .asciz "C.LWSP offset=16"
str_lwsp_off32:  .asciz "C.LWSP offset=32"
str_lwsp_off64:  .asciz "C.LWSP offset=64"
str_lwsp_off128: .asciz "C.LWSP offset=128 (max single bit)"
str_lwsp_off252: .asciz "C.LWSP offset=252 (max, all bits)"
str_lwsp_off84:  .asciz "C.LWSP offset=84 (alt pattern 010101)"
str_lwsp_off168: .asciz "C.LWSP offset=168 (alt pattern 101010)"
str_lwsp_val_zero:     .asciz "C.LWSP value=0x00000000"
    .if XLEN == 64
str_lwsp_val_allones:  .asciz "C.LWSP value=0xffffffff (sign-extends)"
    .else
str_lwsp_val_allones:  .asciz "C.LWSP value=0xffffffff (bit 31 set)"
    .endif
    .if XLEN == 64
str_lwsp_val_maxpos:   .asciz "C.LWSP value=0x7fffffff (no sign-ext)"
    .else
str_lwsp_val_maxpos:   .asciz "C.LWSP value=0x7fffffff (bit 31 clear)"
    .endif
    .if XLEN == 64
str_lwsp_val_minneg:   .asciz "C.LWSP value=0x80000000 (sign-extends)"
    .else
str_lwsp_val_minneg:   .asciz "C.LWSP value=0x80000000 (bit 31 set)"
    .endif
    .if XLEN == 64
str_lwsp_val_alt1:     .asciz "C.LWSP value=0xaaaaaaaa (sign-extends)"
    .else
str_lwsp_val_alt1:     .asciz "C.LWSP value=0xaaaaaaaa (bit 31 set)"
    .endif
    .if XLEN == 64
str_lwsp_val_alt0:     .asciz "C.LWSP value=0x55555555 (no sign-ext)"
    .else
str_lwsp_val_alt0:     .asciz "C.LWSP value=0x55555555 (bit 31 clear)"
    .endif
    .if XLEN == 64
str_lwsp_val_deadbeef: .asciz "C.LWSP value=0xdeadbeef (sign-extends)"
    .else
str_lwsp_val_deadbeef: .asciz "C.LWSP value=0xdeadbeef (bit 31 set)"
    .endif
str_lwsp_val_one:      .asciz "C.LWSP value=0x00000001"
str_lwsp_sp_preserved: .asciz "C.LWSP sp unmodified (pure read)"

str_swsp_rs2_ra:  .asciz "C.SWSP rs2=ra(x1)"
str_swsp_rs2_t0:  .asciz "C.SWSP rs2=t0(x5)"
str_swsp_rs2_s0:  .asciz "C.SWSP rs2=s0(x8)"
str_swsp_rs2_a0:  .asciz "C.SWSP rs2=a0(x10)"
str_swsp_rs2_a4:  .asciz "C.SWSP rs2=a4(x14)"
str_swsp_rs2_s2:  .asciz "C.SWSP rs2=s2(x18)"
str_swsp_rs2_s6:  .asciz "C.SWSP rs2=s6(x22)"
str_swsp_rs2_s10: .asciz "C.SWSP rs2=s10(x26)"
str_swsp_rs2_t6:  .asciz "C.SWSP rs2=t6(x31)"
str_swsp_rs2_x0:  .asciz "C.SWSP rs2=x0 (always-zero register)"
str_swsp_off4:   .asciz "C.SWSP offset=4"
str_swsp_off8:   .asciz "C.SWSP offset=8"
str_swsp_off16:  .asciz "C.SWSP offset=16"
str_swsp_off32:  .asciz "C.SWSP offset=32"
str_swsp_off64:  .asciz "C.SWSP offset=64"
str_swsp_off128: .asciz "C.SWSP offset=128 (max single bit)"
str_swsp_off252: .asciz "C.SWSP offset=252 (max, all bits)"
str_swsp_off84:  .asciz "C.SWSP offset=84 (alt pattern 010101)"
str_swsp_off168: .asciz "C.SWSP offset=168 (alt pattern 101010)"
str_swsp_val_zero:     .asciz "C.SWSP value=0x00000000"
str_swsp_val_allones:  .asciz "C.SWSP value=0xffffffff"
str_swsp_val_maxpos:   .asciz "C.SWSP value=0x7fffffff"
str_swsp_val_minneg:   .asciz "C.SWSP value=0x80000000"
str_swsp_val_alt1:     .asciz "C.SWSP value=0xaaaaaaaa"
str_swsp_val_alt0:     .asciz "C.SWSP value=0x55555555"
str_swsp_val_deadbeef: .asciz "C.SWSP value=0xdeadbeef"
str_swsp_val_one:      .asciz "C.SWSP value=0x00000001"
str_swsp_sp_preserved: .asciz "C.SWSP sp unmodified"

str_ldsp_rd_ra:  .asciz "C.LDSP rd=ra(x1)"
str_ldsp_rd_t0:  .asciz "C.LDSP rd=t0(x5)"
str_ldsp_rd_s0:  .asciz "C.LDSP rd=s0(x8)"
str_ldsp_rd_a0:  .asciz "C.LDSP rd=a0(x10)"
str_ldsp_rd_a4:  .asciz "C.LDSP rd=a4(x14)"
str_ldsp_rd_s2:  .asciz "C.LDSP rd=s2(x18)"
str_ldsp_rd_s6:  .asciz "C.LDSP rd=s6(x22)"
str_ldsp_rd_s10: .asciz "C.LDSP rd=s10(x26)"
str_ldsp_rd_t6:  .asciz "C.LDSP rd=t6(x31)"
str_ldsp_off8:   .asciz "C.LDSP offset=8"
str_ldsp_off16:  .asciz "C.LDSP offset=16"
str_ldsp_off32:  .asciz "C.LDSP offset=32"
str_ldsp_off64:  .asciz "C.LDSP offset=64"
str_ldsp_off128: .asciz "C.LDSP offset=128"
str_ldsp_off256: .asciz "C.LDSP offset=256 (max single bit)"
str_ldsp_off504: .asciz "C.LDSP offset=504 (max, all bits)"
str_ldsp_off168: .asciz "C.LDSP offset=168 (alt pattern 010101)"
str_ldsp_off336: .asciz "C.LDSP offset=336 (alt pattern 101010)"
str_ldsp_val_zero:    .asciz "C.LDSP value=0x0000000000000000"
str_ldsp_val_allones: .asciz "C.LDSP value=0xffffffffffffffff"
str_ldsp_val_maxpos:  .asciz "C.LDSP value=0x7fffffffffffffff"
str_ldsp_val_minneg:  .asciz "C.LDSP value=0x8000000000000000"
str_ldsp_val_alt1:    .asciz "C.LDSP value=0xaaaaaaaaaaaaaaaa"
str_ldsp_val_alt0:    .asciz "C.LDSP value=0x5555555555555555"
str_ldsp_val_walking: .asciz "C.LDSP value=0x0123456789abcdef"
str_ldsp_val_one:     .asciz "C.LDSP value=0x0000000000000001"
str_ldsp_sp_preserved: .asciz "C.LDSP sp unmodified (pure read)"

str_sdsp_rs2_ra:  .asciz "C.SDSP rs2=ra(x1)"
str_sdsp_rs2_t0:  .asciz "C.SDSP rs2=t0(x5)"
str_sdsp_rs2_s0:  .asciz "C.SDSP rs2=s0(x8)"
str_sdsp_rs2_a0:  .asciz "C.SDSP rs2=a0(x10)"
str_sdsp_rs2_a4:  .asciz "C.SDSP rs2=a4(x14)"
str_sdsp_rs2_s2:  .asciz "C.SDSP rs2=s2(x18)"
str_sdsp_rs2_s6:  .asciz "C.SDSP rs2=s6(x22)"
str_sdsp_rs2_s10: .asciz "C.SDSP rs2=s10(x26)"
str_sdsp_rs2_t6:  .asciz "C.SDSP rs2=t6(x31)"
str_sdsp_rs2_x0:  .asciz "C.SDSP rs2=x0 (always-zero register)"
str_sdsp_off8:   .asciz "C.SDSP offset=8"
str_sdsp_off16:  .asciz "C.SDSP offset=16"
str_sdsp_off32:  .asciz "C.SDSP offset=32"
str_sdsp_off64:  .asciz "C.SDSP offset=64"
str_sdsp_off128: .asciz "C.SDSP offset=128"
str_sdsp_off256: .asciz "C.SDSP offset=256 (max single bit)"
str_sdsp_off504: .asciz "C.SDSP offset=504 (max, all bits)"
str_sdsp_off168: .asciz "C.SDSP offset=168 (alt pattern 010101)"
str_sdsp_off336: .asciz "C.SDSP offset=336 (alt pattern 101010)"
str_sdsp_val_zero:    .asciz "C.SDSP value=0x0000000000000000"
str_sdsp_val_allones: .asciz "C.SDSP value=0xffffffffffffffff"
str_sdsp_val_maxpos:  .asciz "C.SDSP value=0x7fffffffffffffff"
str_sdsp_val_minneg:  .asciz "C.SDSP value=0x8000000000000000"
str_sdsp_val_alt1:    .asciz "C.SDSP value=0xaaaaaaaaaaaaaaaa"
str_sdsp_val_alt0:    .asciz "C.SDSP value=0x5555555555555555"
str_sdsp_val_walking: .asciz "C.SDSP value=0x0123456789abcdef"
str_sdsp_val_one:     .asciz "C.SDSP value=0x0000000000000001"
str_sdsp_sp_preserved: .asciz "C.SDSP sp unmodified"

str_mv_rd_ra:  .asciz "C.MV rd=ra(x1)"
str_mv_rd_t0:  .asciz "C.MV rd=t0(x5)"
str_mv_rd_s0:  .asciz "C.MV rd=s0(x8)"
str_mv_rd_a0:  .asciz "C.MV rd=a0(x10)"
str_mv_rd_a4:  .asciz "C.MV rd=a4(x14)"
str_mv_rd_s2:  .asciz "C.MV rd=s2(x18)"
str_mv_rd_s6:  .asciz "C.MV rd=s6(x22)"
str_mv_rd_s10: .asciz "C.MV rd=s10(x26)"
str_mv_rd_t6:  .asciz "C.MV rd=t6(x31)"
str_mv_rs2_ra:  .asciz "C.MV rs2=ra(x1)"
str_mv_rs2_t0:  .asciz "C.MV rs2=t0(x5)"
str_mv_rs2_s0:  .asciz "C.MV rs2=s0(x8)"
str_mv_rs2_a0:  .asciz "C.MV rs2=a0(x10)"
str_mv_rs2_a4:  .asciz "C.MV rs2=a4(x14)"
str_mv_rs2_s2:  .asciz "C.MV rs2=s2(x18)"
str_mv_rs2_s6:  .asciz "C.MV rs2=s6(x22)"
str_mv_rs2_s10: .asciz "C.MV rs2=s10(x26)"
str_mv_rs2_t6:  .asciz "C.MV rs2=t6(x31)"
str_mv_alias_s0: .asciz "C.MV rd==rs2==s0(x8) alias (identity)"
str_mv_alias_a4: .asciz "C.MV rd==rs2==a4(x14) alias (identity)"
    .if XLEN == 64
str_mv_val_zero:    .asciz "C.MV value=0x0000000000000000"
    .else
str_mv_val_zero:    .asciz "C.MV value=0x00000000"
    .endif
    .if XLEN == 64
str_mv_val_allones: .asciz "C.MV value=0xffffffffffffffff"
    .else
str_mv_val_allones: .asciz "C.MV value=0xffffffff"
    .endif
    .if XLEN == 64
str_mv_val_signbit: .asciz "C.MV value=0x8000000000000000"
    .else
str_mv_val_signbit: .asciz "C.MV value=0x80000000"
    .endif
    .if XLEN == 64
str_mv_val_walking:  .asciz "C.MV value=0x123456789abcdef0"
    .else
str_mv_val_walking:  .asciz "C.MV value=0x9abcdef0"
    .endif
    .if XLEN == 64
str_mv_val_one:      .asciz "C.MV value=0x0000000000000001"
    .else
str_mv_val_one:      .asciz "C.MV value=0x00000001"
    .endif
str_mv_rs2_preserved: .asciz "C.MV rs2 unmodified"

str_add_rd_ra:  .asciz "C.ADD rd=ra(x1)"
str_add_rd_t0:  .asciz "C.ADD rd=t0(x5)"
str_add_rd_s0:  .asciz "C.ADD rd=s0(x8)"
str_add_rd_a0:  .asciz "C.ADD rd=a0(x10)"
str_add_rd_a4:  .asciz "C.ADD rd=a4(x14)"
str_add_rd_s2:  .asciz "C.ADD rd=s2(x18)"
str_add_rd_s6:  .asciz "C.ADD rd=s6(x22)"
str_add_rd_s10: .asciz "C.ADD rd=s10(x26)"
str_add_rd_t6:  .asciz "C.ADD rd=t6(x31)"
str_add_rs2_ra:  .asciz "C.ADD rs2=ra(x1)"
str_add_rs2_t0:  .asciz "C.ADD rs2=t0(x5)"
str_add_rs2_s0:  .asciz "C.ADD rs2=s0(x8)"
str_add_rs2_a0:  .asciz "C.ADD rs2=a0(x10)"
str_add_rs2_a4:  .asciz "C.ADD rs2=a4(x14)"
str_add_rs2_s2:  .asciz "C.ADD rs2=s2(x18)"
str_add_rs2_s6:  .asciz "C.ADD rs2=s6(x22)"
str_add_rs2_s10: .asciz "C.ADD rs2=s10(x26)"
str_add_rs2_t6:  .asciz "C.ADD rs2=t6(x31)"
str_add_alias_s0: .asciz "C.ADD rd==rs2==s0(x8) alias (double)"
str_add_alias_a4: .asciz "C.ADD rd==rs2==a4(x14) alias (double, overflows)"
    .if XLEN == 64
str_add_val_wrap:          .asciz "C.ADD 64-bit 0xfff...f + 1 wraps to 0"
    .else
str_add_val_wrap:          .asciz "C.ADD 32-bit 0xfff...f + 1 wraps to 0"
    .endif
    .if XLEN == 64
str_add_val_maxpos:        .asciz "C.ADD INT64_MAX + 1 wraps to INT64_MIN"
    .else
str_add_val_maxpos:        .asciz "C.ADD INT32_MAX + 1 wraps to INT32_MIN"
    .endif
str_add_val_walking:       .asciz "C.ADD two walking patterns"
str_add_val_complementary: .asciz "C.ADD 0xaaaa... + 0x5555... = allones"
str_add_rs2_preserved: .asciz "C.ADD rs2 unmodified"

str_jr_reg_ra:  .asciz "C.JR rs1=ra(x1)"
str_jr_reg_t0:  .asciz "C.JR rs1=t0(x5)"
str_jr_reg_s0:  .asciz "C.JR rs1=s0(x8)"
str_jr_reg_a0:  .asciz "C.JR rs1=a0(x10)"
str_jr_reg_a4:  .asciz "C.JR rs1=a4(x14)"
str_jr_reg_s2:  .asciz "C.JR rs1=s2(x18)"
str_jr_reg_s6:  .asciz "C.JR rs1=s6(x22)"
str_jr_reg_s10: .asciz "C.JR rs1=s10(x26)"
str_jr_reg_t6:  .asciz "C.JR rs1=t6(x31)"
str_jr_rs1_preserved: .asciz "C.JR rs1 unmodified (pure read)"
str_jr_no_link:        .asciz "C.JR does not link ra (unlike C.JALR)"
str_jalr_landed_ra:  .asciz "C.JALR rs1=ra(x1) landed (rd==rs1 alias)"
str_jalr_landed_t0:  .asciz "C.JALR rs1=t0(x5) landed"
str_jalr_landed_s0:  .asciz "C.JALR rs1=s0(x8) landed"
str_jalr_landed_a0:  .asciz "C.JALR rs1=a0(x10) landed"
str_jalr_landed_a4:  .asciz "C.JALR rs1=a4(x14) landed"
str_jalr_landed_s2:  .asciz "C.JALR rs1=s2(x18) landed"
str_jalr_landed_s6:  .asciz "C.JALR rs1=s6(x22) landed"
str_jalr_landed_s10: .asciz "C.JALR rs1=s10(x26) landed"
str_jalr_landed_t6:  .asciz "C.JALR rs1=t6(x31) landed"
str_jalr_link_ra:  .asciz "C.JALR rs1=ra(x1) link value correct (rd==rs1 alias)"
str_jalr_link_t0:  .asciz "C.JALR rs1=t0(x5) link value correct"
str_jalr_link_s0:  .asciz "C.JALR rs1=s0(x8) link value correct"
str_jalr_link_a0:  .asciz "C.JALR rs1=a0(x10) link value correct"
str_jalr_link_a4:  .asciz "C.JALR rs1=a4(x14) link value correct"
str_jalr_link_s2:  .asciz "C.JALR rs1=s2(x18) link value correct"
str_jalr_link_s6:  .asciz "C.JALR rs1=s6(x22) link value correct"
str_jalr_link_s10: .asciz "C.JALR rs1=s10(x26) link value correct"
str_jalr_link_t6:  .asciz "C.JALR rs1=t6(x31) link value correct"
str_jalr_rs1_preserved: .asciz "C.JALR rs1 unmodified when rs1 != rd"
str_ebreak_caught:  .asciz "C.EBREAK trap caught, execution resumed"
str_ebreak_mcause:  .asciz "C.EBREAK mcause == 3 (breakpoint)"
str_ebreak_mepc:    .asciz "C.EBREAK mepc lands exactly on the instruction"
str_ebreak_regs_s0: .asciz "C.EBREAK s0 survives the trap round-trip"
str_ebreak_regs_s1: .asciz "C.EBREAK s1 survives the trap round-trip"
str_ebreak_regs_s3: .asciz "C.EBREAK s3 survives the trap round-trip"
str_ebreak_resume_count: .asciz "C.EBREAK x3 in a row, each resumes exactly once"
str_ebreak_hit_delta:    .asciz "C.EBREAK trap handler hit exactly 3 times"

/* Buffers for the bit-independence SP-relative loads/stores (offsets
 * 0-504, plus the access width). */
    .section .rodata
    .balign 8
bx_q2_ld:
    BX_PATTERN 520
    .section .bss
    .balign 8
bx_q2_st:
    .space  520
