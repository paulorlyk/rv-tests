/* =====================================================================
 * i/op_imm32.S  --  RV64I base-ISA OP-IMM-32 (I-type, word-width)
 *                       ALU instructions: ADDIW, SLLIW, SRLIW, SRAIW
 *
 * Part of the RV64I base-ISA suite; see i/tests.S for how this
 * plugs into the rest (main_tests.S -> i/tests.S -> here), and
 * common.S for the boot/UART/reporting harness everything sits on
 * ("check", "uart_puts" are used from there; nothing else).
 *
 * RV64-only: OP-IMM-32 doesn't exist on RV32 (its opcode is reserved
 * there), so on the RV32 image tests_i_op_imm32 is an empty stub
 * and everything else in this file is assembled out.
 *
 * The word-width twins of i/op_imm.S. The defining rule for all
 * four: the operation is done on the low 32 bits of rs1 only, and the
 * 32-bit result is *sign-extended* from bit 31 into bits 63:32. So the
 * coverage concentrates on the places where that differs from the
 * 64-bit instruction, each chosen so the non-W twin would give a
 * different answer:
 *
 *   - rs1[63:32] is ignored: sources carry garbage in the upper word
 *     (with and without bit 63 set), and the result must not depend on
 *     it.
 *   - The result is sign-extended from bit 31, not 63, and not
 *     zero-extended: a carry, a left shift or a 0-shamt that leaves bit
 *     31 set must give 0xffffffff_xxxxxxxx, one that leaves it clear
 *     must give 0x00000000_xxxxxxxx, whatever the input's upper word.
 *     ADDIW rd, rs1, 0 is the SEXT.W idiom and gets tested as such.
 *   - ADDIW: 32-bit wrap (0x7fffffff + 1 = INT32_MIN, sign-extended;
 *     0xffffffff + 1 = 0, no carry into bit 32). The 12-bit immediate
 *     is sign-extended exactly as for ADDI (+2047, -2048, -1, 0).
 *   - SLLIW/SRLIW/SRAIW: the shamt is the 5-bit imm[4:0]; imm[5] set is
 *     a reserved encoding for the W shifts (the assembler rejects
 *     shamt >= 32), so there's no shamt-32 case. Every shamt bit is
 *     walked (1, 2, 4, 8, 16) plus 0 and 31. SLLIW drops bits shifted
 *     past bit 31 instead of moving them into bit 32. SRLIW zero-fills
 *     from bit 31 downward (not from 63), and SRAIW fills with bit 31
 *     -- not bit 63 -- which is checked with inputs where the two
 *     differ in both directions. The same inputs go through SRLIW and
 *     SRAIW, so a misdecoded imm[10] shows up as a mismatch.
 *   - rd/rs1 (plus rd==rs1, rd=x0 and rs1=x0) are swept through ADDIW.
 *     OP-IMM-32 is its own major opcode, so its register decode gets
 *     its own sweep rather than borrowing OP-IMM's.
 *
 * .option norvc is load-bearing: ADDIW has a compressed form (c.addiw,
 * also what "sext.w" becomes for rd==rs1 in x1-x31) that the
 * assembler would otherwise substitute.
 *
 * Bit independence across fields (bitx_i_op_imm32, at the end): every
 * bit pair among rd, rs1 and the immediate -- C(22,2) = 231 cases for
 * ADDIW and C(15,2) = 105 each for SLLIW/SRLIW/SRAIW (5-bit shamt).
 * The expected values are assemble-time constants computed from the
 * pool value (the OP-32 register-register twins ADDW/SLLW/... aren't
 * covered by this suite, so they aren't a trustworthy reference). See
 * bitx.inc.
 * ===================================================================== */

    .include "xlen.inc"
    .include "harness.inc"

    .option norvc            /* mandatory, not stylistic: see above
                               * (ADDIW -> c.addiw) */

    .include "bitx.inc"

    .global tests_i_op_imm32

    .section .text

    .if XLEN == 64

