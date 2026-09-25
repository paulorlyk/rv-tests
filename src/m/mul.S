/* =====================================================================
 * m/mul.S  --  RV64M multiply instructions:
 *               MUL, MULH, MULHSU, MULHU, MULW
 *
 * Part of the RV64M suite; see m/tests.S for how this plugs into the
 * rest (main_tests.S -> m/tests.S -> here), and common.S for the
 * boot/UART/reporting harness everything sits on ("check",
 * "uart_puts" are used from there; nothing else).
 *
 * All five share the R-type OP/OP-32 encoding with funct7=0000001, so
 * the same organising idea as i/op_alu.S: the register fields carry
 * identical decode risk whichever of the five it is, so rd/rs1/rs2 and
 * their aliasing combinations are swept *once*, through MUL. The real
 * per-instruction depth goes into the arithmetic.
 *
 * Per-instruction highlights:
 *   - MUL / MULH / MULHSU / MULHU: all four run against the *same*
 *     operand pairs, so together they spell out the full 128-bit
 *     product under all three signedness interpretations. MUL's low
 *     half is identical for signed and unsigned operands; the three
 *     high-half variants are exactly where they diverge (-1 * -1 is
 *     high=0 signed, high=0xff..fe unsigned, high=0xff..ff for
 *     signed*unsigned). A decoder that swaps two of them, or an
 *     implementation that sign-extends the wrong operand, shows up as
 *     a visible mismatch instead of quietly passing. MULHSU is also the
 *     one M instruction that is *not* symmetric in its operands (rs1
 *     signed, rs2 unsigned), so both orders of (-1, 1) are tested.
 *   - The spec's recommended fused sequence (MULH[[S]U] rdh; MUL rdl
 *     with the same sources) is tested as a pair, since that is the
 *     form microarchitectures are allowed to fuse into one multiply.
 *   - MULW: operates on the low 32 bits only and sign-extends the
 *     32-bit result to 64 -- tested with garbage in the upper 32 bits
 *     of both sources, a product whose bit 31 is set (must sign-extend)
 *     and a product whose only set bits are above bit 31 (must be 0).
 *
 * Bit independence across fields (bitx_m_mul, at the end): every bit pair
 * of rd/rs1/rs2 set together, C(15,2) = 105 cases per instruction, for
 * all five -- see bitx.inc. The expected value is the same instruction
 * run through the t2/t3/t4 encoding the T_M_VAL tests above already
 * pin down against literals.
 *
 * RV32 image (xlen.inc): MULW is RV64-only and left out; the truth
 * tables use the INT32 counterparts of each operand pair, with expected
 * values from a reference model that also reproduces every RV64 row.
 * ===================================================================== */

    .include "xlen.inc"
    .include "harness.inc"

    .option norvc            /* not strictly needed (there are no compressed
                               * multiplies), but every non-RVC suite file
                               * keeps it on for the same reason: the
                               * helper li/mv/add sequences must never be
                               * silently re-encoded either. */

    .include "bitx.inc"

    .global tests_m_mul

    .section .text

/* =======================================================================
 *  Shared macros
 * ======================================================================= */

/* T_M_RD/RS1/RS2 insn, reg, v1, v2, expect, name -- sweep one register
 * field at a time (through MUL), the other two fixed at registers
 * outside the swept list. reg may be a0/a1/a2 -- result captured to t2
 * before those are reused. */
.macro T_M_RD insn, rdreg, v1, v2, expect, name
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

.macro T_M_RS1 insn, rs1reg, v1, v2, expect, name
    TEST_BEGIN \name
    LIX     \rs1reg, \v1
    LIX     t4, \v2
    \insn   t2, \rs1reg, t4
    la      a0, \name
    LIX     a1, \expect
    mv      a2, t2
    call    check
.endm

.macro T_M_RS2 insn, rs2reg, v1, v2, expect, name
    TEST_BEGIN \name
    LIX     t3, \v1
    LIX     \rs2reg, \v2
    \insn   t2, t3, \rs2reg
    la      a0, \name
    LIX     a1, \expect
    mv      a2, t2
    call    check
