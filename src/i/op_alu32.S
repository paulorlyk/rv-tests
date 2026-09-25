/* =====================================================================
 * i/op_alu32.S  --  RV64I base-ISA OP-32 (R-type, word-width) ALU
 *                       instructions: ADDW, SUBW, SLLW, SRLW, SRAW
 *
 * Part of the RV64I base-ISA suite; see i/tests.S for how this
 * plugs into the rest (main_tests.S -> i/tests.S -> here), and
 * common.S for the boot/UART/reporting harness everything sits on
 * ("check", "uart_puts" are used from there; nothing else).
 *
 * RV64-only: OP-32 doesn't exist on RV32 (its opcode is reserved
 * there), so on the RV32 image tests_i_op_alu32 is an empty stub
 * and everything else in this file is assembled out.
 *
 * The word-width twins of i/op_alu.S's ADD/SUB/SLL/SRL/SRA, and the
 * register-register twins of i/op_imm32.S. The defining rule for
 * all five: the operation uses only the low 32 bits of rs1 (and of rs2
 * for ADDW/SUBW, rs2[4:0] for the shifts), and the 32-bit result is
 * *sign-extended* from bit 31 into bits 63:32. Each value test is
 * chosen so the 64-bit twin would give a different answer:
 *
 *   - rs1[63:32] and rs2[63:32] are ignored: sources carry garbage in
 *     the upper word (with and without bit 63 set).
 *   - The result is sign-extended from bit 31, never zero-extended and
 *     never taken from a 64-bit computation: ADDW/SUBW wrap at 32 bits
 *     (INT32_MAX + 1, INT32_MIN - 1, 0 - INT32_MIN, 0xffffffff + 1 = 0
 *     with no carry into bit 32).
 *   - SLLW/SRLW/SRAW: only rs2[4:0] is the shift amount -- rs2[5] too
 *     is ignored, unlike SLL/SRL/SRA -- so rs2=32 must behave like 0
 *     and rs2=33 like 1, and an rs2 with garbage above bit 4 must
 *     still shift by its low five bits. SLLW drops bits shifted past
 *     bit 31; SRLW zero-fills from bit 31 downward; SRAW fills with
 *     bit 31, not bit 63 (checked with bit 31 set/bit 63 clear and the
 *     other way round). The same inputs go through SRLW and SRAW, so a
 *     misdecoded funct7 bit shows up as a mismatch. Even a shift by 0
 *     must replace the upper word with copies of bit 31.
 *   - rd/rs1/rs2 and every aliasing combination are swept through ADDW.
 *     OP-32 is its own major opcode, so its register decode gets its
 *     own sweep rather than borrowing OP's.
 *
 * .option norvc is load-bearing: ADDW and SUBW have compressed forms
 * (c.addw, c.subw) the assembler would otherwise substitute for
 * x8-x15 operands with rd == rs1.
 *
 * Bit independence across fields (bitx_i_op_alu32, at the end): every
 * bit pair of rd/rs1/rs2, C(15,2) = 105 cases per instruction, with
 * the shared BX_C_RRR case macro -- no immediate, so the reference is
 * the same instruction in the t2/t3/t4 encoding that the T_OPW_VAL
 * tests below pin down against literals. See bitx.inc.
 * ===================================================================== */

    .include "xlen.inc"
    .include "harness.inc"

    .option norvc            /* mandatory, not stylistic: see above
                               * (ADDW -> c.addw, SUBW -> c.subw) */

    .include "bitx.inc"

    .global tests_i_op_alu32

    .section .text

    .if XLEN == 64

/* =======================================================================
 *  Shared macros
 * ======================================================================= */

/* T_OPW_RD/RS1/RS2 insn, reg, v1, v2, expect, name -- sweep one
 * register field at a time (through ADDW), the other two fixed at
 * registers outside the swept list (rd=t2, rs1=t3, rs2=t4). reg may be
 * a0/a1/a2 -- result captured to t2 before those are reused. */
.macro T_OPW_RD insn, rdreg, v1, v2, expect, name
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