/* Pool values for the bit-independence cases. Both keep bit 63 clear so
 * the assemble-time arithmetic below never sees a negative operand
 * (right shifts of a positive value are the same logical or
 * arithmetic).
 *   ADDIW: low word 0x7ffffa5c sits just under INT32_MAX, so some
 *     immediates carry into bit 31 (the result sign-extends to
 *     negative) and others don't; the upper word is garbage.
 *   Shifts: low word 0xc3a5695a has bit 31 set (SRAIW fills with ones,
 *     SRLIW with zeroes) while bit 63 is clear, so a SRAIW that takes
 *     its fill from bit 63 fails. */
    .equ BXW_VA_ADD, 0x123456787ffffa5c
    .equ BXW_VA_SH,  0x0123456fc3a5695a

/* BXW_LDSX reg, r -- reg = r's low 32 bits, sign-extended from bit 31,
 * as an assemble-time constant. */
.macro BXW_LDSX reg, r
    BX_LDC  \reg, ((((\r)) & 0xffffffff) - ((((\r)) & 0x80000000) << 1))
.endm

/* BX_C_OPIW insn, nm, op, va, rd, rs1, v -- one bit-independence case
 * (bitx.inc). op selects the reference computation: 0 = ADDIW (v is the
 * raw 12-bit immediate field, sign-extended here), 1 = SLLIW, 2 =
 * SRLIW, 3 = SRAIW (v is the 5-bit shamt). va is the value BX_POOL was
 * given; the expected value is computed from it at assemble time, so no
 * encoding carrying the bits under test feeds the reference. rd is
 * pre-loaded with a sentinel; if rd == rs1 the operand load wins. */
.macro BX_C_OPIW insn, nm, op, va, rd, rs1, v
    BX_ENTER
    .if \op == 0
    BXW_LDSX t5, ((\va) + ((\v) - (((\v) & 0x800) << 1)))
    .elseif \op == 1
    BXW_LDSX t5, (((\va) & 0xffffffff) << (\v))
    .elseif \op == 2
    BXW_LDSX t5, (((\va) & 0xffffffff) >> (\v))
    .else
    BXW_LDSX t5, ((((\va) & 0xffffffff) >> (\v)) | ((((\va) >> 31) & 1) * (0xffffffff << (32 - (\v)))))
    .endif
    BX_PV   x\rd, 2
    BX_PV   x\rs1, 0
    .if \op == 0
    \insn   x\rd, x\rs1, ((\v) - (((\v) & 0x800) << 1))
    mv      t6, x\rd
    BX_REPORT "\nm bitx rd=x\rd rs1=x\rs1 imm=\v"
    .else
    \insn   x\rd, x\rs1, (\v)
    mv      t6, x\rd
    BX_REPORT "\nm bitx rd=x\rd rs1=x\rs1 shamt=\v"
    .endif
.endm

/* =======================================================================
 *  Shared macros
 * ======================================================================= */

/* T_OPIW_RD/RS1 insn, reg, v1, imm, expect, name -- sweep one register
 * field at a time (through ADDIW), the other fixed at a register
 * outside the swept list (rs1=t3 resp. rd=t2). reg may be a0/a1/a2 --
 * result captured to t2 before those are reused. */
.macro T_OPIW_RD insn, rdreg, v1, imm, expect, name
    TEST_BEGIN \name
    LIX     t3, \v1
    \insn   \rdreg, t3, \imm
    mv      t2, \rdreg
    la      a0, \name
    LIX     a1, \expect
    mv      a2, t2
    call    check
.endm

.macro T_OPIW_RS1 insn, rs1reg, v1, imm, expect, name
    TEST_BEGIN \name
    LIX     \rs1reg, \v1
    \insn   t2, \rs1reg, \imm
    la      a0, \name
    LIX     a1, \expect
    mv      a2, t2
    call    check
.endm

/* T_OPIW_VAL insn, v1, imm, expect, name -- fixed rd=t2/rs1=t3, sweep
 * the source value and immediate. */
