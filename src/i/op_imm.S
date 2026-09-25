/* =====================================================================
 * i/op_imm.S  --  RV64I base-ISA OP-IMM (I-type) ALU instructions:
 *                     ADDI, SLTI, SLTIU, XORI, ORI, ANDI,
 *                     SLLI, SRLI, SRAI
 *
 * Part of the RV64I base-ISA suite; see i/tests.S for how this
 * plugs into the rest (main_tests.S -> i/tests.S -> here), and
 * common.S for the boot/UART/reporting harness everything sits on
 * ("check", "uart_puts" are used from there; nothing else).
 *
 * The immediate-operand twins of i/op_alu.S, and organised the same
 * way: rd/rs1 carry identical decode risk for all nine, so the
 * register fields (and rd==rs1 aliasing) are swept *once*, through
 * ADDI. The per-instruction depth goes into the operation and, above
 * all, into the immediate, which is where OP-IMM differs from OP:
 *
 *   - The 12-bit immediate is sign-extended to 64 bits *before* the
 *     operation, for every one of ADDI/SLTI/SLTIU/XORI/ORI/ANDI --
 *     including the logical ops and the unsigned compare, where it's
 *     easiest to forget. So XORI rd, rs1, -1 is a full 64-bit NOT,
 *     ANDI with -2048 clears only the low 11 bits, and SLTIU compares
 *     against 0xffff...ffff when imm=-1 (the "rs1 != all-ones" idiom),
 *     while SLTIU rd, rs1, 1 is the SEQZ idiom. Each gets both a
 *     positive (sign bit 11 clear) and a negative (sign bit 11 set)
 *     immediate, so an implementation that zero-extends shows up as a
 *     mismatch in bits 63:12.
 *   - The immediate is a single contiguous field, so -- the same
 *     reasoning as the load/store offsets -- it gets boundary values
 *     (+2047, -2048, 0, -1) and representative in-between ones rather
 *     than an exhaustive per-bit walk.
 *   - SLLI/SRLI/SRAI: on RV64 the shift amount is the 6-bit
 *     imm[5:0], with imm[11:6] acting as funct6 (SRAI differs from
 *     SRLI only in imm[10]). Every shamt bit is walked individually
 *     (1, 2, 4, 8, 16, 32) plus 0 and 63, since unlike OP's register
 *     shifts the amount lives in the instruction encoding itself, and
 *     shamt[5] in particular is RV64-only (it's reserved on RV32). The
 *     same inputs go through SRLI and SRAI, so a mixup of the two
 *     (i.e. a misdecoded imm[10]) is a visible mismatch. Out-of-range
 *     amounts (>= 64) aren't encodable -- the assembler rejects them --
 *     so there's no masking test like SLL's rs2=64.
 *   - SLTI/SLTIU get the same signed/unsigned divergence pairs as
 *     SLT/SLTU in i/op_alu.S.
 *
 * Bit independence across fields (bitx_i_op_imm, at the end): every bit
 * pair among rd, rs1 and the immediate set together, per instruction --
 * C(22,2) = 231 cases each for the six 12-bit-immediate ops and
 * C(16,2) = 120 each for SLLI/SRLI/SRAI (6-bit shamt). Expected values
 * come from the register-register twin (ADDI against ADD, and so on)
 * with the immediate fetched from a constant pool, so the reference
 * never shares the immediate bits under test. See bitx.inc.
 *
 * RV32 image (xlen.inc): the shamt is 5 bits (max 31); the carry/borrow
 * across bit 32 and "sign-extended to 64, not 32" tests are RV64-only.
 * ===================================================================== */

    .include "xlen.inc"
    .include "harness.inc"

    .option norvc            /* mandatory, not stylistic: ADDI, ANDI,
                               * SLLI, SRLI and SRAI all have compressed
                               * forms (c.addi, c.li, c.mv, c.andi,
                               * c.slli, c.srli, c.srai ...) the
                               * assembler would otherwise substitute for
                               * suitable operands, silently testing the
                               * RVC instruction instead of this one. */

    .include "bitx.inc"

    .global tests_i_op_imm

    .section .text

/* BX_C_OPI insn, rinsn, nm, rd, rs1, v -- one bit-independence case for
 * a 12-bit-immediate op (bitx.inc). v is the raw 12-bit field; the
 * instruction gets it sign-extended. The expected value comes from the
 * register-register twin rinsn (ADD for ADDI, ...) in the T_OP_VAL
 * encoding, with the same value fetched from the constant pool, so no
 * encoding carrying these immediate bits feeds the reference. rd is
 * pre-loaded with a sentinel; if rd == rs1 the operand load wins. */
.macro BX_C_OPI insn, rinsn, nm, rd, rs1, v
    BX_ENTER
    BX_PV   t3, 0
    BX_LDC  t4, ((\v) - (((\v) & 0x800) << 1))
    \rinsn  t2, t3, t4
    mv      t5, t2
    BX_PV   x\rd, 2
    BX_PV   x\rs1, 0
    \insn   x\rd, x\rs1, ((\v) - (((\v) & 0x800) << 1))
    mv      t6, x\rd
    BX_REPORT "\nm bitx rd=x\rd rs1=x\rs1 imm=\v"
