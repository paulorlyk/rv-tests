/* =====================================================================
 * i/op_alu.S  --  RV64I base-ISA OP (R-type) ALU instructions:
 *                     ADD, SUB, SLL, SLT, SLTU, XOR, SRL, SRA, OR, AND
 *
 * Part of the RV64I base-ISA suite; see i/tests.S for how this
 * plugs into the rest (main_tests.S -> i/tests.S -> here), and
 * common.S for the boot/UART/reporting harness everything sits on
 * ("check", "uart_puts" are used from there; nothing else).
 *
 * All ten share one R-type encoding (rd, rs1, rs2, funct3, funct7) and
 * differ only in the operation. So, the same organising idea as
 * i/branches.S: the register fields carry identical decode risk
 * regardless of which of the ten it is, so rd/rs1/rs2 and their
 * aliasing combinations are swept *once*, through ADD, rather than
 * ten times over. What's actually specific to each instruction -- the
 * operation's own correctness on interesting operand values -- gets
 * the real per-instruction depth.
 *
 * Per-instruction highlights:
 *   - SLL/SRL/SRA: only the low 6 bits of rs2 select the shift amount
 *     (RV64's shamt field is 6 bits) -- the rest of rs2 must be
 *     ignored, not folded in some other way. Tested directly: rs2=64
 *     must behave identically to rs2=0 (both mask to shamt=0), and
 *     rs2=65 identically to rs2=1. SLL/SRL also get a truncation (not
 *     rotation) check, the same property tested for C.SLLI in the RVC
 *     suite: a bit shifted past bit 63 must be gone, not wrapped to
 *     bit 0.
 *   - SLT/SLTU: signed vs unsigned comparison, with the same
 *     divergence pairs used for BLT/BLTU in i/branches.S (rs1=-1,
 *     rs2=1 gives SLT=1 but SLTU=0 on identical bits) and the same
 *     rationale -- this is exactly the bug class (signed/unsigned
 *     mixup) that has bitten this project's own test code before.
 *
 * Bit independence across fields (bitx_i_op_alu, at the end): the per-field
 * sweeps above go through ADD only, but a decoder fault where one
 * register-field bit misbehaves only together with another bit -- in
 * the same field, in another field, or in combination with this
 * instruction's own funct3/funct7 -- needs every bit pair of rd/rs1/rs2
 * set together, per instruction. So all ten get the full C(15,2) = 105
 * pairs; see bitx.inc for the method and the reference-value scheme.
 *
 * RV32 image (xlen.inc): only rs2[4:0] selects the shift amount, so the
 * masking tests use rs2=32/33 and the maximum is 31.
 * ===================================================================== */

    .include "xlen.inc"
    .include "harness.inc"

    .option norvc            /* mandatory, not stylistic: several of these
                               * (ADD/SUB/AND/OR/XOR among x8-x15 registers)
                               * have direct compressed equivalents the
                               * assembler would otherwise substitute for,
                               * silently testing the RVC instruction
                               * instead of this one. */

    .include "bitx.inc"

    .global tests_i_op_alu

    .section .text

/* =======================================================================
 *  Shared macros
 * ======================================================================= */

/* T_OP_RD/RS1/RS2 insn, reg, v1, v2, expect, name -- sweep one
 * register field at a time (through ADD, since decode risk is
 * identical across all ten), the other two fixed at registers outside
 * the swept list. reg may be a0/a1/a2 -- result captured to t2 before
 * those are reused. */
.macro T_OP_RD insn, rdreg, v1, v2, expect, name
    TEST_BEGIN \name
    LIX     t3, \v1
    LIX     t4, \v2
    \insn   \rdreg, t3, t4
    mv      t2, \rdreg
    la      a0, \name
    LIX     a1, \expect
    mv      a2, t2
    call    check
.endm

.macro T_OP_RS1 insn, rs1reg, v1, v2, expect, name
    TEST_BEGIN \name
    LIX     \rs1reg, \v1
    LIX     t4, \v2
    \insn   t2, \rs1reg, t4
    la      a0, \name
    LIX     a1, \expect
    mv      a2, t2
    call    check
.endm