.macro T_OPIW_VAL insn, v1, imm, expect, name
    TEST_BEGIN \name
    LIX     t3, \v1
    \insn   t2, t3, \imm
    la      a0, \name
    LIX     a1, \expect
    mv      a2, t2
    call    check
.endm

/* T_OPIW_PRESERVED insn, imm, name -- the instruction must not write
 * back to its source register (all 64 bits of it). */
.macro T_OPIW_PRESERVED insn, imm, name
    TEST_BEGIN \name
    LIX     t3, 0x123456789abcdef0
    mv      t5, t3
    \insn   t2, t3, \imm
    la      a0, \name
    mv      a1, t5
    mv      a2, t3
    call    check
.endm

tests_i_op_imm32:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    /* ===== register sweep (through ADDIW). Upper garbage in the
     * source and a result with bit 31 clear, so a sweep register that
     * skips the W semantics also fails. ===== */
    T_OPIW_RD addiw, ra,  0xdead000000000064, 23, 123, str_opiw_rd_ra
    T_OPIW_RD addiw, t0,  0xdead000000000064, 23, 123, str_opiw_rd_t0
    T_OPIW_RD addiw, s0,  0xdead000000000064, 23, 123, str_opiw_rd_s0
    T_OPIW_RD addiw, a0,  0xdead000000000064, 23, 123, str_opiw_rd_a0
    T_OPIW_RD addiw, s10, 0xdead000000000064, 23, 123, str_opiw_rd_s10
    T_OPIW_RD addiw, t6,  0xdead000000000064, 23, 123, str_opiw_rd_t6

    T_OPIW_RS1 addiw, ra,  0xdead000000000064, 23, 123, str_opiw_rs1_ra
    T_OPIW_RS1 addiw, t0,  0xdead000000000064, 23, 123, str_opiw_rs1_t0
    T_OPIW_RS1 addiw, s0,  0xdead000000000064, 23, 123, str_opiw_rs1_s0
    T_OPIW_RS1 addiw, a0,  0xdead000000000064, 23, 123, str_opiw_rs1_a0
    T_OPIW_RS1 addiw, s10, 0xdead000000000064, 23, 123, str_opiw_rs1_s10
    T_OPIW_RS1 addiw, t6,  0xdead000000000064, 23, 123, str_opiw_rs1_t6

    /* rs1=x0: both signs of imm */
    TEST_BEGIN str_opiw_rs1_x0_neg
    addiw   t2, x0, -2048
    la      a0, str_opiw_rs1_x0_neg
    LIX     a1, 0xfffffffffffff800
    mv      a2, t2
    call    check
    TEST_BEGIN str_opiw_rs1_x0_pos
    addiw   t2, x0, 2047
    la      a0, str_opiw_rs1_x0_pos
    LIX     a1, 0x00000000000007ff
    mv      a2, t2
    call    check

    /* rd=x0: must not fault, result discarded */
    TEST_BEGIN str_opiw_rd_x0
    LIX     t3, 100
    addiw   x0, t3, 23
    la      a0, str_opiw_rd_x0
    LIX     a1, 0
    mv      a2, x0
    call    check

    TEST_BEGIN str_opiw_alias_rd_rs1
    /* ===== aliasing (through ADDIW): rd==rs1, across the 32-bit
     * overflow so the sign extension is visible too ===== */
    LIX     t1, 0x000000007fffffff
    addiw   t1, t1, 1
    la      a0, str_opiw_alias_rd_rs1
    LIX     a1, 0xffffffff80000000
    mv      a2, t1
    call    check

    /* ===== ADDIW: sign-extended 12-bit immediate, 32-bit add,
     *     result sign-extended from bit 31 ===== */
    T_OPIW_VAL addiw, 0, 2047,  0x00000000000007ff, str_addiw_imm_max
    T_OPIW_VAL addiw, 0, -2048, 0xfffffffffffff800, str_addiw_imm_min
    T_OPIW_VAL addiw, 0, -1,    0xffffffffffffffff, str_addiw_imm_m1
    T_OPIW_VAL addiw, 5, -10,   0xfffffffffffffffb, str_addiw_neg_result
    T_OPIW_VAL addiw, 1000, -1000, 0x0000000000000000, str_addiw_cancel
    /* SEXT.W idiom: imm=0 */
    T_OPIW_VAL addiw, 0x1234567887654321, 0, 0xffffffff87654321, str_addiw_sextw_neg
    T_OPIW_VAL addiw, 0xfedcba9812345678, 0, 0x0000000012345678, str_addiw_sextw_pos
    T_OPIW_VAL addiw, 0x00000000ffffffff, 0, 0xffffffffffffffff, str_addiw_sextw_allones
    /* 32-bit wrap, and no carry/borrow across bit 32 */
    T_OPIW_VAL addiw, 0x000000007fffffff, 1,  0xffffffff80000000, str_addiw_int32_max_plus1
    T_OPIW_VAL addiw, 0xffffffff80000000, -1, 0x000000007fffffff, str_addiw_int32_min_minus1
    T_OPIW_VAL addiw, 0x00000000ffffffff, 1,  0x0000000000000000, str_addiw_no_carry_32
    T_OPIW_VAL addiw, 0x0000000100000000, -1, 0xffffffffffffffff, str_addiw_no_borrow_32
    /* upper word ignored */
    T_OPIW_VAL addiw, 0xdeadbeef00000005, 3, 0x0000000000000008, str_addiw_upper_ignored
    T_OPIW_VAL addiw, 0x0123456789abcdef, 0x555,  0xffffffff89abd344, str_addiw_pattern_pos
    T_OPIW_VAL addiw, 0x0123456789abcdef, -0x556, 0xffffffff89abc899, str_addiw_pattern_neg
    T_OPIW_PRESERVED addiw, 23, str_addiw_rs1_preserved

    /* ===== SLLIW: every shamt bit individually, plus 0 and 31 ===== */
    T_OPIW_VAL slliw, 0x0000000000000001, 0,  0x0000000000000001, str_slliw_sh0
    T_OPIW_VAL slliw, 0x0000000000000001, 1,  0x0000000000000002, str_slliw_sh1
    T_OPIW_VAL slliw, 0x0000000000000001, 2,  0x0000000000000004, str_slliw_sh2
    T_OPIW_VAL slliw, 0x0000000000000001, 4,  0x0000000000000010, str_slliw_sh4
    T_OPIW_VAL slliw, 0x0000000000000001, 8,  0x0000000000000100, str_slliw_sh8
    T_OPIW_VAL slliw, 0x0000000000000001, 16, 0x0000000000010000, str_slliw_sh16
    T_OPIW_VAL slliw, 0x0000000000000001, 31, 0xffffffff80000000, str_slliw_sh31
    T_OPIW_VAL slliw, 0x0000000040000000, 1,  0xffffffff80000000, str_slliw_into_bit31
    T_OPIW_VAL slliw, 0x0000000080000001, 1,  0x0000000000000002, str_slliw_drops_bit31
    T_OPIW_VAL slliw, 0x00000000ffffffff, 1,  0xfffffffffffffffe, str_slliw_no_carry_32
    T_OPIW_VAL slliw, 0xffffffffffffffff, 16, 0xffffffffffff0000, str_slliw_allones_sh16
    T_OPIW_VAL slliw, 0xdeadbeef00000001, 4,  0x0000000000000010, str_slliw_upper_ignored
    T_OPIW_VAL slliw, 0xdeadbeef12345678, 0,  0x0000000012345678, str_slliw_sh0_upper_cleared
    T_OPIW_PRESERVED slliw, 4, str_slliw_rs1_preserved

    /* ===== SRLIW / SRAIW: same inputs through both. Source bit 31 set,
     *     bit 63 clear: the fill must come from bit 31. ===== */
    T_OPIW_VAL srliw, 0x0000000080000000, 0,  0xffffffff80000000, str_srliw_sh0
    T_OPIW_VAL sraiw, 0x0000000080000000, 0,  0xffffffff80000000, str_sraiw_sh0
    T_OPIW_VAL srliw, 0x0000000080000000, 1,  0x0000000040000000, str_srliw_sh1
    T_OPIW_VAL sraiw, 0x0000000080000000, 1,  0xffffffffc0000000, str_sraiw_sh1
    T_OPIW_VAL srliw, 0x0000000080000000, 2,  0x0000000020000000, str_srliw_sh2
    T_OPIW_VAL sraiw, 0x0000000080000000, 2,  0xffffffffe0000000, str_sraiw_sh2
    T_OPIW_VAL srliw, 0x0000000080000000, 4,  0x0000000008000000, str_srliw_sh4
    T_OPIW_VAL sraiw, 0x0000000080000000, 4,  0xfffffffff8000000, str_sraiw_sh4
    T_OPIW_VAL srliw, 0x0000000080000000, 8,  0x0000000000800000, str_srliw_sh8
    T_OPIW_VAL sraiw, 0x0000000080000000, 8,  0xffffffffff800000, str_sraiw_sh8
    T_OPIW_VAL srliw, 0x0000000080000000, 16, 0x0000000000008000, str_srliw_sh16
    T_OPIW_VAL sraiw, 0x0000000080000000, 16, 0xffffffffffff8000, str_sraiw_sh16
    T_OPIW_VAL srliw, 0x0000000080000000, 31, 0x0000000000000001, str_srliw_sh31
    T_OPIW_VAL sraiw, 0x0000000080000000, 31, 0xffffffffffffffff, str_sraiw_sh31
    /* bit 63 set, bit 31 clear: the fill must still come from bit 31 */
    T_OPIW_VAL srliw, 0xffffffff7fffffff, 4,  0x0000000007ffffff, str_srliw_bit63_ignored
    T_OPIW_VAL sraiw, 0xffffffff7fffffff, 4,  0x0000000007ffffff, str_sraiw_bit63_ignored
    /* only the upper word set: nothing may shift down out of it */
    T_OPIW_VAL srliw, 0xffffffff00000000, 1,  0x0000000000000000, str_srliw_upper_not_shifted_in
    T_OPIW_VAL sraiw, 0xffffffff00000000, 1,  0x0000000000000000, str_sraiw_upper_not_shifted_in
    T_OPIW_VAL srliw, 0x0000000040000000, 2,  0x0000000010000000, str_srliw_positive
    T_OPIW_VAL sraiw, 0x0000000040000000, 2,  0x0000000010000000, str_sraiw_positive_no_signext
    T_OPIW_VAL srliw, 0xfffffffffffffffd, 1,  0x000000007ffffffe, str_srliw_m3
    T_OPIW_VAL sraiw, 0xfffffffffffffffd, 1,  0xfffffffffffffffe, str_sraiw_rounds_toward_neg_inf
    T_OPIW_PRESERVED srliw, 4, str_srliw_rs1_preserved
    T_OPIW_PRESERVED sraiw, 4, str_sraiw_rs1_preserved

    jal     ra, bitx_i_op_imm32

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