.endm

/* BX_C_SHI -- the same for SLLI/SRLI/SRAI: v is the unsigned 6-bit
 * shamt, checked against SLL/SRL/SRA by that amount. */
.macro BX_C_SHI insn, rinsn, nm, rd, rs1, v
    BX_ENTER
    BX_PV   t3, 0
    BX_LDC  t4, (\v)
    \rinsn  t2, t3, t4
    mv      t5, t2
    BX_PV   x\rd, 2
    BX_PV   x\rs1, 0
    \insn   x\rd, x\rs1, (\v)
    mv      t6, x\rd
    BX_REPORT "\nm bitx rd=x\rd rs1=x\rs1 shamt=\v"
.endm

/* =======================================================================
 *  Shared macros
 * ======================================================================= */

/* T_OPI_RD/RS1 insn, reg, v1, imm, expect, name -- sweep one register
 * field at a time (through ADDI), the other fixed at a register outside
 * the swept list. reg may be a0/a1/a2 -- result captured to t2 before
 * those are reused. */
.macro T_OPI_RD insn, rdreg, v1, imm, expect, name
    TEST_BEGIN \name
    LIX     t3, \v1
    \insn   \rdreg, t3, \imm
    mv      t2, \rdreg
    la      a0, \name
    LIX     a1, \expect
    mv      a2, t2
    call    check
.endm

.macro T_OPI_RS1 insn, rs1reg, v1, imm, expect, name
    TEST_BEGIN \name
    LIX     \rs1reg, \v1
    \insn   t2, \rs1reg, \imm
    la      a0, \name
    LIX     a1, \expect
    mv      a2, t2
    call    check
.endm

/* T_OPI_VAL insn, v1, imm, expect, name -- fixed rd=t2/rs1=t3, sweep
 * the source value and immediate. */
.macro T_OPI_VAL insn, v1, imm, expect, name
    TEST_BEGIN \name
    LIX     t3, \v1
    \insn   t2, t3, \imm
    la      a0, \name
    LIX     a1, \expect
    mv      a2, t2
    call    check
.endm

/* T_OPI_PRESERVED insn, imm, name -- the instruction must not write
 * back to its source register. */
.macro T_OPI_PRESERVED insn, imm, name
    TEST_BEGIN \name
    LIXT    t3, 0x123456789abcdef0
    mv      t5, t3
    \insn   t2, t3, \imm
    la      a0, \name
    mv      a1, t5
    mv      a2, t3
    call    check
.endm