.macro T_OP_RS2 insn, rs2reg, v1, v2, expect, name
    TEST_BEGIN \name
    LIX     t3, \v1
    LIX     \rs2reg, \v2
    \insn   t2, t3, \rs2reg
    la      a0, \name
    LIX     a1, \expect
    mv      a2, t2
    call    check
.endm

/* T_OP_VAL insn, v1, v2, expect, name -- fixed rd=t2/rs1=t3/rs2=t4,
 * sweep the operand values. */
.macro T_OP_VAL insn, v1, v2, expect, name
    TEST_BEGIN \name
    LIX     t3, \v1
    LIX     t4, \v2
    \insn   t2, t3, t4
    la      a0, \name
    LIX     a1, \expect
    mv      a2, t2
    call    check
.endm

tests_i_op_alu:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    /* ===== register sweep (through ADD; identical decode risk for
     * all ten) ===== */
    T_OP_RD add, ra,  100, 23, 123, str_op_rd_ra
    T_OP_RD add, t0,  100, 23, 123, str_op_rd_t0
    T_OP_RD add, s0,  100, 23, 123, str_op_rd_s0
    T_OP_RD add, a0,  100, 23, 123, str_op_rd_a0
    T_OP_RD add, s10, 100, 23, 123, str_op_rd_s10
    T_OP_RD add, t6,  100, 23, 123, str_op_rd_t6

    T_OP_RS1 add, ra,  100, 23, 123, str_op_rs1_ra
    T_OP_RS1 add, t0,  100, 23, 123, str_op_rs1_t0
    T_OP_RS1 add, s0,  100, 23, 123, str_op_rs1_s0
    T_OP_RS1 add, a0,  100, 23, 123, str_op_rs1_a0
    T_OP_RS1 add, s10, 100, 23, 123, str_op_rs1_s10
    T_OP_RS1 add, t6,  100, 23, 123, str_op_rs1_t6

    T_OP_RS2 add, ra,  100, 23, 123, str_op_rs2_ra
    T_OP_RS2 add, t0,  100, 23, 123, str_op_rs2_t0
    T_OP_RS2 add, s0,  100, 23, 123, str_op_rs2_s0
    T_OP_RS2 add, a0,  100, 23, 123, str_op_rs2_a0
    T_OP_RS2 add, s10, 100, 23, 123, str_op_rs2_s10
    T_OP_RS2 add, t6,  100, 23, 123, str_op_rs2_t6

    /* ===== aliasing (through ADD): every register-overlap combination ===== */
    TEST_BEGIN str_op_alias_all_same
    LIX     t1, 30
    add     t1, t1, t1              /* rd==rs1==rs2: double itself */
    la      a0, str_op_alias_all_same
    LIX     a1, 60
    mv      a2, t1
    call    check

    TEST_BEGIN str_op_alias_rd_rs1
    LIX     t1, 30
    LIX     t2, 12
    add     t1, t1, t2              /* rd==rs1 */
    la      a0, str_op_alias_rd_rs1
    LIX     a1, 42
    mv      a2, t1
    call    check

    TEST_BEGIN str_op_alias_rd_rs2
    LIX     t1, 30
    LIX     t2, 12
    add     t2, t1, t2              /* rd==rs2 */
    la      a0, str_op_alias_rd_rs2
    LIX     a1, 42
    mv      a2, t2
    call    check

    TEST_BEGIN str_op_alias_rs1_rs2
    LIX     t1, 21
    add     t2, t1, t1              /* rs1==rs2, rd distinct */
    la      a0, str_op_alias_rs1_rs2
    LIX     a1, 42
    mv      a2, t2
    call    check

    /* ===== ADD ===== */
    T_OP_VAL add, 0xffffffffffffffff, 1, 0x0000000000000000, str_add_wrap
    .if XLEN == 64
    T_OP_VAL add, 0xfedcba9876543210, 0x0123456789abcdef, 0xffffffffffffffff, str_add_walking
    .else
    T_OP_VAL add, 0xfedcba98, 0x01234567, 0xffffffff, str_add_walking
    .endif
    T_OP_VAL add, 0, 0, 0, str_add_zero
    TEST_BEGIN str_add_rs1_preserved
    LIX     t3, 100
    LIX     t4, 23
    mv      t5, t3
    mv      t6, t4
    add     t2, t3, t4
    la      a0, str_add_rs1_preserved
    mv      a1, t5
    mv      a2, t3
    call    check
    TEST_BEGIN str_add_rs2_preserved
    la      a0, str_add_rs2_preserved
    mv      a1, t6
    mv      a2, t4
    call    check

    /* ===== SUB ===== */
    T_OP_VAL sub, 0, 1, 0xffffffffffffffff, str_sub_wrap
    .if XLEN == 64
    T_OP_VAL sub, 0x8000000000000000, 1, 0x7fffffffffffffff, str_sub_minwrap
    .else
    T_OP_VAL sub, 0x80000000, 1, 0x7fffffff, str_sub_minwrap
    .endif
    T_OP_VAL sub, 0, 0, 0, str_sub_zero
    T_OP_VAL sub, 100, 100, 0, str_sub_equal
    TEST_BEGIN str_sub_rs1_preserved
    LIX     t3, 100
    LIX     t4, 23
    mv      t5, t3
    mv      t6, t4
    sub     t2, t3, t4
    la      a0, str_sub_rs1_preserved
    mv      a1, t5
    mv      a2, t3
    call    check
    TEST_BEGIN str_sub_rs2_preserved
    la      a0, str_sub_rs2_preserved
    mv      a1, t6
    mv      a2, t4
    call    check

    /* ===== SLL: only rs2[5:0] (RV32: rs2[4:0]) selects the shift
     *     amount ===== */
    T_OP_VAL sll, 0xffffffffffffffff, 0,  0xffffffffffffffff, str_sll_sh0
    T_OP_VAL sll, 0xffffffffffffffff, 1,  0xfffffffffffffffe, str_sll_sh1
    .if XLEN == 64
    T_OP_VAL sll, 0xffffffffffffffff, 32, 0xffffffff00000000, str_sll_sh32
    T_OP_VAL sll, 0xffffffffffffffff, 63, 0x8000000000000000, str_sll_sh63
    T_OP_VAL sll, 0xffffffffffffffff, 64, 0xffffffffffffffff, str_sll_sh64_masks_to_0
    T_OP_VAL sll, 0xffffffffffffffff, 65, 0xfffffffffffffffe, str_sll_sh65_masks_to_1
    T_OP_VAL sll, 0x8000000000000001, 1,  0x0000000000000002, str_sll_truncates
    .else
    T_OP_VAL sll, 0xffffffff, 16, 0xffff0000, str_sll_sh16
    T_OP_VAL sll, 0xffffffff, 31, 0x80000000, str_sll_sh31
    T_OP_VAL sll, 0xffffffff, 32, 0xffffffff, str_sll_sh32_masks_to_0
    T_OP_VAL sll, 0xffffffff, 33, 0xfffffffe, str_sll_sh33_masks_to_1
    T_OP_VAL sll, 0x80000001, 1,  0x00000002, str_sll_truncates
    .endif
    TEST_BEGIN str_sll_rs1_preserved
    LIX     t3, 100
    LIX     t4, 4
    mv      t5, t3
    mv      t6, t4
    sll     t2, t3, t4
    la      a0, str_sll_rs1_preserved
    mv      a1, t5
    mv      a2, t3
    call    check
    TEST_BEGIN str_sll_rs2_preserved
    la      a0, str_sll_rs2_preserved
    mv      a1, t6
    mv      a2, t4
    call    check

    /* ===== SRL: only rs2[5:0] (RV32: rs2[4:0]) selects the shift
     *     amount, logical (zero-fill from the top) ===== */
    T_OP_VAL srl, 0xffffffffffffffff, 0,  0xffffffffffffffff, str_srl_sh0
    .if XLEN == 64
    T_OP_VAL srl, 0xffffffffffffffff, 1,  0x7fffffffffffffff, str_srl_sh1
    T_OP_VAL srl, 0xffffffffffffffff, 32, 0x00000000ffffffff, str_srl_sh32
    T_OP_VAL srl, 0xffffffffffffffff, 63, 0x0000000000000001, str_srl_sh63
    T_OP_VAL srl, 0xffffffffffffffff, 64, 0xffffffffffffffff, str_srl_sh64_masks_to_0
    T_OP_VAL srl, 0xffffffffffffffff, 65, 0x7fffffffffffffff, str_srl_sh65_masks_to_1
    .else
    T_OP_VAL srl, 0xffffffff, 1,  0x7fffffff, str_srl_sh1
    T_OP_VAL srl, 0xffffffff, 16, 0x0000ffff, str_srl_sh16
    T_OP_VAL srl, 0xffffffff, 31, 0x00000001, str_srl_sh31
    T_OP_VAL srl, 0xffffffff, 32, 0xffffffff, str_srl_sh32_masks_to_0
    T_OP_VAL srl, 0xffffffff, 33, 0x7fffffff, str_srl_sh33_masks_to_1
    .endif
    TEST_BEGIN str_srl_rs1_preserved
    LIX     t3, 100
    LIX     t4, 4
    mv      t5, t3
    mv      t6, t4
    srl     t2, t3, t4
    la      a0, str_srl_rs1_preserved
    mv      a1, t5
    mv      a2, t3
    call    check
    TEST_BEGIN str_srl_rs2_preserved
    la      a0, str_srl_rs2_preserved
    mv      a1, t6
    mv      a2, t4
    call    check

    /* ===== SRA: only rs2[5:0] (RV32: rs2[4:0]) selects the shift
     *     amount, arithmetic (sign-fill from the top) ===== */
    .if XLEN == 64
    T_OP_VAL sra, 0x8000000000000000, 0,  0x8000000000000000, str_sra_sh0
    T_OP_VAL sra, 0x8000000000000000, 1,  0xc000000000000000, str_sra_sh1
    T_OP_VAL sra, 0x8000000000000000, 32, 0xffffffff80000000, str_sra_sh32
    T_OP_VAL sra, 0x8000000000000000, 63, 0xffffffffffffffff, str_sra_sh63
    T_OP_VAL sra, 0x8000000000000000, 64, 0x8000000000000000, str_sra_sh64_masks_to_0
    T_OP_VAL sra, 0x8000000000000000, 65, 0xc000000000000000, str_sra_sh65_masks_to_1
    T_OP_VAL sra, 0x7fffffffffffffff, 4,  0x07ffffffffffffff, str_sra_positive_no_signext
    .else
    T_OP_VAL sra, 0x80000000, 0,  0x80000000, str_sra_sh0
    T_OP_VAL sra, 0x80000000, 1,  0xc0000000, str_sra_sh1
    T_OP_VAL sra, 0x80000000, 16, 0xffff8000, str_sra_sh16
    T_OP_VAL sra, 0x80000000, 31, 0xffffffff, str_sra_sh31
    T_OP_VAL sra, 0x80000000, 32, 0x80000000, str_sra_sh32_masks_to_0
    T_OP_VAL sra, 0x80000000, 33, 0xc0000000, str_sra_sh33_masks_to_1
    T_OP_VAL sra, 0x7fffffff, 4,  0x07ffffff, str_sra_positive_no_signext
    .endif
    TEST_BEGIN str_sra_rs1_preserved
    LIX     t3, 100
    LIX     t4, 4
    mv      t5, t3
    mv      t6, t4
    sra     t2, t3, t4
    la      a0, str_sra_rs1_preserved
    mv      a1, t5
    mv      a2, t3
    call    check
    TEST_BEGIN str_sra_rs2_preserved
    la      a0, str_sra_rs2_preserved
    mv      a1, t6
    mv      a2, t4
    call    check

    /* ===== XOR ===== */
    .if XLEN == 64
    T_OP_VAL xor, 0xfedcba9876543210, 0x123456789abcdef0, 0xece8ece0ece8ece0, str_xor_walking
    T_OP_VAL xor, 0xffffffffffffffff, 0xffffffffffffffff, 0x0000000000000000, str_xor_self_via_equal_values
    T_OP_VAL xor, 0x1234567812345678, 0x0000000000000000, 0x1234567812345678, str_xor_identity
    .else
    T_OP_VAL xor, 0xfedcba98, 0x12345678, 0xece8ece0, str_xor_walking
    T_OP_VAL xor, 0xffffffff, 0xffffffff, 0x00000000, str_xor_self_via_equal_values
    T_OP_VAL xor, 0x12345678, 0x00000000, 0x12345678, str_xor_identity
    .endif
    TEST_BEGIN str_xor_rs1_preserved
    LIX     t3, 100
    LIX     t4, 23
    mv      t5, t3
    mv      t6, t4
    xor     t2, t3, t4
    la      a0, str_xor_rs1_preserved
    mv      a1, t5
    mv      a2, t3
    call    check
    TEST_BEGIN str_xor_rs2_preserved
    la      a0, str_xor_rs2_preserved
    mv      a1, t6
    mv      a2, t4
    call    check

    /* ===== OR ===== */
    .if XLEN == 64
    T_OP_VAL or, 0xfedcba9876543210, 0x123456789abcdef0, 0xfefcfef8fefcfef0, str_or_walking
    T_OP_VAL or, 0x1234567812345678, 0xffffffffffffffff, 0xffffffffffffffff, str_or_absorption
    T_OP_VAL or, 0x1234567812345678, 0x0000000000000000, 0x1234567812345678, str_or_identity
    .else
    T_OP_VAL or, 0xfedcba98, 0x12345678, 0xfefcfef8, str_or_walking
    T_OP_VAL or, 0x12345678, 0xffffffff, 0xffffffff, str_or_absorption
    T_OP_VAL or, 0x12345678, 0x00000000, 0x12345678, str_or_identity
    .endif
    TEST_BEGIN str_or_rs1_preserved
    LIX     t3, 100
    LIX     t4, 23
    mv      t5, t3
    mv      t6, t4
    or      t2, t3, t4
    la      a0, str_or_rs1_preserved
    mv      a1, t5
    mv      a2, t3
    call    check
    TEST_BEGIN str_or_rs2_preserved
    la      a0, str_or_rs2_preserved
    mv      a1, t6
    mv      a2, t4
    call    check

    /* ===== AND ===== */
    .if XLEN == 64
    T_OP_VAL and, 0xfedcba9876543210, 0x123456789abcdef0, 0x1214121812141210, str_and_walking
    T_OP_VAL and, 0x1234567812345678, 0x0000000000000000, 0x0000000000000000, str_and_absorption
    T_OP_VAL and, 0x1234567812345678, 0xffffffffffffffff, 0x1234567812345678, str_and_identity
    .else
    T_OP_VAL and, 0xfedcba98, 0x12345678, 0x12141218, str_and_walking
    T_OP_VAL and, 0x12345678, 0x00000000, 0x00000000, str_and_absorption
    T_OP_VAL and, 0x12345678, 0xffffffff, 0x12345678, str_and_identity
    .endif
    TEST_BEGIN str_and_rs1_preserved
    LIX     t3, 100
    LIX     t4, 23
    mv      t5, t3
    mv      t6, t4
    and     t2, t3, t4
    la      a0, str_and_rs1_preserved
    mv      a1, t5
    mv      a2, t3
    call    check
    TEST_BEGIN str_and_rs2_preserved
    la      a0, str_and_rs2_preserved
    mv      a1, t6
    mv      a2, t4
    call    check

    /* ===== SLT / SLTU: signed vs unsigned comparison truth table.
     *     Same divergence pairs as BLT/BLTU in i/branches.S. ===== */
    T_OP_VAL slt,  0, 0, 0, str_slt_eq
    T_OP_VAL sltu, 0, 0, 0, str_sltu_eq
    T_OP_VAL slt,  1, 2, 1, str_slt_1_2
    T_OP_VAL sltu, 1, 2, 1, str_sltu_1_2
    T_OP_VAL slt,  2, 1, 0, str_slt_2_1
    T_OP_VAL sltu, 2, 1, 0, str_sltu_2_1
    T_OP_VAL slt,  -1, 1, 1, str_slt_m1_1
    T_OP_VAL sltu, -1, 1, 0, str_sltu_m1_1_diverges
    T_OP_VAL slt,  1, -1, 0, str_slt_1_m1
    T_OP_VAL sltu, 1, -1, 1, str_sltu_1_m1_diverges
    T_OP_VAL slt,  -1, 0, 1, str_slt_m1_0
    T_OP_VAL sltu, -1, 0, 0, str_sltu_m1_0_diverges
    .if XLEN == 64
    T_OP_VAL slt,  0x8000000000000000, 0x7fffffffffffffff, 1, str_slt_minmax
    T_OP_VAL sltu, 0x8000000000000000, 0x7fffffffffffffff, 0, str_sltu_minmax_diverges
    T_OP_VAL slt,  0x7fffffffffffffff, 0x8000000000000000, 0, str_slt_maxmin
    T_OP_VAL sltu, 0x7fffffffffffffff, 0x8000000000000000, 1, str_sltu_maxmin_diverges
    .else
    T_OP_VAL slt,  0x80000000, 0x7fffffff, 1, str_slt_minmax
    T_OP_VAL sltu, 0x80000000, 0x7fffffff, 0, str_sltu_minmax_diverges
    T_OP_VAL slt,  0x7fffffff, 0x80000000, 0, str_slt_maxmin
    T_OP_VAL sltu, 0x7fffffff, 0x80000000, 1, str_sltu_maxmin_diverges
    .endif
    TEST_BEGIN str_slt_rs1_preserved
    LIX     t3, 100
    LIX     t4, 23
    mv      t5, t3
    mv      t6, t4
    slt     t2, t3, t4
    la      a0, str_slt_rs1_preserved
    mv      a1, t5
    mv      a2, t3
    call    check
    TEST_BEGIN str_slt_rs2_preserved
    la      a0, str_slt_rs2_preserved
    mv      a1, t6
    mv      a2, t4
    call    check

    jal     ra, bitx_i_op_alu

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  Bit independence across fields: every bit pair of rd/rs1/rs2, for
 *  each of the ten (bitx.inc). Operand values are chosen per operation
 *  so the result depends on every operand bit that matters: a shift
 *  amount of 37 (with junk above bit 5 that must be ignored; on RV32 the
 *  truncated operand gives 5, with junk above bit 4), and
 *  SLT/SLTU operands that compare true, so the reference for aliased
 *  rs1 == rs2 (equal operands, false) visibly differs.
 * ======================================================================= */