bitx_i_op_imm32:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    /* 12-bit immediate: C(22,2) = 231 pairs */
    BX_POOL BXW_VA_ADD, 0
    BX_E_RRI5 BX_C_OPIW, "addiw, ADDIW, 0, BXW_VA_ADD", 7, 28, "0x1,0x2,0x4,0x8,0x10,0x20,0x40,0x80,0x100,0x200,0x400,0x800", 0
    /* 5-bit shamt: C(15,2) = 105 pairs each */
    BX_POOL BXW_VA_SH, 0
    BX_E_RRI5 BX_C_OPIW, "slliw, SLLIW, 1, BXW_VA_SH", 7, 28, "0x1,0x2,0x4,0x8,0x10", 0
    BX_E_RRI5 BX_C_OPIW, "srliw, SRLIW, 2, BXW_VA_SH", 7, 28, "0x1,0x2,0x4,0x8,0x10", 0
    BX_E_RRI5 BX_C_OPIW, "sraiw, SRAIW, 3, BXW_VA_SH", 7, 28, "0x1,0x2,0x4,0x8,0x10", 0

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

    .else   /* XLEN == 32: OP-IMM-32 doesn't exist */

tests_i_op_imm32:
    ret

    .endif

    .if XLEN == 64
    .section .rodata