tests_i_op_imm:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    /* ===== register sweep (through ADDI; identical decode risk for
     * all nine) ===== */
    T_OPI_RD addi, ra,  100, 23, 123, str_opi_rd_ra
    T_OPI_RD addi, t0,  100, 23, 123, str_opi_rd_t0
    T_OPI_RD addi, s0,  100, 23, 123, str_opi_rd_s0
    T_OPI_RD addi, a0,  100, 23, 123, str_opi_rd_a0
    T_OPI_RD addi, s10, 100, 23, 123, str_opi_rd_s10
    T_OPI_RD addi, t6,  100, 23, 123, str_opi_rd_t6

    T_OPI_RS1 addi, ra,  100, 23, 123, str_opi_rs1_ra
    T_OPI_RS1 addi, t0,  100, 23, 123, str_opi_rs1_t0
    T_OPI_RS1 addi, s0,  100, 23, 123, str_opi_rs1_s0
    T_OPI_RS1 addi, a0,  100, 23, 123, str_opi_rs1_a0
    T_OPI_RS1 addi, s10, 100, 23, 123, str_opi_rs1_s10
    T_OPI_RS1 addi, t6,  100, 23, 123, str_opi_rs1_t6

    /* rs1=x0: the "li rd, imm" idiom, both signs of imm */
    TEST_BEGIN str_opi_rs1_x0_neg
    addi    t2, x0, -2048
    la      a0, str_opi_rs1_x0_neg
    LIX     a1, 0xfffffffffffff800
    mv      a2, t2
    call    check
    TEST_BEGIN str_opi_rs1_x0_pos
    addi    t2, x0, 2047
    la      a0, str_opi_rs1_x0_pos
    LIX     a1, 0x00000000000007ff
    mv      a2, t2
    call    check

    /* rd=x0: must not fault, result discarded */
    TEST_BEGIN str_opi_rd_x0
    LIX     t3, 100
    addi    x0, t3, 23
    la      a0, str_opi_rd_x0
    LIX     a1, 0
    mv      a2, x0
    call    check

    /* ===== aliasing (through ADDI): rd==rs1 ===== */
    TEST_BEGIN str_opi_alias_rd_rs1
    LIX     t1, 100
    addi    t1, t1, 23
    la      a0, str_opi_alias_rd_rs1
    LIX     a1, 123
    mv      a2, t1
    call    check

    /* ===== ADDI: sign-extended 12-bit immediate ===== */
    T_OPI_VAL addi, 0, 2047,  0x00000000000007ff, str_addi_imm_max
    T_OPI_VAL addi, 0, -2048, 0xfffffffffffff800, str_addi_imm_min
    T_OPI_VAL addi, 0, -1,    0xffffffffffffffff, str_addi_imm_m1
    .if XLEN == 64
    T_OPI_VAL addi, 0x1234567812345678, 0, 0x1234567812345678, str_addi_imm_0
    T_OPI_VAL addi, 0x0000000100000000, -1, 0x00000000ffffffff, str_addi_borrow_across_32
    T_OPI_VAL addi, 0x00000000ffffffff, 1, 0x0000000100000000, str_addi_carry_across_32
    .else
    T_OPI_VAL addi, 0x12345678, 0, 0x12345678, str_addi_imm_0
    .endif
    T_OPI_VAL addi, 0xffffffffffffffff, 1, 0x0000000000000000, str_addi_wrap
    T_OPI_VAL addi, INTX_MAX, 1, INTX_MIN, str_addi_int64_max_plus1
    T_OPI_VAL addi, INTX_MIN, -1, INTX_MAX, str_addi_int64_min_minus1
    T_OPI_VAL addi, 1000, -1000, 0x0000000000000000, str_addi_cancel
    .if XLEN == 64
    T_OPI_VAL addi, 0x0123456789abcdef, 0x555, 0x0123456789abd344, str_addi_pattern_pos
    T_OPI_VAL addi, 0x0123456789abcdef, -0x556, 0x0123456789abc899, str_addi_pattern_neg
    .else
    T_OPI_VAL addi, 0x89abcdef, 0x555, 0x89abd344, str_addi_pattern_pos
    T_OPI_VAL addi, 0x89abcdef, -0x556, 0x89abc899, str_addi_pattern_neg
    .endif
    T_OPI_PRESERVED addi, 23, str_addi_rs1_preserved

    /* ===== SLTI / SLTIU: signed vs unsigned compare against the
     *     *sign-extended* immediate. Same divergence pairs as SLT/SLTU. ===== */
    T_OPI_VAL slti,  0, 0, 0, str_slti_eq
    T_OPI_VAL sltiu, 0, 0, 0, str_sltiu_eq
    T_OPI_VAL slti,  1, 2, 1, str_slti_1_2
    T_OPI_VAL sltiu, 1, 2, 1, str_sltiu_1_2
    T_OPI_VAL slti,  2, 1, 0, str_slti_2_1
    T_OPI_VAL sltiu, 2, 1, 0, str_sltiu_2_1
    T_OPI_VAL slti,  -1, 1, 1, str_slti_m1_1
    T_OPI_VAL sltiu, -1, 1, 0, str_sltiu_m1_1_diverges
    T_OPI_VAL slti,  1, -1, 0, str_slti_1_m1
    T_OPI_VAL sltiu, 1, -1, 1, str_sltiu_1_m1_diverges
    T_OPI_VAL slti,  -1, 0, 1, str_slti_m1_0
    T_OPI_VAL sltiu, -1, 0, 0, str_sltiu_m1_0_diverges
    T_OPI_VAL slti,  INTX_MIN, 2047, 1, str_slti_min_immmax
    T_OPI_VAL sltiu, INTX_MIN, 2047, 0, str_sltiu_min_immmax_diverges
    T_OPI_VAL slti,  INTX_MAX, -2048, 0, str_slti_max_immmin
    T_OPI_VAL sltiu, INTX_MAX, -2048, 1, str_sltiu_max_immmin_diverges
    /* boundary right at the immediate's value */
    T_OPI_VAL slti,  2046, 2047, 1, str_slti_just_below_immmax
    T_OPI_VAL slti,  2047, 2047, 0, str_slti_equal_immmax
    T_OPI_VAL slti,  -2049, -2048, 1, str_slti_just_below_immmin
    T_OPI_VAL slti,  -2048, -2048, 0, str_slti_equal_immmin
    /* SLTIU idioms: imm=1 is SEQZ, imm=-1 compares against 0xff..ff */
    T_OPI_VAL sltiu, 0, 1, 1, str_sltiu_seqz_0
    T_OPI_VAL sltiu, 7, 1, 0, str_sltiu_seqz_7
    T_OPI_VAL sltiu, INTX_MIN, 1, 0, str_sltiu_seqz_min
    T_OPI_VAL sltiu, 0xfffffffffffffffe, -1, 1, str_sltiu_below_allones
    T_OPI_VAL sltiu, 0xffffffffffffffff, -1, 0, str_sltiu_equal_allones
    .if XLEN == 64                  /* the 64-vs-32 distinction itself */
    T_OPI_VAL sltiu, 0x00000000fffff800, -2048, 1, str_sltiu_imm_signext
    .endif
    T_OPI_PRESERVED slti,  5, str_slti_rs1_preserved
    T_OPI_PRESERVED sltiu, 5, str_sltiu_rs1_preserved

    /* ===== XORI ===== */
    .if XLEN == 64
    T_OPI_VAL xori, 0x1234567812345678, -1,    0xedcba987edcba987, str_xori_not
    T_OPI_VAL xori, 0x1234567812345678, 0x7ff, 0x1234567812345187, str_xori_low11
    T_OPI_VAL xori, 0x1234567812345678, -2048, 0xedcba987edcbae78, str_xori_imm_min_signext
    T_OPI_VAL xori, 0x1234567812345678, 0,     0x1234567812345678, str_xori_identity
    .else
    T_OPI_VAL xori, 0x12345678, -1,    0xedcba987, str_xori_not
    T_OPI_VAL xori, 0x12345678, 0x7ff, 0x12345187, str_xori_low11
    T_OPI_VAL xori, 0x12345678, -2048, 0xedcbae78, str_xori_imm_min_signext
    T_OPI_VAL xori, 0x12345678, 0,     0x12345678, str_xori_identity
    .endif
    T_OPI_VAL xori, 0x0000000000000555, 0x555, 0x0000000000000000, str_xori_equal
    T_OPI_PRESERVED xori, 0x555, str_xori_rs1_preserved

    /* ===== ORI ===== */
    .if XLEN == 64
    T_OPI_VAL ori, 0x1234567812345678, -2048, 0xfffffffffffffe78, str_ori_imm_min_signext
    T_OPI_VAL ori, 0x1234567812345678, -1,    0xffffffffffffffff, str_ori_absorption
    T_OPI_VAL ori, 0x1234567812345678, 0,     0x1234567812345678, str_ori_identity
    .else
    T_OPI_VAL ori, 0x12345678, -2048, 0xfffffe78, str_ori_imm_min_signext
    T_OPI_VAL ori, 0x12345678, -1,    0xffffffff, str_ori_absorption
    T_OPI_VAL ori, 0x12345678, 0,     0x12345678, str_ori_identity
    .endif
    T_OPI_VAL ori, 0x0000000000000000, 0x555, 0x0000000000000555, str_ori_pos_imm
    T_OPI_VAL ori, INTX_MIN, 0x7ff, INTX_MIN | 0x7ff, str_ori_pos_no_signext
    T_OPI_PRESERVED ori, 0x555, str_ori_rs1_preserved

    /* ===== ANDI ===== */
    .if XLEN == 64
    T_OPI_VAL andi, 0x1234567812345678, -1,    0x1234567812345678, str_andi_identity
    T_OPI_VAL andi, 0x1234567812345678, 0,     0x0000000000000000, str_andi_absorption
    T_OPI_VAL andi, 0x1234567812345678, 0x7ff, 0x0000000000000678, str_andi_low11
    T_OPI_VAL andi, 0x1234567812345678, -2048, 0x1234567812345000, str_andi_imm_min_signext
    .else
    T_OPI_VAL andi, 0x12345678, -1,    0x12345678, str_andi_identity
    T_OPI_VAL andi, 0x12345678, 0,     0x00000000, str_andi_absorption
    T_OPI_VAL andi, 0x12345678, 0x7ff, 0x00000678, str_andi_low11
    T_OPI_VAL andi, 0x12345678, -2048, 0x12345000, str_andi_imm_min_signext
    .endif
    T_OPI_VAL andi, 0xffffffffffffffff, 0x555, 0x0000000000000555, str_andi_pos_no_signext
    T_OPI_VAL andi, 0xffffffffffffffff, -0x556, 0xfffffffffffffaaa, str_andi_neg_signext
    T_OPI_PRESERVED andi, 0x555, str_andi_rs1_preserved

    /* ===== SLLI: every shamt bit individually, plus 0 and 63 ===== */
    T_OPI_VAL slli, 0x0000000000000001, 0,  0x0000000000000001, str_slli_sh0
    T_OPI_VAL slli, 0x0000000000000001, 1,  0x0000000000000002, str_slli_sh1
    T_OPI_VAL slli, 0x0000000000000001, 2,  0x0000000000000004, str_slli_sh2
    T_OPI_VAL slli, 0x0000000000000001, 4,  0x0000000000000010, str_slli_sh4
    T_OPI_VAL slli, 0x0000000000000001, 8,  0x0000000000000100, str_slli_sh8
    T_OPI_VAL slli, 0x0000000000000001, 16, 0x0000000000010000, str_slli_sh16
    .if XLEN == 64
    T_OPI_VAL slli, 0x0000000000000001, 32, 0x0000000100000000, str_slli_sh32
    T_OPI_VAL slli, 0x0000000000000001, 63, 0x8000000000000000, str_slli_sh63
    T_OPI_VAL slli, 0xffffffffffffffff, 32, 0xffffffff00000000, str_slli_allones_sh32
    T_OPI_VAL slli, 0x8000000000000001, 1,  0x0000000000000002, str_slli_truncates
    T_OPI_VAL slli, 0x00000000ffffffff, 1,  0x00000001fffffffe, str_slli_no_32bit_truncation
    .else
    T_OPI_VAL slli, 0x00000001, 31, 0x80000000, str_slli_sh31
    T_OPI_VAL slli, 0xffffffff, 16, 0xffff0000, str_slli_allones_sh16
    T_OPI_VAL slli, 0x80000001, 1,  0x00000002, str_slli_truncates
    .endif
    T_OPI_PRESERVED slli, 4, str_slli_rs1_preserved

    /* ===== SRLI / SRAI: same inputs through both, every shamt bit ===== */
    .if XLEN == 64
    T_OPI_VAL srli, 0x8000000000000000, 0,  0x8000000000000000, str_srli_sh0
    T_OPI_VAL srai, 0x8000000000000000, 0,  0x8000000000000000, str_srai_sh0
    T_OPI_VAL srli, 0x8000000000000000, 1,  0x4000000000000000, str_srli_sh1
    T_OPI_VAL srai, 0x8000000000000000, 1,  0xc000000000000000, str_srai_sh1
    T_OPI_VAL srli, 0x8000000000000000, 2,  0x2000000000000000, str_srli_sh2
    T_OPI_VAL srai, 0x8000000000000000, 2,  0xe000000000000000, str_srai_sh2
    T_OPI_VAL srli, 0x8000000000000000, 4,  0x0800000000000000, str_srli_sh4
    T_OPI_VAL srai, 0x8000000000000000, 4,  0xf800000000000000, str_srai_sh4
    T_OPI_VAL srli, 0x8000000000000000, 8,  0x0080000000000000, str_srli_sh8
    T_OPI_VAL srai, 0x8000000000000000, 8,  0xff80000000000000, str_srai_sh8
    T_OPI_VAL srli, 0x8000000000000000, 16, 0x0000800000000000, str_srli_sh16
    T_OPI_VAL srai, 0x8000000000000000, 16, 0xffff800000000000, str_srai_sh16
    T_OPI_VAL srli, 0x8000000000000000, 32, 0x0000000080000000, str_srli_sh32
    T_OPI_VAL srai, 0x8000000000000000, 32, 0xffffffff80000000, str_srai_sh32
    T_OPI_VAL srli, 0x8000000000000000, 63, 0x0000000000000001, str_srli_sh63
    T_OPI_VAL srai, 0x8000000000000000, 63, 0xffffffffffffffff, str_srai_sh63
    T_OPI_VAL srli, 0x4000000000000000, 2,  0x1000000000000000, str_srli_positive
    T_OPI_VAL srai, 0x4000000000000000, 2,  0x1000000000000000, str_srai_positive_no_signext
    .else
    T_OPI_VAL srli, 0x80000000, 0,  0x80000000, str_srli_sh0
    T_OPI_VAL srai, 0x80000000, 0,  0x80000000, str_srai_sh0
    T_OPI_VAL srli, 0x80000000, 1,  0x40000000, str_srli_sh1
    T_OPI_VAL srai, 0x80000000, 1,  0xc0000000, str_srai_sh1
    T_OPI_VAL srli, 0x80000000, 2,  0x20000000, str_srli_sh2
    T_OPI_VAL srai, 0x80000000, 2,  0xe0000000, str_srai_sh2
    T_OPI_VAL srli, 0x80000000, 4,  0x08000000, str_srli_sh4
    T_OPI_VAL srai, 0x80000000, 4,  0xf8000000, str_srai_sh4
    T_OPI_VAL srli, 0x80000000, 8,  0x00800000, str_srli_sh8
    T_OPI_VAL srai, 0x80000000, 8,  0xff800000, str_srai_sh8
    T_OPI_VAL srli, 0x80000000, 16, 0x00008000, str_srli_sh16
    T_OPI_VAL srai, 0x80000000, 16, 0xffff8000, str_srai_sh16
    T_OPI_VAL srli, 0x80000000, 31, 0x00000001, str_srli_sh31
    T_OPI_VAL srai, 0x80000000, 31, 0xffffffff, str_srai_sh31
    T_OPI_VAL srli, 0x40000000, 2,  0x10000000, str_srli_positive
    T_OPI_VAL srai, 0x40000000, 2,  0x10000000, str_srai_positive_no_signext
    .endif
    T_OPI_VAL srli, 0x0000000000000003, 1,  0x0000000000000001, str_srli_drops_low_bits
    T_OPI_VAL srai, 0xfffffffffffffffd, 1,  0xfffffffffffffffe, str_srai_rounds_toward_neg_inf
    T_OPI_PRESERVED srli, 4, str_srli_rs1_preserved
    T_OPI_PRESERVED srai, 4, str_srai_rs1_preserved

    jal     ra, bitx_i_op_imm

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

