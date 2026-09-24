/* =====================================================================
 * m/div.S  --  RV64M divide/remainder instructions:
 *               DIV, DIVU, REM, REMU, DIVW, DIVUW, REMW, REMUW
 *
 * Part of the RV64M suite; see m/tests.S for how this plugs into the
 * rest (main_tests.S -> m/tests.S -> here), and common.S for the
 * boot/UART/reporting harness everything sits on ("check",
 * "uart_puts" are used from there; nothing else).
 *
 * The register fields share one R-type encoding with the multiplies
 * and were already swept through MUL in m/mul.S, so this file spends
 * its depth on the arithmetic, which is where division actually goes
 * wrong:
 *
 *   - Division never traps in RISC-V. The two special cases have fully
 *     specified results instead, and are tested for every variant:
 *       divide by zero:  quotient = all ones (-1 signed / 2^XLEN-1
 *                        unsigned), remainder = the dividend
 *       signed overflow: INT_MIN / -1 -> quotient = INT_MIN,
 *                        remainder = 0
 *     If either one traps, the trap handler in common.S reports it and
 *     hangs -- a clear failure, not a silent one.
 *   - Signed division truncates toward zero, and the remainder takes
 *     the sign of the dividend (not the divisor). All four sign
 *     combinations of +-20 / +-6 are tested for DIV/REM.
 *   - DIV/DIVU/REM/REMU run against the *same* operand pairs, so a
 *     signed/unsigned swap shows up as a visible mismatch (-20 / 6 is
 *     -3 signed but 0x2aaaaaaaaaaaaaa7 unsigned).
 *   - W variants: only the low 32 bits of each source are used, and the
 *     32-bit result is sign-extended to 64 -- *including* for the
 *     unsigned DIVUW/REMUW. Tested with garbage in the upper 32 bits,
 *     and with a divisor whose low 32 bits are zero but whose upper
 *     bits are not: that is a divide-by-zero for the W forms, and an
 *     implementation that looks at the full 64-bit divisor would miss
 *     it.
 *   - The spec's recommended fused sequence (DIV[U] rdq; REM[U] rdr
 *     with the same sources) is tested as a pair, plus the identity
 *     q*divisor + r == dividend that ties the two together.
 *   - rd aliasing a source is a real hazard for a multi-cycle divider
 *     (writing rd early would corrupt an operand still in use), so
 *     rd==rs1 and rd==rs2 get their own cases here.
 *
 * Bit independence across fields (bitx_m_div, at the end): every bit pair
 * of rd/rs1/rs2 set together, C(15,2) = 105 cases per instruction, for
 * all eight -- see bitx.inc. The expected value is the same instruction
 * run through the t2/t3/t4 encoding the T_M_VAL tests above already
 * pin down against literals.
 *
 * RV32 image (xlen.inc): DIVW/DIVUW/REMW/REMUW are RV64-only and left
 * out; the other tables use the INT32 counterparts of each operand pair.
 * ===================================================================== */

    .include "xlen.inc"
    .include "harness.inc"

    .option norvc            /* see m/mul.S */

    .include "bitx.inc"

    .global tests_m_div

    .section .text

/* T_M_VAL insn, v1, v2, expect, name -- fixed rd=t2/rs1=t3/rs2=t4,
 * sweep the operand values. */
.macro T_M_VAL insn, v1, v2, expect, name
    TEST_BEGIN \name
    LIX     t3, \v1
    LIX     t4, \v2
    \insn   t2, t3, t4
    la      a0, \name
    LIX     a1, \expect
    mv      a2, t2
    call    check
.endm

/* T_M_PRESERVED insn, name1, name2 -- the instruction must not write
 * back to either source register. */
.macro T_M_PRESERVED insn, name1, name2
    TEST_BEGIN \name1
    LIXT    t3, 0x123456789abcdef0
    LIXT    t4, 0x0fedcba987654321
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