str_opiw_rd_ra:  .asciz "OP-IMM-32 rd=ra(x1) (via ADDIW)"
str_opiw_rd_t0:  .asciz "OP-IMM-32 rd=t0(x5) (via ADDIW)"
str_opiw_rd_s0:  .asciz "OP-IMM-32 rd=s0(x8) (via ADDIW)"
str_opiw_rd_a0:  .asciz "OP-IMM-32 rd=a0(x10) (via ADDIW)"
str_opiw_rd_s10: .asciz "OP-IMM-32 rd=s10(x26) (via ADDIW)"
str_opiw_rd_t6:  .asciz "OP-IMM-32 rd=t6(x31) (via ADDIW)"
str_opiw_rs1_ra:  .asciz "OP-IMM-32 rs1=ra(x1) (via ADDIW)"
str_opiw_rs1_t0:  .asciz "OP-IMM-32 rs1=t0(x5) (via ADDIW)"
str_opiw_rs1_s0:  .asciz "OP-IMM-32 rs1=s0(x8) (via ADDIW)"
str_opiw_rs1_a0:  .asciz "OP-IMM-32 rs1=a0(x10) (via ADDIW)"
str_opiw_rs1_s10: .asciz "OP-IMM-32 rs1=s10(x26) (via ADDIW)"
str_opiw_rs1_t6:  .asciz "OP-IMM-32 rs1=t6(x31) (via ADDIW)"
str_opiw_rs1_x0_neg: .asciz "OP-IMM-32 rs1=x0, imm=-2048 (via ADDIW)"
str_opiw_rs1_x0_pos: .asciz "OP-IMM-32 rs1=x0, imm=+2047 (via ADDIW)"
str_opiw_rd_x0:      .asciz "OP-IMM-32 rd=x0 discards result (via ADDIW)"
str_opiw_alias_rd_rs1: .asciz "OP-IMM-32 rd==rs1 (via ADDIW)"

