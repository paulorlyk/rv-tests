/* =====================================================================
 * priv/mstatus.S  --  mstatus privilege fields: MPP and UXL legality,
 *                     misa.U, the interrupt-enable stack on a trap
 *                     from U-mode
 *
 * Part of the privileged-architecture suite; see priv/tests.S for how
 * this plugs into the rest (main_tests.S -> priv/tests.S -> here), and
 * common.S for the boot/UART/reporting harness everything sits on
 * ("check", "test_begin" and the armed trap mode -- trap_resume/
 * trap_count/trap_mcause/... -- are used from there).
 *
 * The fields of mstatus that say which privilege mode code runs in, or
 * came from, must never hold a mode the hart doesn't have: MRET would
 * go there. What is checked:
 *   - MPP is WARL: after writing 3 (M) it reads 3; after writing 0 (U)
 *     it reads 0 (this hart has U-mode, misa.U); after writing 1 (S)
 *     it reads 1 if misa.S, else a legal mode (0 or 3); after writing
 *     2 (reserved: no mode has that number) it reads a legal mode (0,
 *     3, or 1 if misa.S). The field is written with CSRRW of the whole
 *     register, everything else unchanged, and mstatus is put back
 *     straight afterwards (no MRET ever runs with the value);
 *   - misa.U = 1 (the U-mode tests throughout assume it; this makes the
 *     assumption a result line);
 *   - RV64 only: mstatus.UXL (bits 33:32) = 2, U-mode runs at XLEN =
 *     64, and after writing 0 or 3 (not a supported U-mode XLEN: 3
 *     means 128) it still reads a legal value, 1 or 2;
 *   - the interrupt-enable stack on a trap from U-mode: entered with
 *     U-mode's MIE = 0 and with MIE = 1 (MPIE = 0 / 1 before the MRET;
 *     mie = 0 throughout, so MIE = 1 can't let an interrupt in), an
 *     ECALL traps exactly once, and on entry MPIE = U-mode's MIE, MIE
 *     = 0 and MPP = 0 (U).
 *
 * FAIL, NOT HANG: the U-mode cases run armed (TRAP_ARM in harness.inc)
 * and an ECALL is the instruction that traps, with an mscratch read
 * (illegal in U-mode) after it as the backstop.
 *
 * ASSUMPTIONS: U-mode is implemented and PMP (if any) lets U-mode reach
 * all memory -- common.S's reset sets that up. mie = 0 on entry.
 *
 * Bit independence across fields: nothing to pair -- these are CSR
 * fields, not instruction encodings (CSRRW and ECALL have theirs in
 * the Zicsr suite and i/system.S).
 *
 * Built for both widths; the UXL checks are RV64 only (RV32 mstatus
 * has no UXL: U-mode is always 32-bit there).
 * ===================================================================== */

    .include "xlen.inc"
    .include "harness.inc"

    .option norvc            /* mandatory, not stylistic -- see i/loads.S */

    .global tests_priv_mstatus

    .equ MISA_S, 1 << 18
    .equ MISA_U, 1 << 20

    .section .text

/* =======================================================================
 *  Shared macros
 * ======================================================================= */

/* MS_COUNT reg -- reg = trap_count (pc-relative). */
.macro MS_COUNT reg
    .option push
    .option norelax
    lw      \reg, trap_count
    .option pop
.endm

/* MS_FIELD rd, rs, shift, mask -- rd = (rs >> shift) & mask */
.macro MS_FIELD rd, rs, shift, mask
    srli    \rd, \rs, \shift
    andi    \rd, \rd, \mask
.endm

/* MS_CHK name, expected, actual -- check(name, LIX expected, actual).
 * actual must not be a0/a1. */
.macro MS_CHK name, exp, act
    la      a0, \name
    LIX     a1, \exp
    mv      a2, \act
    call    check
.endm

/* MS_CHKR name, expected, actual -- same, expected in a register (not
 * a0/a2). */
.macro MS_CHKR name, exp, act
    la      a0, \name
    mv      a1, \exp
    mv      a2, \act
    call    check
.endm

/* MS_MPP_WRITE v -- write mstatus with MPP = v (everything else as it
 * was), read MPP back into s4, put mstatus back. Clobbers t0-t1. */
