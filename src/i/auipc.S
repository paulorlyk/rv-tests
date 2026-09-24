/* =====================================================================
 * i/auipc.S  --  RV64I base-ISA AUIPC (add upper immediate to pc)
 *
 * Part of the RV64I base-ISA suite; see i/tests.S for how this
 * plugs into the rest (main_tests.S -> i/tests.S -> here), and
 * common.S for the boot/UART/reporting harness everything sits on
 * ("check", "uart_puts" are used from there; nothing else).
 *
 * AUIPC is U-type, like LUI, and shares its immediate encoding
 * exactly (a plain, non-scrambled 20-bit field in bits [31:12]) --
 * but where LUI computes rd = sign_extend64(imm20 << 12), AUIPC
 * computes rd = pc + sign_extend64(imm20 << 12), where pc is the
 * address of the AUIPC instruction itself. That PC-relativity is the
 * entire point of the instruction (it's how position-independent code
 * builds large PC-relative addresses), and it's also why this file
 * can't just reuse LUI's expected-value approach of a fixed literal:
 * the correct answer depends on where the instruction actually ends
 * up in the final linked binary, which isn't known until link time.
 *
 * So instead of hardcoding expected values, every test here computes
 * its own expectation at *runtime*: a local label placed exactly at
 * the AUIPC instruction gives its true address via `la` (which the
 * assembler/linker resolve correctly regardless of where the code
 * ends up), and the immediate's contribution is added to that. This
 * is the same "compute the expectation from a label instead of a
 * hardcoded constant" approach already used for C.EBREAK's mepc
 * precision check and C.JALR's link-address check in the RVC suite.
 *
 * The delta each immediate contributes is identical to what the same
 * value would produce for LUI (same sign-extension math, same
 * boundary cases), so the constants here are the same ones verified
 * there.
 *
 * There's also a dedicated test that doesn't depend on knowing any
 * absolute address at all: two AUIPCs with the *same* immediate at
 * two different code locations must differ by exactly the byte
 * distance between them (the immediate's contribution cancels out).
 * This is the test that would actually catch an implementation that
 * mistakenly computed AUIPC as if it were LUI (ignoring pc entirely,
 * which would make both results identical instead of differing by the
 * inter-instruction distance).
 *
 * rd is a full, unrestricted 5-bit field, same as LUI. rd=sp is tested
 * with the same careful isolation LUI used (poison, execute, capture,
 * restore the *real* sp, only then call into check()). rd=x0 is
 * tested too (must not fault, x0 must still read as 0).
 *
 * Bit independence across fields (bitx_i_auipc, at the end): every
 * bit pair among rd and the 20-bit immediate set together, C(25,2) =
 * 300 cases. See bitx.inc.
 * ===================================================================== */

    .include "xlen.inc"
    .include "harness.inc"

    .option norvc            /* mandatory, not stylistic -- see i/loads.S */

    .include "bitx.inc"

    .global tests_i_auipc

    .section .text

/* BX_C_AUIPC nm, rd, v -- one bit-independence case (bitx.inc): rd is
 * poisoned, then AUIPC with raw 20-bit field v. Expected: the address of
 * that AUIPC (via la) plus sign-extended v << 12, the latter an
 * assemble-time constant from the pool. */
.macro BX_C_AUIPC nm, rd, v
    BX_ENTER
    BX_PV   x\rd, 2
90: auipc   x\rd, (\v)
    mv      t6, x\rd
    .option push
    .option norelax
    la      t5, 90b
    .option pop
    BX_LDC  t4, ((((\v) << 12) ^ 0x80000000) - 0x80000000)
    add     t5, t5, t4
    BX_REPORT "\nm bitx rd=x\rd imm=\v"
.endm

/* T_AUIPC_REG rdreg, name -- fixed imm20=0x15, sweep rd across a
 * representative sample. Expected value computed from this specific
 * AUIPC instruction's own address (via the per-invocation-unique
 * local label \@ generates) plus the immediate's contribution.
 * rdreg may be a0/a1/a2 -- result captured to t2 before those are
 * reused. */
.macro T_AUIPC_REG rdreg, name
    TEST_BEGIN \name
    LIXT    \rdreg, 0xdeadbeefdeadbeef
.Lauipc_reg\@:
    auipc   \rdreg, 0x15
    mv      t2, \rdreg
    la      t3, .Lauipc_reg\@
    LIX     t4, 0x15000
    add     t3, t3, t4
    la      a0, \name
    mv      a1, t3
    mv      a2, t2
    call    check
.endm

/* T_AUIPC_VAL imm20, delta, name -- fixed rd=t1, sweep the immediate.
 * delta is the same sign-extended 64-bit contribution the equivalent
 * LUI immediate would produce (see i/lui.S). */
.macro T_AUIPC_VAL imm20, delta, name
    TEST_BEGIN \name
.Lauipc_val\@:
    auipc   t1, \imm20
    la      t3, .Lauipc_val\@
    LIX     t4, \delta
    add     t3, t3, t4
    la      a0, \name
    mv      a1, t3
    mv      a2, t1
    call    check
.endm

tests_i_auipc:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    /* --- every register in the full 5-bit rd field --- */
    T_AUIPC_REG ra,  str_auipc_rd_ra
    T_AUIPC_REG t0,  str_auipc_rd_t0
    T_AUIPC_REG s0,  str_auipc_rd_s0
    T_AUIPC_REG a0,  str_auipc_rd_a0
    T_AUIPC_REG s10, str_auipc_rd_s10
    T_AUIPC_REG t6,  str_auipc_rd_t6

    /* --- rd=x0: must not fault, x0 must still read as 0 --- */
    TEST_BEGIN str_auipc_rd_x0