str_addiw_imm_max:     .asciz "ADDIW imm=+2047 (max)"
str_addiw_imm_min:     .asciz "ADDIW imm=-2048 (min, sign-extended)"
str_addiw_imm_m1:      .asciz "ADDIW imm=-1 (sign-extended to all ones)"
str_addiw_neg_result:  .asciz "ADDIW 5 + -10 = -5 (sign-extended)"
str_addiw_cancel:      .asciz "ADDIW 1000 + -1000 = 0"
str_addiw_sextw_neg:   .asciz "ADDIW imm=0 (SEXT.W) bit 31 set -> upper word all ones"
str_addiw_sextw_pos:   .asciz "ADDIW imm=0 (SEXT.W) bit 31 clear -> upper word cleared"
str_addiw_sextw_allones: .asciz "ADDIW imm=0 (SEXT.W) 0xffffffff -> -1"
str_addiw_int32_max_plus1:  .asciz "ADDIW INT32_MAX + 1 wraps to INT32_MIN, sign-extended"
str_addiw_int32_min_minus1: .asciz "ADDIW INT32_MIN + -1 wraps to INT32_MAX"
str_addiw_no_carry_32:      .asciz "ADDIW 0xffffffff + 1 = 0 (no carry into bit 32)"
str_addiw_no_borrow_32:     .asciz "ADDIW 2^32 + -1 = -1 (upper word ignored)"
str_addiw_upper_ignored:    .asciz "ADDIW ignores rs1[63:32]"
str_addiw_pattern_pos:      .asciz "ADDIW pattern + 0x555"
str_addiw_pattern_neg:      .asciz "ADDIW pattern + -0x556"
str_addiw_rs1_preserved:    .asciz "ADDIW rs1 unmodified"