tests_m_div:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    /* ===== DIV / DIVU / REM / REMU: same operand pairs through all four ===== */
    /* sign combinations: truncate toward zero, remainder follows dividend */
    T_M_VAL div,  20, 6, 0x0000000000000003, str_div_p20_p6
    T_M_VAL divu, 20, 6, 0x0000000000000003, str_divu_p20_p6
    T_M_VAL rem,  20, 6, 0x0000000000000002, str_rem_p20_p6
    T_M_VAL remu, 20, 6, 0x0000000000000002, str_remu_p20_p6

    .if XLEN == 64
    T_M_VAL div,  -20, 6, 0xfffffffffffffffd, str_div_m20_p6
    T_M_VAL divu, -20, 6, 0x2aaaaaaaaaaaaaa7, str_divu_m20_p6
    T_M_VAL rem,  -20, 6, 0xfffffffffffffffe, str_rem_m20_p6
    T_M_VAL remu, -20, 6, 0x0000000000000002, str_remu_m20_p6
    .else
    T_M_VAL div,    0xffffffec, 0x00000006, 0xfffffffd, str_div_m20_p6
    T_M_VAL divu,   0xffffffec, 0x00000006, 0x2aaaaaa7, str_divu_m20_p6
    T_M_VAL rem,    0xffffffec, 0x00000006, 0xfffffffe, str_rem_m20_p6
    T_M_VAL remu,   0xffffffec, 0x00000006, 0x00000002, str_remu_m20_p6
    .endif

    T_M_VAL div,  20, -6, 0xfffffffffffffffd, str_div_p20_m6
    T_M_VAL divu, 20, -6, 0x0000000000000000, str_divu_p20_m6
    T_M_VAL rem,  20, -6, 0x0000000000000002, str_rem_p20_m6
    T_M_VAL remu, 20, -6, 0x0000000000000014, str_remu_p20_m6

    T_M_VAL div,  -20, -6, 0x0000000000000003, str_div_m20_m6
    T_M_VAL divu, -20, -6, 0x0000000000000000, str_divu_m20_m6
    T_M_VAL rem,  -20, -6, 0xfffffffffffffffe, str_rem_m20_m6
    T_M_VAL remu, -20, -6, 0xffffffffffffffec, str_remu_m20_m6

    /* divide by zero: quotient all ones, remainder = dividend, no trap */
    T_M_VAL div,  7, 0, 0xffffffffffffffff, str_div_p7_by0
    T_M_VAL divu, 7, 0, 0xffffffffffffffff, str_divu_p7_by0
    T_M_VAL rem,  7, 0, 0x0000000000000007, str_rem_p7_by0
    T_M_VAL remu, 7, 0, 0x0000000000000007, str_remu_p7_by0

    T_M_VAL div,  -7, 0, 0xffffffffffffffff, str_div_m7_by0
    T_M_VAL divu, -7, 0, 0xffffffffffffffff, str_divu_m7_by0
    T_M_VAL rem,  -7, 0, 0xfffffffffffffff9, str_rem_m7_by0
    T_M_VAL remu, -7, 0, 0xfffffffffffffff9, str_remu_m7_by0

    T_M_VAL div,  0, 0, 0xffffffffffffffff, str_div_0_by0
    T_M_VAL rem,  0, 0, 0x0000000000000000, str_rem_0_by0

    /* signed overflow: INT64_MIN / -1 */
    .if XLEN == 64
    T_M_VAL div,  0x8000000000000000, -1, 0x8000000000000000, str_div_overflow
    T_M_VAL divu, 0x8000000000000000, -1, 0x0000000000000000, str_divu_overflow_pair
    T_M_VAL rem,  0x8000000000000000, -1, 0x0000000000000000, str_rem_overflow
    T_M_VAL remu, 0x8000000000000000, -1, 0x8000000000000000, str_remu_overflow_pair
    .else
    T_M_VAL div,    0x80000000, 0xffffffff, 0x80000000, str_div_overflow
    T_M_VAL divu,   0x80000000, 0xffffffff, 0x00000000, str_divu_overflow_pair
    T_M_VAL rem,    0x80000000, 0xffffffff, 0x00000000, str_rem_overflow
    T_M_VAL remu,   0x80000000, 0xffffffff, 0x80000000, str_remu_overflow_pair
    .endif

    .if XLEN == 64
    T_M_VAL div,  0x8000000000000000, 1, 0x8000000000000000, str_div_min_1
    T_M_VAL divu, 0x8000000000000000, 1, 0x8000000000000000, str_divu_min_1
    T_M_VAL rem,  0x8000000000000000, 1, 0x0000000000000000, str_rem_min_1
    T_M_VAL remu, 0x8000000000000000, 1, 0x0000000000000000, str_remu_min_1
    .else
    T_M_VAL div,    0x80000000, 0x00000001, 0x80000000, str_div_min_1
    T_M_VAL divu,   0x80000000, 0x00000001, 0x80000000, str_divu_min_1
    T_M_VAL rem,    0x80000000, 0x00000001, 0x00000000, str_rem_min_1
    T_M_VAL remu,   0x80000000, 0x00000001, 0x00000000, str_remu_min_1
    .endif

    .if XLEN == 64
    T_M_VAL div,  5, 0x8000000000000000, 0x0000000000000000, str_div_5_min
    T_M_VAL divu, 5, 0x8000000000000000, 0x0000000000000000, str_divu_5_min
    T_M_VAL rem,  5, 0x8000000000000000, 0x0000000000000005, str_rem_5_min
    T_M_VAL remu, 5, 0x8000000000000000, 0x0000000000000005, str_remu_5_min
    .else
    T_M_VAL div,    0x00000005, 0x80000000, 0x00000000, str_div_5_min
    T_M_VAL divu,   0x00000005, 0x80000000, 0x00000000, str_divu_5_min
    T_M_VAL rem,    0x00000005, 0x80000000, 0x00000005, str_rem_5_min
    T_M_VAL remu,   0x00000005, 0x80000000, 0x00000005, str_remu_5_min
    .endif

    .if XLEN == 64
    T_M_VAL div,  0x7fffffffffffffff, 2, 0x3fffffffffffffff, str_div_max_2
    T_M_VAL rem,  0x7fffffffffffffff, 2, 0x0000000000000001, str_rem_max_2
    T_M_VAL div,  3, 5, 0x0000000000000000, str_div_3_5
    T_M_VAL rem,  3, 5, 0x0000000000000003, str_rem_3_5
    T_M_VAL divu, 0xffffffffffffffff, 1, 0xffffffffffffffff, str_divu_max_1
    T_M_VAL remu, 0xffffffffffffffff, 1, 0x0000000000000000, str_remu_max_1
    T_M_VAL divu, 0xfedcba9876543210, 0x0000000012345678, 0x0000000e00000077, str_divu_walking
    T_M_VAL remu, 0xfedcba9876543210, 0x0000000012345678, 0x0000000000000048, str_remu_walking
    .else
    T_M_VAL div,    0x7fffffff, 0x00000002, 0x3fffffff, str_div_max_2
    T_M_VAL rem,    0x7fffffff, 0x00000002, 0x00000001, str_rem_max_2
    T_M_VAL div,    0x00000003, 0x00000005, 0x00000000, str_div_3_5
    T_M_VAL rem,    0x00000003, 0x00000005, 0x00000003, str_rem_3_5
    T_M_VAL divu,   0xffffffff, 0x00000001, 0xffffffff, str_divu_max_1
    T_M_VAL remu,   0xffffffff, 0x00000001, 0x00000000, str_remu_max_1
    T_M_VAL divu,   0xfedcba98, 0x12345678, 0x0000000e, str_divu_walking
    T_M_VAL remu,   0xfedcba98, 0x12345678, 0x00000008, str_remu_walking
    .endif

    T_M_PRESERVED div,  str_div_rs1_preserved,  str_div_rs2_preserved
    T_M_PRESERVED divu, str_divu_rs1_preserved, str_divu_rs2_preserved
    T_M_PRESERVED rem,  str_rem_rs1_preserved,  str_rem_rs2_preserved
    T_M_PRESERVED remu, str_remu_rs1_preserved, str_remu_rs2_preserved

    TEST_BEGIN str_div_alias_rd_rs1
    /* ===== aliasing: rd overwrites a source still needed by a
     *     multi-cycle divider ===== */
    LIX     t1, 100
    LIX     t2, 7
    div     t1, t1, t2              /* rd==rs1 */
    la      a0, str_div_alias_rd_rs1
    LIX     a1, 14
    mv      a2, t1
    call    check

    TEST_BEGIN str_div_alias_rd_rs2
    LIX     t1, 100
    LIX     t2, 7
    div     t2, t1, t2              /* rd==rs2 */
    la      a0, str_div_alias_rd_rs2
    LIX     a1, 14
    mv      a2, t2
    call    check

    TEST_BEGIN str_rem_alias_rd_rs2
    LIX     t1, 100
    LIX     t2, 7
    rem     t2, t1, t2              /* rd==rs2 */
    la      a0, str_rem_alias_rd_rs2
    LIX     a1, 2
    mv      a2, t2
    call    check

    TEST_BEGIN str_div_alias_all_same
    LIX     t1, -9
    div     t1, t1, t1              /* rd==rs1==rs2: x/x = 1 */
    la      a0, str_div_alias_all_same
    LIX     a1, 1
    mv      a2, t1
    call    check

    TEST_BEGIN str_remu_alias_all_same
    LIX     t1, -9
    remu    t1, t1, t1              /* rd==rs1==rs2: x%x = 0 */
    la      a0, str_remu_alias_all_same
    LIX     a1, 0
    mv      a2, t1
    call    check

    /* rd=x0 on a divide-by-zero: must not trap, result discarded */
    TEST_BEGIN str_div_rd_x0
    LIX     t3, 5
    div     x0, t3, x0
    la      a0, str_div_rd_x0
    LIX     a1, 0
    mv      a2, x0
    call    check

    TEST_BEGIN str_divrem_fused_q
    /* ===== recommended fused sequence DIV rdq; REM rdr, plus the
     *     identity q*divisor + r == dividend ===== */
    LIX     t3, -1000003
    LIX     t4, 97
    div     t1, t3, t4
    rem     t2, t3, t4
    mv      s0, t1                  /* check clobbers t0-t6 */
    mv      s1, t2
    la      a0, str_divrem_fused_q
    LIX     a1, -10309
    mv      a2, s0
    call    check
    TEST_BEGIN str_divrem_fused_r
    la      a0, str_divrem_fused_r
    LIX     a1, -30
    mv      a2, s1
    call    check
    TEST_BEGIN str_divrem_identity
    LIX     t4, 97
    mul     t1, s0, t4
    add     t1, t1, s1
    la      a0, str_divrem_identity
    LIX     a1, -1000003
    mv      a2, t1
    call    check

    TEST_BEGIN str_divremu_fused_q
    .if XLEN == 64
    LIX     t3, 0xfedcba9876543210
    .else
    LIX     t3, 0xfedcba98
    .endif
    LIX     t4, 0x0000000012345678
    divu    t1, t3, t4
    remu    t2, t3, t4
    mv      s0, t1
    mv      s1, t2
    la      a0, str_divremu_fused_q
    .if XLEN == 64
    LIX     a1, 0x0000000e00000077
    .else
    LIX     a1, 0x0000000e
    .endif
    mv      a2, s0
    call    check
    TEST_BEGIN str_divremu_fused_r
    la      a0, str_divremu_fused_r
    .if XLEN == 64
    LIX     a1, 0x0000000000000048
    .else
    LIX     a1, 0x00000008
    .endif
    mv      a2, s1
    call    check

    /* ===== DIVW / DIVUW / REMW / REMUW: low 32 bits only, 32-bit
     *     result sign-extended (even for the unsigned forms) ===== */
    .if XLEN == 64
    T_M_VAL divw,  0xdeadbeef00000014, 0x1234567800000006, 0x0000000000000003, str_divw_garbage_upper
    T_M_VAL divuw, 0xdeadbeef00000014, 0x1234567800000006, 0x0000000000000003, str_divuw_garbage_upper
    T_M_VAL remw,  0xdeadbeef00000014, 0x1234567800000006, 0x0000000000000002, str_remw_garbage_upper
    T_M_VAL remuw, 0xdeadbeef00000014, 0x1234567800000006, 0x0000000000000002, str_remuw_garbage_upper
    .endif

    /* -20 in the low word, once properly sign-extended and once
     * zero-extended: the W forms must not care which */
    .if XLEN == 64
    T_M_VAL divw,  0xffffffffffffffec, 6, 0xfffffffffffffffd, str_divw_m20_sext
    T_M_VAL divuw, 0xffffffffffffffec, 6, 0x000000002aaaaaa7, str_divuw_m20_sext
    T_M_VAL remw,  0xffffffffffffffec, 6, 0xfffffffffffffffe, str_remw_m20_sext
    T_M_VAL remuw, 0xffffffffffffffec, 6, 0x0000000000000002, str_remuw_m20_sext
    T_M_VAL divw,  0x00000000ffffffec, 6, 0xfffffffffffffffd, str_divw_m20_zext
    T_M_VAL divuw, 0x00000000ffffffec, 6, 0x000000002aaaaaa7, str_divuw_m20_zext
    T_M_VAL remw,  0x00000000ffffffec, 6, 0xfffffffffffffffe, str_remw_m20_zext
    T_M_VAL remuw, 0x00000000ffffffec, 6, 0x0000000000000002, str_remuw_m20_zext
    .endif

    /* signed overflow: INT32_MIN / -1 (divisor -1 as 64-bit and as
     * a zero-extended 32-bit value) */
    .if XLEN == 64
    T_M_VAL divw,  0x0000000080000000, 0xffffffffffffffff, 0xffffffff80000000, str_divw_overflow
    T_M_VAL divuw, 0x0000000080000000, 0xffffffffffffffff, 0x0000000000000000, str_divuw_overflow_pair
    T_M_VAL remw,  0x0000000080000000, 0xffffffffffffffff, 0x0000000000000000, str_remw_overflow
    T_M_VAL remuw, 0x0000000080000000, 0xffffffffffffffff, 0xffffffff80000000, str_remuw_overflow_pair
    T_M_VAL divw,  0x0000000080000000, 0x00000000ffffffff, 0xffffffff80000000, str_divw_overflow_zext_m1
    T_M_VAL remw,  0x0000000080000000, 0x00000000ffffffff, 0x0000000000000000, str_remw_overflow_zext_m1
    .endif

    /* divide by zero */
    .if XLEN == 64
    T_M_VAL divw,  7, 0, 0xffffffffffffffff, str_divw_by0
    T_M_VAL divuw, 7, 0, 0xffffffffffffffff, str_divuw_by0
    T_M_VAL remw,  7, 0, 0x0000000000000007, str_remw_by0
    T_M_VAL remuw, 7, 0, 0x0000000000000007, str_remuw_by0
    T_M_VAL remw,  0x00000000fffffff9, 0, 0xfffffffffffffff9, str_remw_by0_signext
    T_M_VAL remuw, 0x00000000fffffff9, 0, 0xfffffffffffffff9, str_remuw_by0_signext
    .endif

    /* divisor nonzero in 64 bits, but zero in its low 32 bits: still a
     * divide-by-zero for the W forms */
    .if XLEN == 64
    T_M_VAL divw,  7, 0xffffffff00000000, 0xffffffffffffffff, str_divw_by0_upper
    T_M_VAL divuw, 7, 0xffffffff00000000, 0xffffffffffffffff, str_divuw_by0_upper
    T_M_VAL remw,  0x00000000fffffff9, 0xffffffff00000000, 0xfffffffffffffff9, str_remw_by0_upper
    T_M_VAL remuw, 0x00000000fffffff9, 0xffffffff00000000, 0xfffffffffffffff9, str_remuw_by0_upper
    .endif

    /* unsigned forms still sign-extend their 32-bit result */
    .if XLEN == 64
    T_M_VAL divuw, 0x00000000ffffffff, 1, 0xffffffffffffffff, str_divuw_result_signext
    T_M_VAL divuw, 0x0000000080000000, 1, 0xffffffff80000000, str_divuw_result_signext_min
    T_M_VAL divw,  0xffffffff80000000, 2, 0xffffffffc0000000, str_divw_min32_2
    T_M_VAL divuw, 0xffffffff80000000, 2, 0x0000000040000000, str_divuw_min32_2
    .endif

    .if XLEN == 64
    T_M_PRESERVED divw,  str_divw_rs1_preserved,  str_divw_rs2_preserved
    T_M_PRESERVED divuw, str_divuw_rs1_preserved, str_divuw_rs2_preserved
    T_M_PRESERVED remw,  str_remw_rs1_preserved,  str_remw_rs2_preserved
    T_M_PRESERVED remuw, str_remuw_rs1_preserved, str_remuw_rs2_preserved
    .endif

    jal     ra, bitx_m_div

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* Bit independence across fields -- see the file header and bitx.inc. */
bitx_m_div:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    /* negative dividend, small positive divisor: a dense quotient and a
     * nonzero remainder; aliased rs1 == rs2 gives 1 / 0 instead */
    BX_POOL 0x8123456789abcdef, 0x000000000001234f
    BX_E_RRR5 BX_C_RRR, "div, DIV"
    BX_E_RRR5 BX_C_RRR, "divu, DIVU"
    BX_E_RRR5 BX_C_RRR, "rem, REM"
    BX_E_RRR5 BX_C_RRR, "remu, REMU"
    /* same idea for the W forms, with garbage above bit 31 */
    BX_POOL 0xdeadbeef87654321, 0x123456780001234f
    .if XLEN == 64
    BX_E_RRR5 BX_C_RRR, "divw, DIVW"
    BX_E_RRR5 BX_C_RRR, "divuw, DIVUW"
    BX_E_RRR5 BX_C_RRR, "remw, REMW"
    BX_E_RRR5 BX_C_RRR, "remuw, REMUW"
    .endif

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

    .section .rodata