.endm

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

tests_m_mul:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    /* ===== register sweep (through MUL; identical decode risk for
     * all M-extension R-type ops) ===== */
    T_M_RD mul, ra,  12, 11, 132, str_m_rd_ra
    T_M_RD mul, t0,  12, 11, 132, str_m_rd_t0
    T_M_RD mul, s0,  12, 11, 132, str_m_rd_s0
    T_M_RD mul, a0,  12, 11, 132, str_m_rd_a0
    T_M_RD mul, s10, 12, 11, 132, str_m_rd_s10
    T_M_RD mul, t6,  12, 11, 132, str_m_rd_t6

    T_M_RS1 mul, ra,  12, 11, 132, str_m_rs1_ra
    T_M_RS1 mul, t0,  12, 11, 132, str_m_rs1_t0
    T_M_RS1 mul, s0,  12, 11, 132, str_m_rs1_s0
    T_M_RS1 mul, a0,  12, 11, 132, str_m_rs1_a0
    T_M_RS1 mul, s10, 12, 11, 132, str_m_rs1_s10
    T_M_RS1 mul, t6,  12, 11, 132, str_m_rs1_t6

    T_M_RS2 mul, ra,  12, 11, 132, str_m_rs2_ra
    T_M_RS2 mul, t0,  12, 11, 132, str_m_rs2_t0
    T_M_RS2 mul, s0,  12, 11, 132, str_m_rs2_s0
    T_M_RS2 mul, a0,  12, 11, 132, str_m_rs2_a0
    T_M_RS2 mul, s10, 12, 11, 132, str_m_rs2_s10
    T_M_RS2 mul, t6,  12, 11, 132, str_m_rs2_t6

    /* rd=x0: must not fault, result discarded */
    TEST_BEGIN str_m_rd_x0
    LIX     t3, 12
    LIX     t4, 11
    mul     x0, t3, t4
    la      a0, str_m_rd_x0
    LIX     a1, 0
    mv      a2, x0
    call    check

    /* ===== aliasing (through MUL): every register-overlap combination ===== */
    TEST_BEGIN str_m_alias_all_same
    LIX     t1, 13
    mul     t1, t1, t1              /* rd==rs1==rs2: squares itself */
    la      a0, str_m_alias_all_same
    LIX     a1, 169
    mv      a2, t1
    call    check

    TEST_BEGIN str_m_alias_rd_rs1
    LIX     t1, 13
    LIX     t2, 7
    mul     t1, t1, t2              /* rd==rs1 */
    la      a0, str_m_alias_rd_rs1
    LIX     a1, 91
    mv      a2, t1
    call    check

    TEST_BEGIN str_m_alias_rd_rs2
    LIX     t1, 13
    LIX     t2, 7
    mul     t2, t1, t2              /* rd==rs2 */
    la      a0, str_m_alias_rd_rs2
    LIX     a1, 91
    mv      a2, t2
    call    check

    TEST_BEGIN str_m_alias_rs1_rs2
    LIX     t1, 13
    mul     t2, t1, t1              /* rs1==rs2, rd distinct */
    la      a0, str_m_alias_rs1_rs2
    LIX     a1, 169
    mv      a2, t2
    call    check

    TEST_BEGIN str_m_alias_mulhu_rd_rs1
    /* high-half ops with rd==rs1: the whole 128-bit product must be
     * formed from the old rs1 before rd is written */
    LIX     t1, 0xffffffffffffffff
    LIX     t2, 0xffffffffffffffff
    mulhu   t1, t1, t2
    la      a0, str_m_alias_mulhu_rd_rs1
    LIX     a1, 0xfffffffffffffffe
    mv      a2, t1
    call    check

    TEST_BEGIN str_m_alias_mulh_all_same
    LIX     t1, INTX_MIN
    mulh    t1, t1, t1
    la      a0, str_m_alias_mulh_all_same
    LIX     a1, (INTX_MIN >> 1)
    mv      a2, t1
    call    check

    /* ===== MUL / MULH / MULHSU / MULHU truth table: the same operand
     *     pairs through all four, giving the full 128-bit product under
     *     each signedness interpretation ===== */
    T_M_VAL mul,    3, 7, 0x0000000000000015, str_mul_3_7
    T_M_VAL mulh,   3, 7, 0x0000000000000000, str_mulh_3_7
    T_M_VAL mulhsu, 3, 7, 0x0000000000000000, str_mulhsu_3_7
    T_M_VAL mulhu,  3, 7, 0x0000000000000000, str_mulhu_3_7

    T_M_VAL mul,    0xffffffffffffffff, 0xffffffffffffffff, 0x0000000000000001, str_mul_m1_m1
    T_M_VAL mulh,   0xffffffffffffffff, 0xffffffffffffffff, 0x0000000000000000, str_mulh_m1_m1
    T_M_VAL mulhsu, 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, str_mulhsu_m1_m1
    T_M_VAL mulhu,  0xffffffffffffffff, 0xffffffffffffffff, 0xfffffffffffffffe, str_mulhu_m1_m1

    T_M_VAL mul,    0xffffffffffffffff, 1, 0xffffffffffffffff, str_mul_m1_1
    T_M_VAL mulh,   0xffffffffffffffff, 1, 0xffffffffffffffff, str_mulh_m1_1
    T_M_VAL mulhsu, 0xffffffffffffffff, 1, 0xffffffffffffffff, str_mulhsu_m1_1
    T_M_VAL mulhu,  0xffffffffffffffff, 1, 0x0000000000000000, str_mulhu_m1_1

    T_M_VAL mul,    1, 0xffffffffffffffff, 0xffffffffffffffff, str_mul_1_m1
    T_M_VAL mulh,   1, 0xffffffffffffffff, 0xffffffffffffffff, str_mulh_1_m1
    T_M_VAL mulhsu, 1, 0xffffffffffffffff, 0x0000000000000000, str_mulhsu_1_m1
    T_M_VAL mulhu,  1, 0xffffffffffffffff, 0x0000000000000000, str_mulhu_1_m1

    .if XLEN == 64
    T_M_VAL mul,    0x8000000000000000, 0x8000000000000000, 0x0000000000000000, str_mul_min_min
    T_M_VAL mulh,   0x8000000000000000, 0x8000000000000000, 0x4000000000000000, str_mulh_min_min
    T_M_VAL mulhsu, 0x8000000000000000, 0x8000000000000000, 0xc000000000000000, str_mulhsu_min_min
    T_M_VAL mulhu,  0x8000000000000000, 0x8000000000000000, 0x4000000000000000, str_mulhu_min_min
    .else
    T_M_VAL mul,    0x80000000, 0x80000000, 0x00000000, str_mul_min_min
    T_M_VAL mulh,   0x80000000, 0x80000000, 0x40000000, str_mulh_min_min
    T_M_VAL mulhsu, 0x80000000, 0x80000000, 0xc0000000, str_mulhsu_min_min
    T_M_VAL mulhu,  0x80000000, 0x80000000, 0x40000000, str_mulhu_min_min
    .endif

    .if XLEN == 64
    T_M_VAL mul,    0x8000000000000000, 0xffffffffffffffff, 0x8000000000000000, str_mul_min_m1
    T_M_VAL mulh,   0x8000000000000000, 0xffffffffffffffff, 0x0000000000000000, str_mulh_min_m1
    T_M_VAL mulhsu, 0x8000000000000000, 0xffffffffffffffff, 0x8000000000000000, str_mulhsu_min_m1
    T_M_VAL mulhu,  0x8000000000000000, 0xffffffffffffffff, 0x7fffffffffffffff, str_mulhu_min_m1
    .else
    T_M_VAL mul,    0x80000000, 0xffffffff, 0x80000000, str_mul_min_m1
    T_M_VAL mulh,   0x80000000, 0xffffffff, 0x00000000, str_mulh_min_m1
    T_M_VAL mulhsu, 0x80000000, 0xffffffff, 0x80000000, str_mulhsu_min_m1
    T_M_VAL mulhu,  0x80000000, 0xffffffff, 0x7fffffff, str_mulhu_min_m1
    .endif

    .if XLEN == 64
    T_M_VAL mul,    0x7fffffffffffffff, 0x7fffffffffffffff, 0x0000000000000001, str_mul_max_max
    T_M_VAL mulh,   0x7fffffffffffffff, 0x7fffffffffffffff, 0x3fffffffffffffff, str_mulh_max_max
    T_M_VAL mulhsu, 0x7fffffffffffffff, 0x7fffffffffffffff, 0x3fffffffffffffff, str_mulhsu_max_max
    T_M_VAL mulhu,  0x7fffffffffffffff, 0x7fffffffffffffff, 0x3fffffffffffffff, str_mulhu_max_max
    .else
    T_M_VAL mul,    0x7fffffff, 0x7fffffff, 0x00000001, str_mul_max_max
    T_M_VAL mulh,   0x7fffffff, 0x7fffffff, 0x3fffffff, str_mulh_max_max
    T_M_VAL mulhsu, 0x7fffffff, 0x7fffffff, 0x3fffffff, str_mulhsu_max_max
    T_M_VAL mulhu,  0x7fffffff, 0x7fffffff, 0x3fffffff, str_mulhu_max_max
    .endif

    .if XLEN == 64
    T_M_VAL mul,    0x8000000000000000, 0x7fffffffffffffff, 0x8000000000000000, str_mul_min_max
    T_M_VAL mulh,   0x8000000000000000, 0x7fffffffffffffff, 0xc000000000000000, str_mulh_min_max
    T_M_VAL mulhsu, 0x8000000000000000, 0x7fffffffffffffff, 0xc000000000000000, str_mulhsu_min_max
    T_M_VAL mulhu,  0x8000000000000000, 0x7fffffffffffffff, 0x3fffffffffffffff, str_mulhu_min_max
    .else
    T_M_VAL mul,    0x80000000, 0x7fffffff, 0x80000000, str_mul_min_max
    T_M_VAL mulh,   0x80000000, 0x7fffffff, 0xc0000000, str_mulh_min_max
    T_M_VAL mulhsu, 0x80000000, 0x7fffffff, 0xc0000000, str_mulhsu_min_max
    T_M_VAL mulhu,  0x80000000, 0x7fffffff, 0x3fffffff, str_mulhu_min_max
    .endif

    .if XLEN == 64
    T_M_VAL mul,    0xfedcba9876543210, 0x0123456789abcdef, 0x2236d88fe5618cf0, str_mul_walking
    T_M_VAL mulh,   0xfedcba9876543210, 0x0123456789abcdef, 0xfffeb49923cc0953, str_mulh_walking
    T_M_VAL mulhsu, 0xfedcba9876543210, 0x0123456789abcdef, 0xfffeb49923cc0953, str_mulhsu_walking
    T_M_VAL mulhu,  0xfedcba9876543210, 0x0123456789abcdef, 0x0121fa00ad77d742, str_mulhu_walking
    .else
    T_M_VAL mul,    0xfedcba98, 0x01234567, 0x23e20b28, str_mul_walking
    T_M_VAL mulh,   0xfedcba98, 0x01234567, 0xfffeb499, str_mulh_walking
    T_M_VAL mulhsu, 0xfedcba98, 0x01234567, 0xfffeb499, str_mulhsu_walking
    T_M_VAL mulhu,  0xfedcba98, 0x01234567, 0x0121fa00, str_mulhu_walking
    .endif

    .if XLEN == 64
    T_M_VAL mul,    0x0000000100000000, 0x0000000100000000, 0x0000000000000000, str_mul_2p32_sq
    T_M_VAL mulh,   0x0000000100000000, 0x0000000100000000, 0x0000000000000001, str_mulh_2p32_sq
    T_M_VAL mulhsu, 0x0000000100000000, 0x0000000100000000, 0x0000000000000001, str_mulhsu_2p32_sq
    T_M_VAL mulhu,  0x0000000100000000, 0x0000000100000000, 0x0000000000000001, str_mulhu_2p32_sq
    .else
    T_M_VAL mul,    0x00010000, 0x00010000, 0x00000000, str_mul_2p32_sq
    T_M_VAL mulh,   0x00010000, 0x00010000, 0x00000001, str_mulh_2p32_sq
    T_M_VAL mulhsu, 0x00010000, 0x00010000, 0x00000001, str_mulhsu_2p32_sq
    T_M_VAL mulhu,  0x00010000, 0x00010000, 0x00000001, str_mulhu_2p32_sq
    .endif

    T_M_VAL mul,    0xfffffffffffffffe, 3, 0xfffffffffffffffa, str_mul_m2_3
    T_M_VAL mulh,   0xfffffffffffffffe, 3, 0xffffffffffffffff, str_mulh_m2_3
    T_M_VAL mulhsu, 0xfffffffffffffffe, 3, 0xffffffffffffffff, str_mulhsu_m2_3
    T_M_VAL mulhu,  0xfffffffffffffffe, 3, 0x0000000000000002, str_mulhu_m2_3

    .if XLEN == 64
    T_M_VAL mul,    0x1234567812345678, 0, 0x0000000000000000, str_mul_zero
    T_M_VAL mul,    0x1234567812345678, 1, 0x1234567812345678, str_mul_identity
    .else
    T_M_VAL mul,    0x12345678, 0x00000000, 0x00000000, str_mul_zero
    T_M_VAL mul,    0x12345678, 0x00000001, 0x12345678, str_mul_identity
    .endif

    T_M_PRESERVED mul,    str_mul_rs1_preserved,    str_mul_rs2_preserved
    T_M_PRESERVED mulh,   str_mulh_rs1_preserved,   str_mulh_rs2_preserved
    T_M_PRESERVED mulhsu, str_mulhsu_rs1_preserved, str_mulhsu_rs2_preserved
    T_M_PRESERVED mulhu,  str_mulhu_rs1_preserved,  str_mulhu_rs2_preserved

    TEST_BEGIN str_mul_fused_hi
    /* ===== recommended fused sequence: MULH rdh, then MUL rdl, same
     *     sources, rdh distinct from both sources ===== */
    .if XLEN == 64
    LIX     t3, 0xfedcba9876543210
    LIX     t4, 0x0123456789abcdef
    .else
    LIX     t3, 0xfedcba98
    LIX     t4, 0x01234567
    .endif
    mulh    t1, t3, t4
    mul     t2, t3, t4
    mv      s0, t2                  /* check clobbers t0-t6 */
    la      a0, str_mul_fused_hi
    .if XLEN == 64
    LIX     a1, 0xfffeb49923cc0953
    .else
    LIX     a1, 0xfffeb499
    .endif
    mv      a2, t1
    call    check
    TEST_BEGIN str_mul_fused_lo
    la      a0, str_mul_fused_lo
    .if XLEN == 64
    LIX     a1, 0x2236d88fe5618cf0
    .else
    LIX     a1, 0x23e20b28
    .endif
    mv      a2, s0
    call    check

    /* ===== MULW: low 32 bits of each source only; 32-bit result
     *     sign-extended to 64 ===== */
    .if XLEN == 64
    T_M_VAL mulw, 0xdeadbeef00000003, 0x1234567800000005, 0x000000000000000f, str_mulw_garbage_upper
    T_M_VAL mulw, 0x0000000000010000, 0x0000000000008000, 0xffffffff80000000, str_mulw_signext
    T_M_VAL mulw, 0x000000007fffffff, 2,                  0xfffffffffffffffe, str_mulw_wrap32
    T_M_VAL mulw, 0xffffffffffffffff, 0xffffffffffffffff, 0x0000000000000001, str_mulw_m1_m1
    T_M_VAL mulw, 0x0000000080000000, 0xffffffffffffffff, 0xffffffff80000000, str_mulw_min32_m1
    T_M_VAL mulw, 0x0000000100000000, 5,                  0x0000000000000000, str_mulw_upper_only
    T_M_PRESERVED mulw, str_mulw_rs1_preserved, str_mulw_rs2_preserved
    .endif

    jal     ra, bitx_m_mul

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* Bit independence across fields -- see the file header and bitx.inc. */
bitx_m_mul:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    /* signed * big-magnitude operands, so all four 64x64 variants
     * produce distinct, dense results */
    BX_POOL 0xfedcba9876543211, 0x8123456789abcdef
    BX_E_RRR5 BX_C_RRR, "mul, MUL"
    BX_E_RRR5 BX_C_RRR, "mulh, MULH"
    BX_E_RRR5 BX_C_RRR, "mulhsu, MULHSU"
    BX_E_RRR5 BX_C_RRR, "mulhu, MULHU"
    /* garbage above bit 31 in both sources; must be ignored */
    BX_POOL 0xdeadbeef87654321, 0x123456780fedcba9
    .if XLEN == 64
    BX_E_RRR5 BX_C_RRR, "mulw, MULW"
    .endif

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

    .section .rodata