str_slliw_sh0:  .asciz "SLLIW shamt=0"
str_slliw_sh1:  .asciz "SLLIW shamt=1 (shamt bit 0)"
str_slliw_sh2:  .asciz "SLLIW shamt=2 (shamt bit 1)"
str_slliw_sh4:  .asciz "SLLIW shamt=4 (shamt bit 2)"
str_slliw_sh8:  .asciz "SLLIW shamt=8 (shamt bit 3)"
str_slliw_sh16: .asciz "SLLIW shamt=16 (shamt bit 4)"
str_slliw_sh31: .asciz "SLLIW shamt=31 (max, result sign-extended)"
str_slliw_into_bit31:   .asciz "SLLIW shifting into bit 31 sign-extends"
str_slliw_drops_bit31:  .asciz "SLLIW bit 31 shifted out, not into bit 32"
str_slliw_no_carry_32:  .asciz "SLLIW 0xffffffff<<1 = -2 (not 0x1fffffffe)"
str_slliw_allones_sh16: .asciz "SLLIW all-ones by 16"
str_slliw_upper_ignored:     .asciz "SLLIW ignores rs1[63:32]"
str_slliw_sh0_upper_cleared: .asciz "SLLIW shamt=0 still replaces the upper word"
str_slliw_rs1_preserved: .asciz "SLLIW rs1 unmodified"

str_srliw_sh0:  .asciz "SRLIW shamt=0 (result sign-extended)"
str_sraiw_sh0:  .asciz "SRAIW shamt=0 (result sign-extended)"
str_srliw_sh1:  .asciz "SRLIW shamt=1 (zero-fill from bit 31)"
str_sraiw_sh1:  .asciz "SRAIW shamt=1 (fill from bit 31) DIVERGES from SRLIW"
str_srliw_sh2:  .asciz "SRLIW shamt=2"
str_sraiw_sh2:  .asciz "SRAIW shamt=2"
str_srliw_sh4:  .asciz "SRLIW shamt=4"
str_sraiw_sh4:  .asciz "SRAIW shamt=4"
str_srliw_sh8:  .asciz "SRLIW shamt=8"
str_sraiw_sh8:  .asciz "SRAIW shamt=8"
str_srliw_sh16: .asciz "SRLIW shamt=16"
str_sraiw_sh16: .asciz "SRAIW shamt=16"
str_srliw_sh31: .asciz "SRLIW shamt=31 (max)"
str_sraiw_sh31: .asciz "SRAIW shamt=31 (max, all sign-fill)"
str_srliw_bit63_ignored: .asciz "SRLIW bit 63 set, bit 31 clear: positive result"
str_sraiw_bit63_ignored: .asciz "SRAIW fills from bit 31, not bit 63"
str_srliw_upper_not_shifted_in: .asciz "SRLIW rs1[63:32] not shifted into the result"
str_sraiw_upper_not_shifted_in: .asciz "SRAIW rs1[63:32] not shifted into the result"
str_srliw_positive:             .asciz "SRLIW positive input"
str_sraiw_positive_no_signext:  .asciz "SRAIW positive input needs no sign-extension"
str_srliw_m3:                   .asciz "SRLIW -3>>1 = 0x7ffffffe (zero-fill at bit 31)"
str_sraiw_rounds_toward_neg_inf: .asciz "SRAIW -3>>1 = -2 (rounds toward -inf)"
str_srliw_rs1_preserved: .asciz "SRLIW rs1 unmodified"
str_sraiw_rs1_preserved: .asciz "SRAIW rs1 unmodified"
    .endif