.macro T_OPW_RS1 insn, rs1reg, v1, v2, expect, name
    TEST_BEGIN \name
    LIX     \rs1reg, \v1
    LIX     t4, \v2
    \insn   t2, \rs1reg, t4
    la      a0, \name
    LIX     a1, \expect
    mv      a2, t2
    call    check
.endm

.macro T_OPW_RS2 insn, rs2reg, v1, v2, expect, name
    TEST_BEGIN \name
    LIX     t3, \v1
    LIX     \rs2reg, \v2
    \insn   t2, t3, \rs2reg
    la      a0, \name
    LIX     a1, \expect
    mv      a2, t2
    call    check
.endm

/* T_OPW_VAL insn, v1, v2, expect, name -- fixed rd=t2/rs1=t3/rs2=t4,
 * sweep the operand values. */
.macro T_OPW_VAL insn, v1, v2, expect, name
    TEST_BEGIN \name
    LIX     t3, \v1
    LIX     t4, \v2
    \insn   t2, t3, t4
    la      a0, \name
    LIX     a1, \expect
    mv      a2, t2
    call    check
.endm

/* T_OPW_PRESERVED insn, v2, name1, name2 -- the instruction must not
 * write back to either source register (all 64 bits of each). */
.macro T_OPW_PRESERVED insn, v2, name1, name2
    TEST_BEGIN \name1
    LIX     t3, 0x123456789abcdef0
    LIX     t4, \v2
    mv      t5, t3
    mv      t6, t4
    \insn   t2, t3, t4
    la      a0, \name1
    mv      a1, t5
    mv      a2, t3
    call    check
    TEST_BEGIN \name2
    la      a0, \name2
    mv      a1, t6
    mv      a2, t4
    call    check
.endm