str_div_p20_p6:  .asciz "DIV 20/6 = 3"
str_divu_p20_p6: .asciz "DIVU 20/6 = 3"
str_rem_p20_p6:  .asciz "REM 20%6 = 2"
str_remu_p20_p6: .asciz "REMU 20%6 = 2"
str_div_m20_p6:  .asciz "DIV -20/6 = -3 (truncates toward zero)"
str_divu_m20_p6: .asciz "DIVU 0xff..ec/6 DIVERGES from DIV"
str_rem_m20_p6:  .asciz "REM -20%6 = -2 (sign of dividend)"
str_remu_m20_p6: .asciz "REMU 0xff..ec%6 = 2"
str_div_p20_m6:  .asciz "DIV 20/-6 = -3"
str_divu_p20_m6: .asciz "DIVU 20/0xff..fa = 0 DIVERGES"
str_rem_p20_m6:  .asciz "REM 20%-6 = 2 (sign of dividend, not divisor)"
str_remu_p20_m6: .asciz "REMU 20%0xff..fa = 20"
str_div_m20_m6:  .asciz "DIV -20/-6 = 3"
str_divu_m20_m6: .asciz "DIVU 0xff..ec/0xff..fa = 0"
str_rem_m20_m6:  .asciz "REM -20%-6 = -2"
str_remu_m20_m6: .asciz "REMU 0xff..ec%0xff..fa = dividend"
str_div_p7_by0:  .asciz "DIV 7/0 = -1 (no trap)"
str_divu_p7_by0: .asciz "DIVU 7/0 = 0xff..ff (no trap)"
str_rem_p7_by0:  .asciz "REM 7%0 = 7 (no trap)"
str_remu_p7_by0: .asciz "REMU 7%0 = 7 (no trap)"
str_div_m7_by0:  .asciz "DIV -7/0 = -1"
str_divu_m7_by0: .asciz "DIVU 0xff..f9/0 = 0xff..ff"
str_rem_m7_by0:  .asciz "REM -7%0 = -7"
str_remu_m7_by0: .asciz "REMU 0xff..f9%0 = dividend"
str_div_0_by0:   .asciz "DIV 0/0 = -1"
str_rem_0_by0:   .asciz "REM 0%0 = 0"
    .if XLEN == 64