bitx_i_op_alu:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    BX_POOL 0x0123456789abcdef, 0x7edcba9876543211
    BX_E_RRR5 BX_C_RRR, "add, ADD"
    BX_E_RRR5 BX_C_RRR, "sub, SUB"
    BX_POOL 0x5aa5f00f3cc3e11e, 0x0123456789abcdef
    BX_E_RRR5 BX_C_RRR, "xor, XOR"
    BX_E_RRR5 BX_C_RRR, "or, OR"
    BX_E_RRR5 BX_C_RRR, "and, AND"
    BX_POOL 0x8123456789abcdef, 0xfedcba9876543225
    BX_E_RRR5 BX_C_RRR, "sll, SLL"
    BX_E_RRR5 BX_C_RRR, "srl, SRL"
    BX_E_RRR5 BX_C_RRR, "sra, SRA"
    BX_POOL 0xfffffffedcba9877, 0x0000000000002345
    BX_E_RRR5 BX_C_RRR, "slt, SLT"
    BX_POOL 0x0000000000002345, 0xfedcba9876543210
    BX_E_RRR5 BX_C_RRR, "sltu, SLTU"

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

    .section .rodata
str_op_rd_ra:  .asciz "OP rd=ra(x1) (via ADD)"
str_op_rd_t0:  .asciz "OP rd=t0(x5) (via ADD)"
str_op_rd_s0:  .asciz "OP rd=s0(x8) (via ADD)"
str_op_rd_a0:  .asciz "OP rd=a0(x10) (via ADD)"
str_op_rd_s10: .asciz "OP rd=s10(x26) (via ADD)"
str_op_rd_t6:  .asciz "OP rd=t6(x31) (via ADD)"
str_op_rs1_ra:  .asciz "OP rs1=ra(x1) (via ADD)"
str_op_rs1_t0:  .asciz "OP rs1=t0(x5) (via ADD)"
str_op_rs1_s0:  .asciz "OP rs1=s0(x8) (via ADD)"
str_op_rs1_a0:  .asciz "OP rs1=a0(x10) (via ADD)"
str_op_rs1_s10: .asciz "OP rs1=s10(x26) (via ADD)"
str_op_rs1_t6:  .asciz "OP rs1=t6(x31) (via ADD)"
str_op_rs2_ra:  .asciz "OP rs2=ra(x1) (via ADD)"
str_op_rs2_t0:  .asciz "OP rs2=t0(x5) (via ADD)"
str_op_rs2_s0:  .asciz "OP rs2=s0(x8) (via ADD)"
str_op_rs2_a0:  .asciz "OP rs2=a0(x10) (via ADD)"
str_op_rs2_s10: .asciz "OP rs2=s10(x26) (via ADD)"
str_op_rs2_t6:  .asciz "OP rs2=t6(x31) (via ADD)"
str_op_alias_all_same: .asciz "OP rd==rs1==rs2 (via ADD, doubles)"
str_op_alias_rd_rs1:   .asciz "OP rd==rs1 (via ADD)"
str_op_alias_rd_rs2:   .asciz "OP rd==rs2 (via ADD)"
str_op_alias_rs1_rs2:  .asciz "OP rs1==rs2, rd distinct (via ADD)"