tests_i_op_alu32:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    /* ===== register sweep (through ADDW). Upper garbage in both
     * sources, so a swept register that skips the W semantics also
     * fails. ===== */
    T_OPW_RD addw, ra,  0xdead000000000064, 0xbeef000000000017, 123, str_opw_rd_ra
    T_OPW_RD addw, t0,  0xdead000000000064, 0xbeef000000000017, 123, str_opw_rd_t0
    T_OPW_RD addw, s0,  0xdead000000000064, 0xbeef000000000017, 123, str_opw_rd_s0
    T_OPW_RD addw, a0,  0xdead000000000064, 0xbeef000000000017, 123, str_opw_rd_a0
    T_OPW_RD addw, s10, 0xdead000000000064, 0xbeef000000000017, 123, str_opw_rd_s10
    T_OPW_RD addw, t6,  0xdead000000000064, 0xbeef000000000017, 123, str_opw_rd_t6

    T_OPW_RS1 addw, ra,  0xdead000000000064, 0xbeef000000000017, 123, str_opw_rs1_ra
    T_OPW_RS1 addw, t0,  0xdead000000000064, 0xbeef000000000017, 123, str_opw_rs1_t0
    T_OPW_RS1 addw, s0,  0xdead000000000064, 0xbeef000000000017, 123, str_opw_rs1_s0
    T_OPW_RS1 addw, a0,  0xdead000000000064, 0xbeef000000000017, 123, str_opw_rs1_a0
    T_OPW_RS1 addw, s10, 0xdead000000000064, 0xbeef000000000017, 123, str_opw_rs1_s10
    T_OPW_RS1 addw, t6,  0xdead000000000064, 0xbeef000000000017, 123, str_opw_rs1_t6

    T_OPW_RS2 addw, ra,  0xdead000000000064, 0xbeef000000000017, 123, str_opw_rs2_ra
    T_OPW_RS2 addw, t0,  0xdead000000000064, 0xbeef000000000017, 123, str_opw_rs2_t0
    T_OPW_RS2 addw, s0,  0xdead000000000064, 0xbeef000000000017, 123, str_opw_rs2_s0
    T_OPW_RS2 addw, a0,  0xdead000000000064, 0xbeef000000000017, 123, str_opw_rs2_a0
    T_OPW_RS2 addw, s10, 0xdead000000000064, 0xbeef000000000017, 123, str_opw_rs2_s10
    T_OPW_RS2 addw, t6,  0xdead000000000064, 0xbeef000000000017, 123, str_opw_rs2_t6

    /* rs1=x0 / rs2=x0 / rd=x0 */
    TEST_BEGIN str_opw_rs1_x0
    LIX     t4, 0x00000000ffffffff
    addw    t2, x0, t4
    la      a0, str_opw_rs1_x0
    LIX     a1, 0xffffffffffffffff
    mv      a2, t2
    call    check
    TEST_BEGIN str_opw_rs2_x0
    LIX     t3, 0xdeadbeef80000000
    addw    t2, t3, x0
    la      a0, str_opw_rs2_x0
    LIX     a1, 0xffffffff80000000
    mv      a2, t2
    call    check
    TEST_BEGIN str_opw_rd_x0
    LIX     t3, 100
    LIX     t4, 23
    addw    x0, t3, t4
    la      a0, str_opw_rd_x0
    LIX     a1, 0
    mv      a2, x0
    call    check

    TEST_BEGIN str_opw_alias_all_same
    /* ===== aliasing (through ADDW): every register-overlap
     * combination, each crossing the 32-bit overflow so the sign
     * extension is visible too ===== */
    LIX     t1, 0x0000000040000000
    addw    t1, t1, t1              /* rd==rs1==rs2: double itself */
    la      a0, str_opw_alias_all_same
    LIX     a1, 0xffffffff80000000
    mv      a2, t1
    call    check

    TEST_BEGIN str_opw_alias_rd_rs1
    LIX     t1, 0x000000007fffffff
    LIX     t2, 1
    addw    t1, t1, t2              /* rd==rs1 */
    la      a0, str_opw_alias_rd_rs1
    LIX     a1, 0xffffffff80000000
    mv      a2, t1
    call    check

    TEST_BEGIN str_opw_alias_rd_rs2
    LIX     t1, 0x000000007fffffff
    LIX     t2, 1
    addw    t2, t1, t2              /* rd==rs2 */
    la      a0, str_opw_alias_rd_rs2
    LIX     a1, 0xffffffff80000000
    mv      a2, t2
    call    check

    TEST_BEGIN str_opw_alias_rs1_rs2
    LIX     t1, 0x0000000040000000
    addw    t2, t1, t1              /* rs1==rs2, rd distinct */
    la      a0, str_opw_alias_rs1_rs2
    LIX     a1, 0xffffffff80000000
    mv      a2, t2
    call    check

    /* ===== ADDW ===== */
    T_OPW_VAL addw, 0, 0, 0, str_addw_zero
    T_OPW_VAL addw, 0x000000007fffffff, 1, 0xffffffff80000000, str_addw_int32_max_plus1
    T_OPW_VAL addw, 0x00000000ffffffff, 1, 0x0000000000000000, str_addw_no_carry_32
    T_OPW_VAL addw, 0x0000000080000000, 0x0000000080000000, 0x0000000000000000, str_addw_carry_out_dropped
    T_OPW_VAL addw, 0xffffffff80000000, 0xffffffffffffffff, 0x000000007fffffff, str_addw_int32_min_minus1
    T_OPW_VAL addw, 0xdeadbeef00000005, 0x1234567800000003, 0x0000000000000008, str_addw_upper_ignored
    T_OPW_VAL addw, 0x1111111170000000, 0x2222222210000000, 0xffffffff80000000, str_addw_signext
    T_OPW_VAL addw, 0x0000000000000005, 0x00000000fffffff6, 0xfffffffffffffffb, str_addw_neg_result
    T_OPW_PRESERVED addw, 0xfedcba9876543210, str_addw_rs1_preserved, str_addw_rs2_preserved

    /* ===== SUBW ===== */
    T_OPW_VAL subw, 0, 0, 0, str_subw_zero
    T_OPW_VAL subw, 100, 100, 0, str_subw_equal
    T_OPW_VAL subw, 0, 1, 0xffffffffffffffff, str_subw_wrap
    T_OPW_VAL subw, 0xffffffff80000000, 1, 0x000000007fffffff, str_subw_int32_min_minus1
    T_OPW_VAL subw, 0x000000007fffffff, 0xffffffffffffffff, 0xffffffff80000000, str_subw_int32_max_minus_m1
    T_OPW_VAL subw, 0, 0x0000000080000000, 0xffffffff80000000, str_subw_neg_int32_min
    T_OPW_VAL subw, 0x0000000100000000, 1, 0xffffffffffffffff, str_subw_no_borrow_32
    T_OPW_VAL subw, 0xdeadbeef0000000a, 0x1234567800000003, 0x0000000000000007, str_subw_upper_ignored
    T_OPW_VAL subw, 0x0000000000000003, 0x0000000000000005, 0xfffffffffffffffe, str_subw_neg_result
    T_OPW_PRESERVED subw, 0xfedcba9876543210, str_subw_rs1_preserved, str_subw_rs2_preserved

    /* ===== SLLW: only rs2[4:0] selects the shift amount ===== */
    T_OPW_VAL sllw, 0x0000000000000001, 0,  0x0000000000000001, str_sllw_sh0
    T_OPW_VAL sllw, 0x0000000000000001, 1,  0x0000000000000002, str_sllw_sh1
    T_OPW_VAL sllw, 0x0000000000000001, 16, 0x0000000000010000, str_sllw_sh16
    T_OPW_VAL sllw, 0x0000000000000001, 31, 0xffffffff80000000, str_sllw_sh31
    T_OPW_VAL sllw, 0x0000000087654321, 32, 0xffffffff87654321, str_sllw_sh32_masks_to_0
    T_OPW_VAL sllw, 0x0000000000000001, 33, 0x0000000000000002, str_sllw_sh33_masks_to_1
    T_OPW_VAL sllw, 0x0000000000000001, 0xffffffffffffffe4, 0x0000000000000010, str_sllw_rs2_upper_ignored
    T_OPW_VAL sllw, 0x0000000040000000, 1,  0xffffffff80000000, str_sllw_into_bit31
    T_OPW_VAL sllw, 0x0000000080000001, 1,  0x0000000000000002, str_sllw_drops_bit31
    T_OPW_VAL sllw, 0x00000000ffffffff, 1,  0xfffffffffffffffe, str_sllw_no_carry_32
    T_OPW_VAL sllw, 0xffffffffffffffff, 16, 0xffffffffffff0000, str_sllw_allones_sh16
    T_OPW_VAL sllw, 0xdeadbeef00000001, 4,  0x0000000000000010, str_sllw_rs1_upper_ignored
    T_OPW_VAL sllw, 0xdeadbeef12345678, 0,  0x0000000012345678, str_sllw_sh0_upper_cleared
    T_OPW_PRESERVED sllw, 0xdeadbeef00000004, str_sllw_rs1_preserved, str_sllw_rs2_preserved

    /* ===== SRLW / SRAW: same inputs through both. Source bit 31 set,
     *     bit 63 clear: the fill must come from bit 31. ===== */
    T_OPW_VAL srlw, 0x0000000080000000, 0,  0xffffffff80000000, str_srlw_sh0
    T_OPW_VAL sraw, 0x0000000080000000, 0,  0xffffffff80000000, str_sraw_sh0
    T_OPW_VAL srlw, 0x0000000080000000, 1,  0x0000000040000000, str_srlw_sh1
    T_OPW_VAL sraw, 0x0000000080000000, 1,  0xffffffffc0000000, str_sraw_sh1
    T_OPW_VAL srlw, 0x0000000080000000, 16, 0x0000000000008000, str_srlw_sh16
    T_OPW_VAL sraw, 0x0000000080000000, 16, 0xffffffffffff8000, str_sraw_sh16
    T_OPW_VAL srlw, 0x0000000080000000, 31, 0x0000000000000001, str_srlw_sh31
    T_OPW_VAL sraw, 0x0000000080000000, 31, 0xffffffffffffffff, str_sraw_sh31
    T_OPW_VAL srlw, 0x0000000080000000, 32, 0xffffffff80000000, str_srlw_sh32_masks_to_0
    T_OPW_VAL sraw, 0x0000000080000000, 32, 0xffffffff80000000, str_sraw_sh32_masks_to_0
    T_OPW_VAL srlw, 0x0000000080000000, 33, 0x0000000040000000, str_srlw_sh33_masks_to_1
    T_OPW_VAL sraw, 0x0000000080000000, 33, 0xffffffffc0000000, str_sraw_sh33_masks_to_1
    T_OPW_VAL srlw, 0x0000000080000000, 0x8000000000000024, 0x0000000008000000, str_srlw_rs2_upper_ignored
    T_OPW_VAL sraw, 0x0000000080000000, 0x8000000000000024, 0xfffffffff8000000, str_sraw_rs2_upper_ignored
    /* bit 63 set, bit 31 clear: the fill must still come from bit 31 */
    T_OPW_VAL srlw, 0xffffffff7fffffff, 4,  0x0000000007ffffff, str_srlw_bit63_ignored
    T_OPW_VAL sraw, 0xffffffff7fffffff, 4,  0x0000000007ffffff, str_sraw_bit63_ignored
    /* only the upper word set: nothing may shift down out of it */
    T_OPW_VAL srlw, 0xffffffff00000000, 1,  0x0000000000000000, str_srlw_upper_not_shifted_in
    T_OPW_VAL sraw, 0xffffffff00000000, 1,  0x0000000000000000, str_sraw_upper_not_shifted_in
    T_OPW_VAL srlw, 0xfffffffffffffffd, 1,  0x000000007ffffffe, str_srlw_m3
    T_OPW_VAL sraw, 0xfffffffffffffffd, 1,  0xfffffffffffffffe, str_sraw_rounds_toward_neg_inf
    T_OPW_PRESERVED srlw, 0xdeadbeef00000004, str_srlw_rs1_preserved, str_srlw_rs2_preserved
    T_OPW_PRESERVED sraw, 0xdeadbeef00000004, str_sraw_rs1_preserved, str_sraw_rs2_preserved

    jal     ra, bitx_i_op_alu32

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* Bit independence across fields -- see the file header and bitx.inc. */
bitx_i_op_alu32:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    /* upper-word garbage in both; low words that overflow bit 31 when
     * added and borrow when subtracted either way round */
    BX_POOL 0x123456787ffffa5c, 0xfedcba98000009c7
    BX_E_RRR5 BX_C_RRR, "addw, ADDW"
    BX_E_RRR5 BX_C_RRR, "subw, SUBW"
    /* rs1: bit 31 set, bit 63 clear. rs2: shamt 11 in bits 4:0, bit 5
     * set (a shift that honours rs2[5] shifts by 43), garbage above. */
    BX_POOL 0x0123456fc3a5695a, 0xdeadbeef0000002b
    BX_E_RRR5 BX_C_RRR, "sllw, SLLW"
    BX_E_RRR5 BX_C_RRR, "srlw, SRLW"
    BX_E_RRR5 BX_C_RRR, "sraw, SRAW"

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

    .else   /* XLEN == 32: OP-32 doesn't exist */