str_div_overflow:       .asciz "DIV INT64_MIN/-1 = INT64_MIN (overflow, no trap)"
    .else
str_div_overflow:       .asciz "DIV INT32_MIN/-1 = INT32_MIN (overflow, no trap)"
    .endif
    .if XLEN == 64
str_divu_overflow_pair: .asciz "DIVU 2^63/0xff..ff = 0"
    .else
str_divu_overflow_pair: .asciz "DIVU 2^31/0xff..ff = 0"
    .endif
    .if XLEN == 64
str_rem_overflow:       .asciz "REM INT64_MIN%-1 = 0 (overflow, no trap)"
    .else
str_rem_overflow:       .asciz "REM INT32_MIN%-1 = 0 (overflow, no trap)"
    .endif
    .if XLEN == 64
str_remu_overflow_pair: .asciz "REMU 2^63%0xff..ff = 2^63"
    .else
str_remu_overflow_pair: .asciz "REMU 2^31%0xff..ff = 2^31"
    .endif
    .if XLEN == 64
str_div_min_1:  .asciz "DIV INT64_MIN/1"
    .else
str_div_min_1:  .asciz "DIV INT32_MIN/1"
    .endif
    .if XLEN == 64
str_divu_min_1: .asciz "DIVU 2^63/1"
    .else