bitx_i_op_imm:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    /* 12-bit immediate: C(22,2) = 231 pairs each */
    BX_POOL 0x0123456789abcdef, 0
    BX_E_RRI5 BX_C_OPI, "addi, add, ADDI", 7, 28, "0x1,0x2,0x4,0x8,0x10,0x20,0x40,0x80,0x100,0x200,0x400,0x800", 0
    /* a small rs1, so some immediates compare above it and some below */
    BX_POOL 0x00000000000003a5, 0
    BX_E_RRI5 BX_C_OPI, "slti, slt, SLTI", 7, 28, "0x1,0x2,0x4,0x8,0x10,0x20,0x40,0x80,0x100,0x200,0x400,0x800", 0
    BX_E_RRI5 BX_C_OPI, "sltiu, sltu, SLTIU", 7, 28, "0x1,0x2,0x4,0x8,0x10,0x20,0x40,0x80,0x100,0x200,0x400,0x800", 0
    BX_POOL 0x5aa5f00f3cc3e11e, 0
    BX_E_RRI5 BX_C_OPI, "xori, xor, XORI", 7, 28, "0x1,0x2,0x4,0x8,0x10,0x20,0x40,0x80,0x100,0x200,0x400,0x800", 0
    BX_E_RRI5 BX_C_OPI, "ori, or, ORI", 7, 28, "0x1,0x2,0x4,0x8,0x10,0x20,0x40,0x80,0x100,0x200,0x400,0x800", 0
    BX_E_RRI5 BX_C_OPI, "andi, and, ANDI", 7, 28, "0x1,0x2,0x4,0x8,0x10,0x20,0x40,0x80,0x100,0x200,0x400,0x800", 0
    /* 6-bit shamt: C(16,2) = 120 pairs each (RV32: 5-bit shamt,
     * C(15,2) = 105) */
    BX_POOL 0x8123456789abcdef, 0
    .if XLEN == 64
    BX_E_RRI5 BX_C_SHI, "slli, sll, SLLI", 7, 28, "0x1,0x2,0x4,0x8,0x10,0x20", 0
    .else
    BX_E_RRI5 BX_C_SHI, "slli, sll, SLLI", 7, 28, "0x1,0x2,0x4,0x8,0x10", 0
    .endif
    .if XLEN == 64
    BX_E_RRI5 BX_C_SHI, "srli, srl, SRLI", 7, 28, "0x1,0x2,0x4,0x8,0x10,0x20", 0
    .else
    BX_E_RRI5 BX_C_SHI, "srli, srl, SRLI", 7, 28, "0x1,0x2,0x4,0x8,0x10", 0
    .endif
    .if XLEN == 64
    BX_E_RRI5 BX_C_SHI, "srai, sra, SRAI", 7, 28, "0x1,0x2,0x4,0x8,0x10,0x20", 0
    .else
    BX_E_RRI5 BX_C_SHI, "srai, sra, SRAI", 7, 28, "0x1,0x2,0x4,0x8,0x10", 0
    .endif

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

    .section .rodata