str_m_rd_ra:  .asciz "MUL rd=ra(x1) (M format)"
str_m_rd_t0:  .asciz "MUL rd=t0(x5) (M format)"
str_m_rd_s0:  .asciz "MUL rd=s0(x8) (M format)"
str_m_rd_a0:  .asciz "MUL rd=a0(x10) (M format)"
str_m_rd_s10: .asciz "MUL rd=s10(x26) (M format)"
str_m_rd_t6:  .asciz "MUL rd=t6(x31) (M format)"
str_m_rs1_ra:  .asciz "MUL rs1=ra(x1) (M format)"
str_m_rs1_t0:  .asciz "MUL rs1=t0(x5) (M format)"
str_m_rs1_s0:  .asciz "MUL rs1=s0(x8) (M format)"
str_m_rs1_a0:  .asciz "MUL rs1=a0(x10) (M format)"
str_m_rs1_s10: .asciz "MUL rs1=s10(x26) (M format)"
str_m_rs1_t6:  .asciz "MUL rs1=t6(x31) (M format)"
str_m_rs2_ra:  .asciz "MUL rs2=ra(x1) (M format)"
str_m_rs2_t0:  .asciz "MUL rs2=t0(x5) (M format)"
str_m_rs2_s0:  .asciz "MUL rs2=s0(x8) (M format)"
str_m_rs2_a0:  .asciz "MUL rs2=a0(x10) (M format)"
str_m_rs2_s10: .asciz "MUL rs2=s10(x26) (M format)"
str_m_rs2_t6:  .asciz "MUL rs2=t6(x31) (M format)"
str_m_rd_x0:   .asciz "MUL rd=x0 discards result (M format)"
str_m_alias_all_same: .asciz "MUL rd==rs1==rs2 (M format, squares)"
str_m_alias_rd_rs1:   .asciz "MUL rd==rs1 (M format)"
str_m_alias_rd_rs2:   .asciz "MUL rd==rs2 (M format)"
str_m_alias_rs1_rs2:  .asciz "MUL rs1==rs2, rd distinct (M format)"
str_m_alias_mulhu_rd_rs1:  .asciz "MULHU rd==rs1"
str_m_alias_mulh_all_same: .asciz "MULH rd==rs1==rs2"