tests_i_op_alu32:
    ret

    .endif

    .if XLEN == 64
    .section .rodata
str_opw_rd_ra:   .asciz "ADDW rd=ra(x1) (OP-32 format)"
str_opw_rd_t0:   .asciz "ADDW rd=t0(x5) (OP-32 format)"
str_opw_rd_s0:   .asciz "ADDW rd=s0(x8) (OP-32 format)"
str_opw_rd_a0:   .asciz "ADDW rd=a0(x10) (OP-32 format)"
str_opw_rd_s10:  .asciz "ADDW rd=s10(x26) (OP-32 format)"
str_opw_rd_t6:   .asciz "ADDW rd=t6(x31) (OP-32 format)"
str_opw_rs1_ra:  .asciz "ADDW rs1=ra(x1) (OP-32 format)"
str_opw_rs1_t0:  .asciz "ADDW rs1=t0(x5) (OP-32 format)"
str_opw_rs1_s0:  .asciz "ADDW rs1=s0(x8) (OP-32 format)"
str_opw_rs1_a0:  .asciz "ADDW rs1=a0(x10) (OP-32 format)"
str_opw_rs1_s10: .asciz "ADDW rs1=s10(x26) (OP-32 format)"
str_opw_rs1_t6:  .asciz "ADDW rs1=t6(x31) (OP-32 format)"
str_opw_rs2_ra:  .asciz "ADDW rs2=ra(x1) (OP-32 format)"
str_opw_rs2_t0:  .asciz "ADDW rs2=t0(x5) (OP-32 format)"
str_opw_rs2_s0:  .asciz "ADDW rs2=s0(x8) (OP-32 format)"
str_opw_rs2_a0:  .asciz "ADDW rs2=a0(x10) (OP-32 format)"
str_opw_rs2_s10: .asciz "ADDW rs2=s10(x26) (OP-32 format)"
str_opw_rs2_t6:  .asciz "ADDW rs2=t6(x31) (OP-32 format)"
str_opw_rs1_x0:  .asciz "ADDW rs1=x0 (OP-32 format, 0 + 0xffffffff = -1)"
str_opw_rs2_x0:  .asciz "ADDW rs2=x0 (OP-32 format, SEXT.W of rs1)"
str_opw_rd_x0:   .asciz "ADDW rd=x0 discards result (OP-32 format)"
str_opw_alias_all_same: .asciz "ADDW rd==rs1==rs2 (OP-32 format)"
str_opw_alias_rd_rs1:   .asciz "ADDW rd==rs1 (OP-32 format)"
str_opw_alias_rd_rs2:   .asciz "ADDW rd==rs2 (OP-32 format)"
str_opw_alias_rs1_rs2:  .asciz "ADDW rs1==rs2, rd distinct (OP-32 format)"