.macro MS_MPP_WRITE v
    csrr    t1, mstatus
    li      t0, MSTATUS_MPP
    not     t0, t0
    and     t0, t0, t1
    li      s4, (\v) << 11
    or      t0, t0, s4
    csrw    mstatus, t0
    csrr    s4, mstatus
    csrw    mstatus, t1
    MS_FIELD s4, s4, 11, 3
.endm

/* =======================================================================
 *  Entry point
 * ======================================================================= */
tests_priv_mstatus:
    addi    sp, sp, -48
    REG_S   ra, 0(sp)
    REG_S   s2, 8(sp)
    REG_S   s3, 16(sp)
    REG_S   s4, 24(sp)
    REG_S   s5, 32(sp)

    jal     ra, test_ms_mpp
    jal     ra, test_ms_misa_u
    .if XLEN == 64
    jal     ra, test_ms_uxl
    .endif
    jal     ra, test_ms_stack_u

    REG_L   ra, 0(sp)
    REG_L   s2, 8(sp)
    REG_L   s3, 16(sp)
    REG_L   s4, 24(sp)
    REG_L   s5, 32(sp)
    addi    sp, sp, 48
    ret

/* =======================================================================
 *  MPP: WARL, only modes the hart has
 * ======================================================================= */
test_ms_mpp:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    csrr    s5, misa
    li      t0, MISA_S
    and     s5, s5, t0              /* s5 != 0: S-mode exists */

    TEST_BEGIN str_ms_mpp3
    MS_MPP_WRITE 3
    MS_CHK  str_ms_mpp3, 3, s4

    TEST_BEGIN str_ms_mpp0
    MS_MPP_WRITE 0
    MS_CHK  str_ms_mpp0, 0, s4

    /* --- 1 (S): reads 1 with S-mode; otherwise expected = what it
     *     reads if that is 0 or 3, else 3 (the check then FAILs) --- */
    TEST_BEGIN str_ms_mpp1
    MS_MPP_WRITE 1
    li      t2, 1
    bnez    s5, 1f
    mv      t2, s4
    beqz    t2, 1f
    li      t2, 3
1:  MS_CHKR str_ms_mpp1, t2, s4

    /* --- 2 (reserved): expected = what it reads if that is 0, 3, or
     *     1 with S-mode, else 3 --- */
    TEST_BEGIN str_ms_mpp2
    MS_MPP_WRITE 2
    mv      t2, s4
    beqz    t2, 1f
    li      t0, 3
    beq     t2, t0, 1f
    li      t0, 1
    bne     t2, t0, 2f
    bnez    s5, 1f
2:  li      t2, 3
1:  MS_CHKR str_ms_mpp2, t2, s4

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  misa.U
 * ======================================================================= */
test_ms_misa_u:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    TEST_BEGIN str_ms_misa_u
    csrr    t2, misa
    MS_FIELD t2, t2, 20, 1
    MS_CHK  str_ms_misa_u, 1, t2

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  UXL (RV64 only): reads 2, and stays legal (1 or 2) after writing 0
 *  or 3
 * ======================================================================= */
    .if XLEN == 64
/* MS_UXL_WRITE v -- as MS_MPP_WRITE, for UXL (bits 33:32); s4 = UXL
 * read back. */
.macro MS_UXL_WRITE v
    csrr    t1, mstatus
    li      t0, 3
    slli    t0, t0, 32
    not     t0, t0
    and     t0, t0, t1
    li      s4, \v
    slli    s4, s4, 32
    or      t0, t0, s4
    csrw    mstatus, t0
    csrr    s4, mstatus
    csrw    mstatus, t1
    MS_FIELD s4, s4, 32, 3
.endm

/* MS_UXL_LEGAL name -- check that s4 is 1 or 2 (expected = s4 if so,
 * else 2). */
.macro MS_UXL_LEGAL name
    mv      t2, s4
    addi    t0, t2, -1
    li      t1, 2
    bltu    t0, t1, 1f              /* 1 or 2 */
    li      t2, 2
1:  MS_CHKR \name, t2, s4
.endm

test_ms_uxl:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    TEST_BEGIN str_ms_uxl
    csrr    t2, mstatus
    MS_FIELD t2, t2, 32, 3
    MS_CHK  str_ms_uxl, 2, t2

    TEST_BEGIN str_ms_uxl0
    MS_UXL_WRITE 0
    MS_UXL_LEGAL str_ms_uxl0

    TEST_BEGIN str_ms_uxl3
    MS_UXL_WRITE 3
    MS_UXL_LEGAL str_ms_uxl3

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret
    .endif