str_mul_3_7:    .asciz "MUL 3*7"
str_mulh_3_7:   .asciz "MULH 3*7 (high = 0)"
str_mulhsu_3_7: .asciz "MULHSU 3*7 (high = 0)"
str_mulhu_3_7:  .asciz "MULHU 3*7 (high = 0)"
str_mul_m1_m1:    .asciz "MUL -1*-1 = 1"
str_mulh_m1_m1:   .asciz "MULH -1*-1 high = 0 (signed)"
str_mulhsu_m1_m1: .asciz "MULHSU -1*0xff..ff high = -1 DIVERGES"
str_mulhu_m1_m1:  .asciz "MULHU 0xff..ff^2 high = 0xff..fe DIVERGES"
str_mul_m1_1:    .asciz "MUL -1*1 = -1"
str_mulh_m1_1:   .asciz "MULH -1*1 high = -1 (sign fill)"
str_mulhsu_m1_1: .asciz "MULHSU -1*1 high = -1 (rs1 signed)"
str_mulhu_m1_1:  .asciz "MULHU 0xff..ff*1 high = 0 DIVERGES"
str_mul_1_m1:    .asciz "MUL 1*-1 = -1"
str_mulh_1_m1:   .asciz "MULH 1*-1 high = -1"
str_mulhsu_1_m1: .asciz "MULHSU 1*0xff..ff high = 0 (rs2 unsigned, asymmetric)"
str_mulhu_1_m1:  .asciz "MULHU 1*0xff..ff high = 0"
    .if XLEN == 64