str_opi_rd_ra:  .asciz "ADDI rd=ra(x1) (OP-IMM format)"
str_opi_rd_t0:  .asciz "ADDI rd=t0(x5) (OP-IMM format)"
str_opi_rd_s0:  .asciz "ADDI rd=s0(x8) (OP-IMM format)"
str_opi_rd_a0:  .asciz "ADDI rd=a0(x10) (OP-IMM format)"
str_opi_rd_s10: .asciz "ADDI rd=s10(x26) (OP-IMM format)"
str_opi_rd_t6:  .asciz "ADDI rd=t6(x31) (OP-IMM format)"
str_opi_rs1_ra:  .asciz "ADDI rs1=ra(x1) (OP-IMM format)"
str_opi_rs1_t0:  .asciz "ADDI rs1=t0(x5) (OP-IMM format)"
str_opi_rs1_s0:  .asciz "ADDI rs1=s0(x8) (OP-IMM format)"
str_opi_rs1_a0:  .asciz "ADDI rs1=a0(x10) (OP-IMM format)"
str_opi_rs1_s10: .asciz "ADDI rs1=s10(x26) (OP-IMM format)"
str_opi_rs1_t6:  .asciz "ADDI rs1=t6(x31) (OP-IMM format)"
str_opi_rs1_x0_neg: .asciz "ADDI rs1=x0, imm=-2048 (OP-IMM format)"
str_opi_rs1_x0_pos: .asciz "ADDI rs1=x0, imm=+2047 (OP-IMM format)"
str_opi_rd_x0:      .asciz "ADDI rd=x0 discards result (OP-IMM format)"
str_opi_alias_rd_rs1: .asciz "ADDI rd==rs1 (OP-IMM format)"