str_divu_min_1: .asciz "DIVU 2^31/1"
    .endif
    .if XLEN == 64
str_rem_min_1:  .asciz "REM INT64_MIN%1 = 0"
    .else
str_rem_min_1:  .asciz "REM INT32_MIN%1 = 0"
    .endif
    .if XLEN == 64
str_remu_min_1: .asciz "REMU 2^63%1 = 0"
    .else
str_remu_min_1: .asciz "REMU 2^31%1 = 0"
    .endif
    .if XLEN == 64
str_div_5_min:  .asciz "DIV 5/INT64_MIN = 0"
    .else
str_div_5_min:  .asciz "DIV 5/INT32_MIN = 0"
    .endif
    .if XLEN == 64
str_divu_5_min: .asciz "DIVU 5/2^63 = 0"
    .else
str_divu_5_min: .asciz "DIVU 5/2^31 = 0"
    .endif
    .if XLEN == 64
str_rem_5_min:  .asciz "REM 5%INT64_MIN = 5"
    .else
str_rem_5_min:  .asciz "REM 5%INT32_MIN = 5"
    .endif
    .if XLEN == 64
str_remu_5_min: .asciz "REMU 5%2^63 = 5"
    .else
str_remu_5_min: .asciz "REMU 5%2^31 = 5"
    .endif
    .if XLEN == 64