str_mul_min_min:    .asciz "MUL INT64_MIN^2 low = 0"
    .else
str_mul_min_min:    .asciz "MUL INT32_MIN^2 low = 0"
    .endif
    .if XLEN == 64
str_mulh_min_min:   .asciz "MULH INT64_MIN^2 high = 2^62"
    .else
str_mulh_min_min:   .asciz "MULH INT32_MIN^2 high = 2^30"
    .endif
    .if XLEN == 64
str_mulhsu_min_min: .asciz "MULHSU INT64_MIN*2^63 high = -2^62 DIVERGES"
    .else
str_mulhsu_min_min: .asciz "MULHSU INT32_MIN*2^31 high = -2^30 DIVERGES"
    .endif
    .if XLEN == 64
str_mulhu_min_min:  .asciz "MULHU 2^63*2^63 high = 2^62"
    .else
str_mulhu_min_min:  .asciz "MULHU 2^31*2^31 high = 2^30"
    .endif
    .if XLEN == 64
str_mul_min_m1:    .asciz "MUL INT64_MIN*-1 wraps to INT64_MIN"
    .else
str_mul_min_m1:    .asciz "MUL INT32_MIN*-1 wraps to INT32_MIN"
    .endif
    .if XLEN == 64
str_mulh_min_m1:   .asciz "MULH INT64_MIN*-1 high = 0 (2^63 fits in 128)"
    .else