str_addw_zero:              .asciz "ADDW 0 + 0 = 0"
str_addw_int32_max_plus1:   .asciz "ADDW INT32_MAX + 1 wraps to INT32_MIN, sign-extended"
str_addw_no_carry_32:       .asciz "ADDW 0xffffffff + 1 = 0 (no carry into bit 32)"
str_addw_carry_out_dropped: .asciz "ADDW 2^31 + 2^31 = 0 (carry out of bit 31 dropped)"
str_addw_int32_min_minus1:  .asciz "ADDW INT32_MIN + -1 wraps to INT32_MAX"
str_addw_upper_ignored:     .asciz "ADDW ignores rs1[63:32] and rs2[63:32]"
str_addw_signext:           .asciz "ADDW result bit 31 set -> upper word all ones"
str_addw_neg_result:        .asciz "ADDW 5 + 0xfffffff6 = -5 (sign-extended)"
str_addw_rs1_preserved:     .asciz "ADDW rs1 unmodified"
str_addw_rs2_preserved:     .asciz "ADDW rs2 unmodified"

str_subw_zero:               .asciz "SUBW 0 - 0 = 0"
str_subw_equal:              .asciz "SUBW 100 - 100 = 0"
str_subw_wrap:               .asciz "SUBW 0 - 1 = -1"
str_subw_int32_min_minus1:   .asciz "SUBW INT32_MIN - 1 wraps to INT32_MAX"
str_subw_int32_max_minus_m1: .asciz "SUBW INT32_MAX - -1 wraps to INT32_MIN, sign-extended"
str_subw_neg_int32_min:      .asciz "SUBW 0 - INT32_MIN = INT32_MIN"
str_subw_no_borrow_32:       .asciz "SUBW 2^32 - 1 = -1 (upper word ignored)"
str_subw_upper_ignored:      .asciz "SUBW ignores rs1[63:32] and rs2[63:32]"
str_subw_neg_result:         .asciz "SUBW 3 - 5 = -2 (sign-extended)"
str_subw_rs1_preserved:      .asciz "SUBW rs1 unmodified"
str_subw_rs2_preserved:      .asciz "SUBW rs2 unmodified"