.Lauipc_x0:
    auipc   zero, 0x15
    la      a0, str_auipc_rd_x0
    LIX     a1, 0
    mv      a2, zero
    call    check

    TEST_BEGIN str_auipc_rd_sp
    /* --- rd=sp: same careful isolation as LUI's -- sp never holds a
     *     non-stack value across any call. --- */
    mv      t3, sp                  /* remember the real sp */
.Lauipc_sp:
    auipc   sp, 0x15
    mv      t2, sp                  /* capture the AUIPC result */
    mv      sp, t3                  /* restore real sp before any call */
    la      t4, .Lauipc_sp
    LIX     t5, 0x15000
    add     t4, t4, t5
    la      a0, str_auipc_rd_sp
    mv      a1, t4
    mv      a2, t2
    call    check

    /* --- every notable immediate value: zero (rd must equal exactly
     *     this AUIPC's own address), minimum nonzero, positive/negative
     *     boundary either side of the sign bit (bit 19 of imm20),
     *     all-ones, and two alternating patterns --- */
    T_AUIPC_VAL 0x00000, 0x0000000000000000, str_auipc_imm_zero
    T_AUIPC_VAL 0x00001, 0x0000000000001000, str_auipc_imm_min
    T_AUIPC_VAL 0x7ffff, 0x000000007ffff000, str_auipc_imm_maxpos
    T_AUIPC_VAL 0x80000, 0xffffffff80000000, str_auipc_imm_minneg
    T_AUIPC_VAL 0xfffff, 0xfffffffffffff000, str_auipc_imm_allones
    T_AUIPC_VAL 0xaaaaa, 0xffffffffaaaaa000, str_auipc_imm_alt1
    T_AUIPC_VAL 0x55555, 0x0000000055555000, str_auipc_imm_alt0

    TEST_BEGIN str_auipc_pc_relative
    /* --- genuine PC-relativity: two AUIPCs with the *same* immediate,
     *     at two different addresses, must differ by exactly the byte
     *     distance between them (the immediate cancels out). Nothing
     *     here depends on knowing any absolute address -- both the
     *     expected distance and the actual one are computed purely
     *     from labels/registers at runtime. --- */
.Lauipc_a:
    auipc   t1, 0x10
    nop
    nop
.Lauipc_b:
    auipc   t2, 0x10
    la      t4, .Lauipc_b
    la      t5, .Lauipc_a
    sub     t3, t4, t5              /* expected: true label distance */
    sub     t2, t2, t1              /* actual: AUIPC result distance */
    la      a0, str_auipc_pc_relative
    mv      a1, t3
    mv      a2, t2
    call    check

    jal     ra, bitx_i_auipc

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

bitx_i_auipc:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    BX_POOL 0, 0                    /* only the sentinel is used */
    BX_E_RI5 BX_C_AUIPC, "AUIPC", 7, "0x1,0x2,0x4,0x8,0x10,0x20,0x40,0x80,0x100,0x200,0x400,0x800,0x1000,0x2000,0x4000,0x8000,0x10000,0x20000,0x40000,0x80000", 0

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

    .section .rodata
str_auipc_rd_ra:  .asciz "AUIPC rd=ra(x1)"
str_auipc_rd_t0:  .asciz "AUIPC rd=t0(x5)"
str_auipc_rd_s0:  .asciz "AUIPC rd=s0(x8)"
str_auipc_rd_a0:  .asciz "AUIPC rd=a0(x10)"
str_auipc_rd_s10: .asciz "AUIPC rd=s10(x26)"
str_auipc_rd_t6:  .asciz "AUIPC rd=t6(x31)"
str_auipc_rd_x0:  .asciz "AUIPC rd=x0 discards result, no fault"
str_auipc_rd_sp:  .asciz "AUIPC rd=sp"
str_auipc_imm_zero:   .asciz "AUIPC imm=0x00000 (rd == this instruction's own pc)"
str_auipc_imm_min:    .asciz "AUIPC imm=0x00001 (min nonzero)"
    .if XLEN == 64
str_auipc_imm_maxpos: .asciz "AUIPC imm=0x7ffff (max, no sign-ext)"
    .else
str_auipc_imm_maxpos: .asciz "AUIPC imm=0x7ffff (max, bit 31 clear)"
    .endif
    .if XLEN == 64
str_auipc_imm_minneg: .asciz "AUIPC imm=0x80000 (min negative, sign-extends)"
    .else
str_auipc_imm_minneg: .asciz "AUIPC imm=0x80000 (min negative, bit 31 set)"
    .endif
    .if XLEN == 64
str_auipc_imm_allones: .asciz "AUIPC imm=0xfffff (all ones, sign-extends)"
    .else
str_auipc_imm_allones: .asciz "AUIPC imm=0xfffff (all ones, bit 31 set)"
    .endif
    .if XLEN == 64
str_auipc_imm_alt1:   .asciz "AUIPC imm=0xaaaaa (alt pattern, sign-extends)"
    .else
str_auipc_imm_alt1:   .asciz "AUIPC imm=0xaaaaa (alt pattern, bit 31 set)"
    .endif
    .if XLEN == 64
str_auipc_imm_alt0:   .asciz "AUIPC imm=0x55555 (alt pattern, no sign-ext)"
    .else
str_auipc_imm_alt0:   .asciz "AUIPC imm=0x55555 (alt pattern, bit 31 clear)"
    .endif
str_auipc_pc_relative: .asciz "AUIPC is genuinely pc-relative, not a disguised LUI"