str_div_max_2:  .asciz "DIV INT64_MAX/2"
    .else
str_div_max_2:  .asciz "DIV INT32_MAX/2"
    .endif
    .if XLEN == 64
str_rem_max_2:  .asciz "REM INT64_MAX%2 = 1"
    .else
str_rem_max_2:  .asciz "REM INT32_MAX%2 = 1"
    .endif
str_div_3_5:    .asciz "DIV 3/5 = 0"
str_rem_3_5:    .asciz "REM 3%5 = 3"
str_divu_max_1: .asciz "DIVU 0xff..ff/1"
str_remu_max_1: .asciz "REMU 0xff..ff%1 = 0"
str_divu_walking: .asciz "DIVU walking pattern / 0x12345678"
str_remu_walking: .asciz "REMU walking pattern % 0x12345678"
str_div_rs1_preserved:  .asciz "DIV rs1 unmodified"
str_div_rs2_preserved:  .asciz "DIV rs2 unmodified"
str_divu_rs1_preserved: .asciz "DIVU rs1 unmodified"
str_divu_rs2_preserved: .asciz "DIVU rs2 unmodified"
str_rem_rs1_preserved:  .asciz "REM rs1 unmodified"
str_rem_rs2_preserved:  .asciz "REM rs2 unmodified"
str_remu_rs1_preserved: .asciz "REMU rs1 unmodified"
str_remu_rs2_preserved: .asciz "REMU rs2 unmodified"