str_addi_imm_max: .asciz "ADDI imm=+2047 (max)"
str_addi_imm_min: .asciz "ADDI imm=-2048 (min, sign-extended)"
str_addi_imm_m1:  .asciz "ADDI imm=-1 (sign-extended to all ones)"
str_addi_imm_0:   .asciz "ADDI imm=0 (MV idiom)"
str_addi_borrow_across_32: .asciz "ADDI 2^32 + -1 borrows across bit 32"
str_addi_carry_across_32:  .asciz "ADDI 0xffffffff + 1 carries into bit 32"
    .if XLEN == 64
str_addi_wrap:    .asciz "ADDI 64-bit wrap 0xfff...f + 1 = 0"
    .else
str_addi_wrap:    .asciz "ADDI 32-bit wrap 0xfff...f + 1 = 0"
    .endif
    .if XLEN == 64
str_addi_int64_max_plus1:  .asciz "ADDI INT64_MAX + 1 wraps to INT64_MIN"
    .else
str_addi_int64_max_plus1:  .asciz "ADDI INT32_MAX + 1 wraps to INT32_MIN"
    .endif
    .if XLEN == 64
str_addi_int64_min_minus1: .asciz "ADDI INT64_MIN + -1 wraps to INT64_MAX"
    .else
str_addi_int64_min_minus1: .asciz "ADDI INT32_MIN + -1 wraps to INT32_MAX"
    .endif