str_sllw_sh0:  .asciz "SLLW shamt=0"
str_sllw_sh1:  .asciz "SLLW shamt=1"
str_sllw_sh16: .asciz "SLLW shamt=16"
str_sllw_sh31: .asciz "SLLW shamt=31 (max, result sign-extended)"
str_sllw_sh32_masks_to_0:   .asciz "SLLW rs2=32 masks to shamt=0 (rs2[4:0] only)"
str_sllw_sh33_masks_to_1:   .asciz "SLLW rs2=33 masks to shamt=1 (rs2[4:0] only)"
str_sllw_rs2_upper_ignored: .asciz "SLLW rs2=0xff..e4 shifts by 4"
str_sllw_into_bit31:        .asciz "SLLW shifting into bit 31 sign-extends"
str_sllw_drops_bit31:       .asciz "SLLW bit 31 shifted out, not into bit 32"
str_sllw_no_carry_32:       .asciz "SLLW 0xffffffff<<1 = -2 (not 0x1fffffffe)"
str_sllw_allones_sh16:      .asciz "SLLW all-ones by 16"
str_sllw_rs1_upper_ignored: .asciz "SLLW ignores rs1[63:32]"
str_sllw_sh0_upper_cleared: .asciz "SLLW shamt=0 still replaces the upper word"
str_sllw_rs1_preserved:     .asciz "SLLW rs1 unmodified"
str_sllw_rs2_preserved:     .asciz "SLLW rs2 unmodified"