str_div_alias_rd_rs1:    .asciz "DIV rd==rs1"
str_div_alias_rd_rs2:    .asciz "DIV rd==rs2"
str_rem_alias_rd_rs2:    .asciz "REM rd==rs2"
str_div_alias_all_same:  .asciz "DIV rd==rs1==rs2 (x/x = 1)"
str_remu_alias_all_same: .asciz "REMU rd==rs1==rs2 (x%x = 0)"
str_div_rd_x0:           .asciz "DIV rd=x0, divide by x0: no trap, discarded"
str_divrem_fused_q:   .asciz "DIV+REM fused sequence: quotient"
str_divrem_fused_r:   .asciz "DIV+REM fused sequence: remainder"
str_divrem_identity:  .asciz "DIV/REM identity q*d + r == dividend"
str_divremu_fused_q:  .asciz "DIVU+REMU fused sequence: quotient"
str_divremu_fused_r:  .asciz "DIVU+REMU fused sequence: remainder"

str_divw_garbage_upper:  .asciz "DIVW ignores upper 32 bits of both sources"
str_divuw_garbage_upper: .asciz "DIVUW ignores upper 32 bits of both sources"
str_remw_garbage_upper:  .asciz "REMW ignores upper 32 bits of both sources"
str_remuw_garbage_upper: .asciz "REMUW ignores upper 32 bits of both sources"
str_divw_m20_sext:  .asciz "DIVW -20/6 = -3 (sign-extended dividend)"
str_divuw_m20_sext: .asciz "DIVUW 0xffffffec/6 DIVERGES from DIVW"
str_remw_m20_sext:  .asciz "REMW -20%6 = -2 (sign-extended dividend)"
str_remuw_m20_sext: .asciz "REMUW 0xffffffec%6 = 2"
str_divw_m20_zext:  .asciz "DIVW -20/6 = -3 (zero-extended dividend)"
str_divuw_m20_zext: .asciz "DIVUW 0xffffffec/6 (zero-extended dividend)"
str_remw_m20_zext:  .asciz "REMW -20%6 = -2 (zero-extended dividend)"
str_remuw_m20_zext: .asciz "REMUW 0xffffffec%6 (zero-extended dividend)"
str_divw_overflow:         .asciz "DIVW INT32_MIN/-1 = INT32_MIN (overflow, no trap)"
str_divuw_overflow_pair:   .asciz "DIVUW 2^31/0xffffffff = 0"
str_remw_overflow:         .asciz "REMW INT32_MIN%-1 = 0 (overflow, no trap)"
str_remuw_overflow_pair:   .asciz "REMUW 2^31%0xffffffff = 2^31, sign-extended"
str_divw_overflow_zext_m1: .asciz "DIVW INT32_MIN/-1 (divisor zero-extended)"
str_remw_overflow_zext_m1: .asciz "REMW INT32_MIN%-1 (divisor zero-extended)"
str_divw_by0:  .asciz "DIVW 7/0 = -1 (no trap)"
str_divuw_by0: .asciz "DIVUW 7/0 = -1 (no trap)"
str_remw_by0:  .asciz "REMW 7%0 = 7 (no trap)"
str_remuw_by0: .asciz "REMUW 7%0 = 7 (no trap)"
str_remw_by0_signext:  .asciz "REMW -7%0 = dividend, sign-extended"
str_remuw_by0_signext: .asciz "REMUW 0xfffffff9%0 = dividend, sign-extended"
str_divw_by0_upper:  .asciz "DIVW by 0xffffffff00000000 is divide-by-zero"
str_divuw_by0_upper: .asciz "DIVUW by 0xffffffff00000000 is divide-by-zero"
str_remw_by0_upper:  .asciz "REMW by 0xffffffff00000000 is divide-by-zero"
str_remuw_by0_upper: .asciz "REMUW by 0xffffffff00000000 is divide-by-zero"
str_divuw_result_signext:     .asciz "DIVUW 0xffffffff/1 result sign-extended"
str_divuw_result_signext_min: .asciz "DIVUW 0x80000000/1 result sign-extended"
str_divw_min32_2:  .asciz "DIVW INT32_MIN/2 = -2^30"
str_divuw_min32_2: .asciz "DIVUW 2^31/2 = 2^30 DIVERGES"
str_divw_rs1_preserved:  .asciz "DIVW rs1 unmodified"
str_divw_rs2_preserved:  .asciz "DIVW rs2 unmodified"
str_divuw_rs1_preserved: .asciz "DIVUW rs1 unmodified"
str_divuw_rs2_preserved: .asciz "DIVUW rs2 unmodified"
str_remw_rs1_preserved:  .asciz "REMW rs1 unmodified"
str_remw_rs2_preserved:  .asciz "REMW rs2 unmodified"
str_remuw_rs1_preserved: .asciz "REMUW rs1 unmodified"
str_remuw_rs2_preserved: .asciz "REMUW rs2 unmodified"