str_addi_cancel:  .asciz "ADDI 1000 + -1000 = 0"
str_addi_pattern_pos: .asciz "ADDI pattern + 0x555"
str_addi_pattern_neg: .asciz "ADDI pattern + -0x556"
str_addi_rs1_preserved: .asciz "ADDI rs1 unmodified"

str_slti_eq:  .asciz "SLTI 0,0 = 0"
str_sltiu_eq: .asciz "SLTIU 0,0 = 0"
str_slti_1_2:  .asciz "SLTI 1,2 = 1"
str_sltiu_1_2: .asciz "SLTIU 1,2 = 1"
str_slti_2_1:  .asciz "SLTI 2,1 = 0"
str_sltiu_2_1: .asciz "SLTIU 2,1 = 0"
str_slti_m1_1:  .asciz "SLTI -1,1 = 1 (signed: -1 < 1)"
str_sltiu_m1_1_diverges: .asciz "SLTIU -1,1 = 0 (unsigned: 0xff..ff > 1) DIVERGES from SLTI"
str_slti_1_m1:  .asciz "SLTI 1,-1 = 0 (signed)"
str_sltiu_1_m1_diverges: .asciz "SLTIU 1,-1 = 1 (imm sign-extended to 0xff..ff) DIVERGES"
str_slti_m1_0:  .asciz "SLTI -1,0 = 1 (signed)"
str_sltiu_m1_0_diverges: .asciz "SLTIU -1,0 = 0 (unsigned) DIVERGES from SLTI"
    .if XLEN == 64
str_slti_min_immmax:  .asciz "SLTI INT64_MIN,2047 = 1 (signed)"
    .else
str_slti_min_immmax:  .asciz "SLTI INT32_MIN,2047 = 1 (signed)"
    .endif
    .if XLEN == 64
str_sltiu_min_immmax_diverges: .asciz "SLTIU 2^63,2047 = 0 (unsigned) DIVERGES from SLTI"
    .else
str_sltiu_min_immmax_diverges: .asciz "SLTIU 2^31,2047 = 0 (unsigned) DIVERGES from SLTI"
    .endif
    .if XLEN == 64
str_slti_max_immmin:  .asciz "SLTI INT64_MAX,-2048 = 0 (signed)"
    .else
str_slti_max_immmin:  .asciz "SLTI INT32_MAX,-2048 = 0 (signed)"
    .endif
    .if XLEN == 64
str_sltiu_max_immmin_diverges: .asciz "SLTIU INT64_MAX,-2048 = 1 (unsigned) DIVERGES from SLTI"
    .else
str_sltiu_max_immmin_diverges: .asciz "SLTIU INT32_MAX,-2048 = 1 (unsigned) DIVERGES from SLTI"
    .endif
str_slti_just_below_immmax: .asciz "SLTI 2046,2047 = 1"
str_slti_equal_immmax:      .asciz "SLTI 2047,2047 = 0 (strict)"
str_slti_just_below_immmin: .asciz "SLTI -2049,-2048 = 1"
str_slti_equal_immmin:      .asciz "SLTI -2048,-2048 = 0 (strict)"
str_sltiu_seqz_0:   .asciz "SLTIU x,1 (SEQZ) x=0 -> 1"
str_sltiu_seqz_7:   .asciz "SLTIU x,1 (SEQZ) x=7 -> 0"
    .if XLEN == 64
str_sltiu_seqz_min: .asciz "SLTIU x,1 (SEQZ) x=2^63 -> 0"
    .else
str_sltiu_seqz_min: .asciz "SLTIU x,1 (SEQZ) x=2^31 -> 0"
    .endif
str_sltiu_below_allones: .asciz "SLTIU 0xff..fe,-1 = 1 (imm is 0xff..ff unsigned)"
str_sltiu_equal_allones: .asciz "SLTIU 0xff..ff,-1 = 0"
str_sltiu_imm_signext:   .asciz "SLTIU 0xfffff800,-2048 = 1 (imm sign-extended to 64, not 32)"
str_slti_rs1_preserved:  .asciz "SLTI rs1 unmodified"
str_sltiu_rs1_preserved: .asciz "SLTIU rs1 unmodified"

    .if XLEN == 64
str_xori_not:             .asciz "XORI imm=-1 is a full 64-bit NOT"
    .else
str_xori_not:             .asciz "XORI imm=-1 is a full 32-bit NOT"
    .endif
str_xori_low11:           .asciz "XORI imm=0x7ff flips only the low 11 bits"
    .if XLEN == 64
str_xori_imm_min_signext: .asciz "XORI imm=-2048 flips bits 63:11"
    .else