str_mulh_min_m1:   .asciz "MULH INT32_MIN*-1 high = 0 (2^31 fits in 64)"
    .endif
    .if XLEN == 64
str_mulhsu_min_m1: .asciz "MULHSU INT64_MIN*0xff..ff high"
    .else
str_mulhsu_min_m1: .asciz "MULHSU INT32_MIN*0xff..ff high"
    .endif
    .if XLEN == 64
str_mulhu_min_m1:  .asciz "MULHU 2^63*0xff..ff high"
    .else
str_mulhu_min_m1:  .asciz "MULHU 2^31*0xff..ff high"
    .endif
    .if XLEN == 64
str_mul_max_max:    .asciz "MUL INT64_MAX^2 low = 1"
    .else
str_mul_max_max:    .asciz "MUL INT32_MAX^2 low = 1"
    .endif
    .if XLEN == 64
str_mulh_max_max:   .asciz "MULH INT64_MAX^2 high"
    .else
str_mulh_max_max:   .asciz "MULH INT32_MAX^2 high"
    .endif
    .if XLEN == 64
str_mulhsu_max_max: .asciz "MULHSU INT64_MAX^2 high"
    .else
str_mulhsu_max_max: .asciz "MULHSU INT32_MAX^2 high"
    .endif
    .if XLEN == 64