str_add_wrap:    .asciz "ADD wrap: all-ones + 1 = 0"
str_add_walking: .asciz "ADD two walking patterns"
str_add_zero:    .asciz "ADD 0 + 0 = 0"
str_add_rs1_preserved: .asciz "ADD rs1 unmodified"
str_add_rs2_preserved: .asciz "ADD rs2 unmodified"

str_sub_wrap:    .asciz "SUB 0 - 1 wraps to all-ones"
    .if XLEN == 64
str_sub_minwrap: .asciz "SUB INT64_MIN - 1 wraps to INT64_MAX"
    .else
str_sub_minwrap: .asciz "SUB INT32_MIN - 1 wraps to INT32_MAX"
    .endif
str_sub_zero:    .asciz "SUB 0 - 0 = 0"
str_sub_equal:   .asciz "SUB equal operands = 0"
str_sub_rs1_preserved: .asciz "SUB rs1 unmodified"
str_sub_rs2_preserved: .asciz "SUB rs2 unmodified"

str_sll_sh0:  .asciz "SLL shamt=0"
str_sll_sh1:  .asciz "SLL shamt=1"
str_sll_sh32: .asciz "SLL shamt=32"
str_sll_sh63: .asciz "SLL shamt=63 (max)"
str_sll_sh64_masks_to_0: .asciz "SLL rs2=64 masks to shamt=0"
str_sll_sh65_masks_to_1: .asciz "SLL rs2=65 masks to shamt=1"
str_sll_truncates: .asciz "SLL truncates, does not rotate"
    .if XLEN == 32