str_srlw_sh0:  .asciz "SRLW shamt=0 (result sign-extended)"
str_sraw_sh0:  .asciz "SRAW shamt=0 (result sign-extended)"
str_srlw_sh1:  .asciz "SRLW shamt=1 (zero-fill from bit 31)"
str_sraw_sh1:  .asciz "SRAW shamt=1 (fill from bit 31) DIVERGES from SRLW"
str_srlw_sh16: .asciz "SRLW shamt=16"
str_sraw_sh16: .asciz "SRAW shamt=16"
str_srlw_sh31: .asciz "SRLW shamt=31 (max)"
str_sraw_sh31: .asciz "SRAW shamt=31 (max, all sign-fill)"
str_srlw_sh32_masks_to_0: .asciz "SRLW rs2=32 masks to shamt=0 (rs2[4:0] only)"
str_sraw_sh32_masks_to_0: .asciz "SRAW rs2=32 masks to shamt=0 (rs2[4:0] only)"
str_srlw_sh33_masks_to_1: .asciz "SRLW rs2=33 masks to shamt=1 (rs2[4:0] only)"
str_sraw_sh33_masks_to_1: .asciz "SRAW rs2=33 masks to shamt=1 (rs2[4:0] only)"
str_srlw_rs2_upper_ignored: .asciz "SRLW rs2=0x80..24 shifts by 4"
str_sraw_rs2_upper_ignored: .asciz "SRAW rs2=0x80..24 shifts by 4"
str_srlw_bit63_ignored: .asciz "SRLW bit 63 set, bit 31 clear: positive result"
str_sraw_bit63_ignored: .asciz "SRAW fills from bit 31, not bit 63"
str_srlw_upper_not_shifted_in: .asciz "SRLW rs1[63:32] not shifted into the result"
str_sraw_upper_not_shifted_in: .asciz "SRAW rs1[63:32] not shifted into the result"
str_srlw_m3:                   .asciz "SRLW -3>>1 = 0x7ffffffe (zero-fill at bit 31)"
str_sraw_rounds_toward_neg_inf: .asciz "SRAW -3>>1 = -2 (rounds toward -inf)"
str_srlw_rs1_preserved: .asciz "SRLW rs1 unmodified"
str_srlw_rs2_preserved: .asciz "SRLW rs2 unmodified"
str_sraw_rs1_preserved: .asciz "SRAW rs1 unmodified"
str_sraw_rs2_preserved: .asciz "SRAW rs2 unmodified"
    .endif