/* =======================================================================
 *  The interrupt-enable stack on a trap from U-mode
 * ======================================================================= */

/* T_MS_STACK_U mie, s_once, s_mpie, s_mie, s_mpp -- enter U-mode with
 * MIE = mie (MPIE = mie before the MRET), ECALL there, check what the
 * trap recorded. */
.macro T_MS_STACK_U mie, s_once, s_mpie, s_mie, s_mpp
    TEST_BEGIN \s_once
    MS_COUNT s3
    TRAP_ARM .Lms_back\@
    li      t0, MSTATUS_MPP | MSTATUS_MPIE
    csrc    mstatus, t0
    .if \mie
    li      t0, MSTATUS_MPIE
    csrs    mstatus, t0
    .endif
    la      t0, .Lms_at\@
    csrw    mepc, t0
    mret
.Lms_at\@:
    ecall                           /* in U-mode */
    csrr    t0, mscratch            /* backstop: illegal in U-mode */
.Lms_back\@:
    csrci   mstatus, MSTATUS_MIE    /* the handler's MRET restored it */
    li      t0, MSTATUS_MPIE
    csrc    mstatus, t0
    TRAP_DISARM
    MS_COUNT t0
    sub     s3, t0, s3
    MS_CHK  \s_once, 1, s3
    TEST_BEGIN \s_mpie
    TRAP_LD t2, mstatus
    MS_FIELD t2, t2, 7, 1
    MS_CHK  \s_mpie, \mie, t2
    TEST_BEGIN \s_mie
    TRAP_LD t2, mstatus
    MS_FIELD t2, t2, 3, 1
    MS_CHK  \s_mie, 0, t2
    TEST_BEGIN \s_mpp
    TRAP_LD t2, mstatus
    MS_FIELD t2, t2, 11, 3
    MS_CHK  \s_mpp, 0, t2
.endm

test_ms_stack_u:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    csrw    mie, zero
    T_MS_STACK_U 0, str_ms_u0_once, str_ms_u0_mpie, str_ms_u0_mie, str_ms_u0_mpp
    T_MS_STACK_U 1, str_ms_u1_once, str_ms_u1_mpie, str_ms_u1_mie, str_ms_u1_mpp

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  Strings
 * ======================================================================= */
    .section .rodata
str_ms_mpp3:     .asciz "CSRRW mstatus.MPP written 3 (M): reads 3"
str_ms_mpp0:     .asciz "CSRRW mstatus.MPP written 0 (U): reads 0"
str_ms_mpp1:     .asciz "CSRRW mstatus.MPP written 1 (S): reads 1 with S-mode, else 0 or 3"
str_ms_mpp2:     .asciz "CSRRW mstatus.MPP written 2 (reserved): reads a legal mode"
str_ms_misa_u:   .asciz "CSRRS reads misa.U == 1 (U-mode implemented)"
    .if XLEN == 64
str_ms_uxl:      .asciz "CSRRS reads mstatus.UXL == 2 (U-mode XLEN 64)"
str_ms_uxl0:     .asciz "CSRRW mstatus.UXL written 0: reads 1 or 2"
str_ms_uxl3:     .asciz "CSRRW mstatus.UXL written 3 (XLEN 128): reads 1 or 2"
    .endif
str_ms_u0_once:  .asciz "ECALL from U-mode with MIE=0 traps exactly once"
str_ms_u0_mpie:  .asciz "ECALL from U-mode with MIE=0: trap entry MPIE == 0"
str_ms_u0_mie:   .asciz "ECALL from U-mode with MIE=0: trap entry MIE == 0"
str_ms_u0_mpp:   .asciz "ECALL from U-mode with MIE=0: trap entry MPP == 0 (U)"
str_ms_u1_once:  .asciz "ECALL from U-mode with MIE=1 traps exactly once"
str_ms_u1_mpie:  .asciz "ECALL from U-mode with MIE=1: trap entry MPIE == 1"
str_ms_u1_mie:   .asciz "ECALL from U-mode with MIE=1: trap entry MIE == 0"
str_ms_u1_mpp:   .asciz "ECALL from U-mode with MIE=1: trap entry MPP == 0 (U)"