str_sll_sh16: .asciz "SLL shamt=16"
str_sll_sh31: .asciz "SLL shamt=31 (max)"
str_sll_sh32_masks_to_0: .asciz "SLL rs2=32 masks to shamt=0 (RV32: rs2[4:0])"
str_sll_sh33_masks_to_1: .asciz "SLL rs2=33 masks to shamt=1 (RV32: rs2[4:0])"
str_srl_sh16: .asciz "SRL shamt=16"
str_srl_sh31: .asciz "SRL shamt=31 (max)"
str_srl_sh32_masks_to_0: .asciz "SRL rs2=32 masks to shamt=0 (RV32: rs2[4:0])"
str_srl_sh33_masks_to_1: .asciz "SRL rs2=33 masks to shamt=1 (RV32: rs2[4:0])"
str_sra_sh16: .asciz "SRA shamt=16"
str_sra_sh31: .asciz "SRA shamt=31 (max, all sign-fill)"
str_sra_sh32_masks_to_0: .asciz "SRA rs2=32 masks to shamt=0 (RV32: rs2[4:0])"
str_sra_sh33_masks_to_1: .asciz "SRA rs2=33 masks to shamt=1 (RV32: rs2[4:0])"
    .endif
str_sll_rs1_preserved: .asciz "SLL rs1 unmodified"
str_sll_rs2_preserved: .asciz "SLL rs2 unmodified"