str_mulhu_max_max:  .asciz "MULHU INT64_MAX^2 high"
    .else
str_mulhu_max_max:  .asciz "MULHU INT32_MAX^2 high"
    .endif
    .if XLEN == 64
str_mul_min_max:    .asciz "MUL INT64_MIN*INT64_MAX low"
    .else
str_mul_min_max:    .asciz "MUL INT32_MIN*INT32_MAX low"
    .endif
    .if XLEN == 64
str_mulh_min_max:   .asciz "MULH INT64_MIN*INT64_MAX high (negative)"
    .else
str_mulh_min_max:   .asciz "MULH INT32_MIN*INT32_MAX high (negative)"
    .endif
    .if XLEN == 64
str_mulhsu_min_max: .asciz "MULHSU INT64_MIN*INT64_MAX high"
    .else
str_mulhsu_min_max: .asciz "MULHSU INT32_MIN*INT32_MAX high"
    .endif
    .if XLEN == 64
str_mulhu_min_max:  .asciz "MULHU 2^63*INT64_MAX high DIVERGES"
    .else
str_mulhu_min_max:  .asciz "MULHU 2^31*INT32_MAX high DIVERGES"
    .endif
str_mul_walking:    .asciz "MUL two walking patterns"
str_mulh_walking:   .asciz "MULH two walking patterns"
str_mulhsu_walking: .asciz "MULHSU two walking patterns"
str_mulhu_walking:  .asciz "MULHU two walking patterns"
    .if XLEN == 64