str_xori_imm_min_signext: .asciz "XORI imm=-2048 flips bits 31:11"
    .endif
str_xori_identity:        .asciz "XORI identity (x ^ 0 = x)"
str_xori_equal:           .asciz "XORI equal operands = 0"
str_xori_rs1_preserved:   .asciz "XORI rs1 unmodified"

    .if XLEN == 64
str_ori_imm_min_signext: .asciz "ORI imm=-2048 sets bits 63:11"
    .else
str_ori_imm_min_signext: .asciz "ORI imm=-2048 sets bits 31:11"
    .endif
str_ori_absorption:      .asciz "ORI absorption (x | -1 = all ones)"
str_ori_identity:        .asciz "ORI identity (x | 0 = x)"
str_ori_pos_imm:         .asciz "ORI 0 | 0x555"
str_ori_pos_no_signext:  .asciz "ORI positive imm leaves upper bits alone"
str_ori_rs1_preserved:   .asciz "ORI rs1 unmodified"

str_andi_identity:        .asciz "ANDI identity (x & -1 = x)"
str_andi_absorption:      .asciz "ANDI absorption (x & 0 = 0)"
str_andi_low11:           .asciz "ANDI imm=0x7ff keeps only the low 11 bits"
str_andi_imm_min_signext: .asciz "ANDI imm=-2048 clears only the low 11 bits"
    .if XLEN == 64
str_andi_pos_no_signext:  .asciz "ANDI positive imm clears bits 63:12"
    .else
str_andi_pos_no_signext:  .asciz "ANDI positive imm clears bits 31:12"
    .endif
    .if XLEN == 64
str_andi_neg_signext:     .asciz "ANDI imm=-0x556 keeps bits 63:12"
    .else
str_andi_neg_signext:     .asciz "ANDI imm=-0x556 keeps bits 31:12"
    .endif
str_andi_rs1_preserved:   .asciz "ANDI rs1 unmodified"

str_slli_sh0:  .asciz "SLLI shamt=0"
str_slli_sh1:  .asciz "SLLI shamt=1 (shamt bit 0)"
str_slli_sh2:  .asciz "SLLI shamt=2 (shamt bit 1)"
str_slli_sh4:  .asciz "SLLI shamt=4 (shamt bit 2)"
str_slli_sh8:  .asciz "SLLI shamt=8 (shamt bit 3)"
str_slli_sh16: .asciz "SLLI shamt=16 (shamt bit 4)"
str_slli_sh32: .asciz "SLLI shamt=32 (shamt bit 5, RV64-only)"
str_slli_sh63: .asciz "SLLI shamt=63 (max)"
str_slli_allones_sh32: .asciz "SLLI all-ones by 32"
str_slli_truncates:    .asciz "SLLI truncates, does not rotate"
str_slli_no_32bit_truncation: .asciz "SLLI carries past bit 31 (not a 32-bit shift)"
    .if XLEN == 32
str_slli_sh31: .asciz "SLLI shamt=31 (max)"
str_slli_allones_sh16: .asciz "SLLI all-ones by 16"
str_srli_sh31: .asciz "SRLI shamt=31 (max)"
str_srai_sh31: .asciz "SRAI shamt=31 (max, all sign-fill)"
    .endif
str_slli_rs1_preserved: .asciz "SLLI rs1 unmodified"

str_srli_sh0:  .asciz "SRLI shamt=0"
str_srai_sh0:  .asciz "SRAI shamt=0"
str_srli_sh1:  .asciz "SRLI shamt=1 (zero-fill)"
str_srai_sh1:  .asciz "SRAI shamt=1 (sign-fill) DIVERGES from SRLI"
str_srli_sh2:  .asciz "SRLI shamt=2"
str_srai_sh2:  .asciz "SRAI shamt=2"
str_srli_sh4:  .asciz "SRLI shamt=4"
str_srai_sh4:  .asciz "SRAI shamt=4"
str_srli_sh8:  .asciz "SRLI shamt=8"
str_srai_sh8:  .asciz "SRAI shamt=8"
str_srli_sh16: .asciz "SRLI shamt=16"
str_srai_sh16: .asciz "SRAI shamt=16"
str_srli_sh32: .asciz "SRLI shamt=32 (shamt bit 5, RV64-only)"
str_srai_sh32: .asciz "SRAI shamt=32 (shamt bit 5, RV64-only)"
str_srli_sh63: .asciz "SRLI shamt=63 (max)"
str_srai_sh63: .asciz "SRAI shamt=63 (max, all sign-fill)"
str_srli_positive:            .asciz "SRLI positive input"
str_srai_positive_no_signext: .asciz "SRAI positive input needs no sign-extension"
str_srli_drops_low_bits:        .asciz "SRLI 3>>1 = 1 (bits shifted out are lost)"
str_srai_rounds_toward_neg_inf: .asciz "SRAI -3>>1 = -2 (rounds toward -inf)"
str_srli_rs1_preserved: .asciz "SRLI rs1 unmodified"
str_srai_rs1_preserved: .asciz "SRAI rs1 unmodified"