str_srl_sh0:  .asciz "SRL shamt=0"
str_srl_sh1:  .asciz "SRL shamt=1"
str_srl_sh32: .asciz "SRL shamt=32"
str_srl_sh63: .asciz "SRL shamt=63 (max)"
str_srl_sh64_masks_to_0: .asciz "SRL rs2=64 masks to shamt=0"
str_srl_sh65_masks_to_1: .asciz "SRL rs2=65 masks to shamt=1"
str_srl_rs1_preserved: .asciz "SRL rs1 unmodified"
str_srl_rs2_preserved: .asciz "SRL rs2 unmodified"

str_sra_sh0:  .asciz "SRA shamt=0"
str_sra_sh1:  .asciz "SRA shamt=1"
str_sra_sh32: .asciz "SRA shamt=32"
str_sra_sh63: .asciz "SRA shamt=63 (max, all sign-fill)"
str_sra_sh64_masks_to_0: .asciz "SRA rs2=64 masks to shamt=0"
str_sra_sh65_masks_to_1: .asciz "SRA rs2=65 masks to shamt=1"
str_sra_positive_no_signext: .asciz "SRA positive input needs no sign-extension"
str_sra_rs1_preserved: .asciz "SRA rs1 unmodified"
str_sra_rs2_preserved: .asciz "SRA rs2 unmodified"