str_mul_2p32_sq:    .asciz "MUL 2^32*2^32 low = 0 (carry out of bit 63)"
    .else
str_mul_2p32_sq:    .asciz "MUL 2^16*2^16 low = 0 (carry out of bit 31)"
    .endif
    .if XLEN == 64
str_mulh_2p32_sq:   .asciz "MULH 2^32*2^32 high = 1"
    .else
str_mulh_2p32_sq:   .asciz "MULH 2^16*2^16 high = 1"
    .endif
    .if XLEN == 64
str_mulhsu_2p32_sq: .asciz "MULHSU 2^32*2^32 high = 1"
    .else
str_mulhsu_2p32_sq: .asciz "MULHSU 2^16*2^16 high = 1"
    .endif
    .if XLEN == 64
str_mulhu_2p32_sq:  .asciz "MULHU 2^32*2^32 high = 1"
    .else
str_mulhu_2p32_sq:  .asciz "MULHU 2^16*2^16 high = 1"
    .endif
str_mul_m2_3:    .asciz "MUL -2*3 = -6"
str_mulh_m2_3:   .asciz "MULH -2*3 high = -1"
str_mulhsu_m2_3: .asciz "MULHSU -2*3 high = -1"
str_mulhu_m2_3:  .asciz "MULHU 0xff..fe*3 high = 2 DIVERGES"
str_mul_zero:     .asciz "MUL x*0 = 0"
str_mul_identity: .asciz "MUL x*1 = x"
str_mul_rs1_preserved:    .asciz "MUL rs1 unmodified"
str_mul_rs2_preserved:    .asciz "MUL rs2 unmodified"
str_mulh_rs1_preserved:   .asciz "MULH rs1 unmodified"
str_mulh_rs2_preserved:   .asciz "MULH rs2 unmodified"
str_mulhsu_rs1_preserved: .asciz "MULHSU rs1 unmodified"
str_mulhsu_rs2_preserved: .asciz "MULHSU rs2 unmodified"
str_mulhu_rs1_preserved:  .asciz "MULHU rs1 unmodified"
str_mulhu_rs2_preserved:  .asciz "MULHU rs2 unmodified"
str_mul_fused_hi: .asciz "MULH in a fused MULH+MUL sequence: high half"
str_mul_fused_lo: .asciz "MUL in a fused MULH+MUL sequence: low half"

str_mulw_garbage_upper: .asciz "MULW ignores upper 32 bits of both sources"
str_mulw_signext:       .asciz "MULW 0x10000*0x8000 sign-extends bit 31"
str_mulw_wrap32:        .asciz "MULW 0x7fffffff*2 wraps to -2"
str_mulw_m1_m1:         .asciz "MULW -1*-1 = 1"
str_mulw_min32_m1:      .asciz "MULW INT32_MIN*-1 wraps to INT32_MIN"
str_mulw_upper_only:    .asciz "MULW 2^32*5 = 0 (only upper bits set)"
str_mulw_rs1_preserved: .asciz "MULW rs1 unmodified"
str_mulw_rs2_preserved: .asciz "MULW rs2 unmodified"