str_xor_walking: .asciz "XOR two walking patterns"
str_xor_self_via_equal_values: .asciz "XOR equal operands = 0"
str_xor_identity: .asciz "XOR identity (x ^ 0 = x)"
str_xor_rs1_preserved: .asciz "XOR rs1 unmodified"
str_xor_rs2_preserved: .asciz "XOR rs2 unmodified"

str_or_walking:    .asciz "OR two walking patterns"
str_or_absorption: .asciz "OR absorption (x | allones = allones)"
str_or_identity:   .asciz "OR identity (x | 0 = x)"
str_or_rs1_preserved: .asciz "OR rs1 unmodified"
str_or_rs2_preserved: .asciz "OR rs2 unmodified"

str_and_walking:    .asciz "AND two walking patterns"
str_and_absorption: .asciz "AND absorption (x & 0 = 0)"
str_and_identity:   .asciz "AND identity (x & allones = x)"
str_and_rs1_preserved: .asciz "AND rs1 unmodified"
str_and_rs2_preserved: .asciz "AND rs2 unmodified"

str_slt_eq:  .asciz "SLT 0,0 = 0"
str_sltu_eq: .asciz "SLTU 0,0 = 0"
str_slt_1_2:  .asciz "SLT 1,2 = 1"
str_sltu_1_2: .asciz "SLTU 1,2 = 1"
str_slt_2_1:  .asciz "SLT 2,1 = 0"
str_sltu_2_1: .asciz "SLTU 2,1 = 0"
str_slt_m1_1:  .asciz "SLT -1,1 = 1 (signed: -1 < 1)"
str_sltu_m1_1_diverges: .asciz "SLTU -1,1 = 0 (unsigned: 0xff..ff > 1) DIVERGES from SLT"
str_slt_1_m1:  .asciz "SLT 1,-1 = 0 (signed)"
str_sltu_1_m1_diverges: .asciz "SLTU 1,-1 = 1 (unsigned) DIVERGES from SLT"
str_slt_m1_0:  .asciz "SLT -1,0 = 1 (signed)"
str_sltu_m1_0_diverges: .asciz "SLTU -1,0 = 0 (unsigned) DIVERGES from SLT"
    .if XLEN == 64
str_slt_minmax:  .asciz "SLT INT64_MIN,INT64_MAX = 1 (signed)"
str_sltu_minmax_diverges: .asciz "SLTU INT64_MIN,INT64_MAX = 0 (unsigned) DIVERGES from SLT"
str_slt_maxmin:  .asciz "SLT INT64_MAX,INT64_MIN = 0 (signed)"
str_sltu_maxmin_diverges: .asciz "SLTU INT64_MAX,INT64_MIN = 1 (unsigned) DIVERGES from SLT"
    .else
str_slt_minmax:  .asciz "SLT INT32_MIN,INT32_MAX = 1 (signed)"
str_sltu_minmax_diverges: .asciz "SLTU INT32_MIN,INT32_MAX = 0 (unsigned) DIVERGES from SLT"
str_slt_maxmin:  .asciz "SLT INT32_MAX,INT32_MIN = 0 (signed)"
str_sltu_maxmin_diverges: .asciz "SLTU INT32_MAX,INT32_MIN = 1 (unsigned) DIVERGES from SLT"
    .endif
str_slt_rs1_preserved: .asciz "SLT rs1 unmodified"
str_slt_rs2_preserved: .asciz "SLT rs2 unmodified"
