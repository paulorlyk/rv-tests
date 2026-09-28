/* =====================================================================
 * priv/smode.S  --  switching between M-, S- and U-mode
 *
 * Part of the privileged-architecture suite; see priv/tests.S for how
 * this plugs into the rest (main_tests.S -> priv/tests.S -> here), and
 * common.S for the boot/UART/reporting harness everything sits on
 * ("check", "test_begin" and the armed trap mode -- trap_resume/
 * trap_count/trap_mcause/... -- are used from there). The S-mode trap
 * handler and the S-/U-mode entry macros are in priv/smode.inc.
 *
 * The other priv/ files move between M- and U-mode only. This one
 * checks the hops that involve S-mode, and a chain of them:
 *   - MRET with MPP = 1 enters S-mode: an S-mode CSR (sscratch) can be
 *     written and read back there, and an M-mode CSR (mscratch) read
 *     is illegal (mcause 2) with MPP = 1 recorded, mepc on the read.
 *     Entered in U-mode instead, the sscratch write traps first (mepc
 *     is wrong); left in M-mode, nothing traps until the ECALL after
 *     it (mcause 11);
 *   - ECALL from S-mode: exactly one trap, mcause 9 (not 8 or 11),
 *     mepc on the ECALL, mtval 0, MPP = 1;
 *   - the M-mode interrupt-enable stack on a trap from S-mode: entered
 *     with S-mode's MIE = 0 and = 1 (mie = 0, so MIE = 1 lets nothing
 *     in), MPIE = that MIE on entry, MIE = 0, MPP = 1;
 *   - a trap into M-mode leaves the S-mode stack alone: SIE, SPIE and
 *     SPP as set before (two opposite patterns) are what mstatus
 *     holds on entry;
 *   - MRET into S-mode clears MPRV (it does for any mode below M);
 *   - the chain M -> S (MRET) -> U (SRET) -> S (ECALL delegated with
 *     medeleg[8]) -> U (SRET from the S-mode handler, sepc + 4) -> S
 *     -> U -> M (an sscratch read, illegal in U-mode and not
 *     delegated): the S-mode handler runs exactly twice, U-mode goes
 *     on after each ECALL, and the final trap is mcause 2 from U-mode
 *     (MPP = 0) on the sscratch read.
 *
 * FAIL, NOT HANG: every case runs armed (TRAP_ARM in harness.inc), and
 * every S-/U-mode sequence ends in an ECALL (or an mscratch read)
 * that traps to M-mode whatever went wrong before it. The chain's
 * S-mode handler counts its passes and leaves through an ECALL to
 * M-mode after four, so an SRET that returns to the wrong place can't
 * loop.
 *
 * ASSUMPTIONS: S-mode and U-mode are implemented (misa.S, misa.U); PMP
 * (if any) lets both reach all memory -- common.S's reset sets that up
 * -- and satp = 0 (Bare, set by SM_SETUP). mie = 0 on entry. Without
 * S-mode the checks FAIL; they don't hang.
 *
 * Bit independence across fields: nothing to pair -- MRET, SRET and
 * ECALL have a single fixed encoding.
 *
 * Built unchanged for both widths.
 * ===================================================================== */

    .include "xlen.inc"
    .include "harness.inc"
    .include "priv/smode.inc"

    .option norvc            /* mandatory, not stylistic -- see i/loads.S */

    .global tests_priv_smode

    .equ SMS_PAT, 0x3c5a0ff0a5c3969     /* sscratch test value (LIXT) */

    .section .text

/* =======================================================================
 *  Entry point
 * ======================================================================= */
tests_priv_smode:
    addi    sp, sp, -80
    REG_S   ra, 0(sp)
    REG_S   s2, 8(sp)
    REG_S   s3, 16(sp)
    REG_S   s4, 24(sp)
    REG_S   s5, 32(sp)
    REG_S   s6, 40(sp)
    REG_S   s7, 48(sp)
    REG_S   s8, 56(sp)

    csrci   mstatus, MSTATUS_MIE
    csrw    mie, zero
    SM_SETUP
    jal     ra, sm_clean

    jal     ra, test_sms_enter
    jal     ra, test_sms_ecall
    jal     ra, test_sms_stack
    jal     ra, test_sms_mprv
    jal     ra, test_sms_chain

    jal     ra, sm_clean
    REG_L   ra, 0(sp)
    REG_L   s2, 8(sp)
    REG_L   s3, 16(sp)
    REG_L   s4, 24(sp)
    REG_L   s5, 32(sp)
    REG_L   s6, 40(sp)
    REG_L   s7, 48(sp)
    REG_L   s8, 56(sp)
    addi    sp, sp, 80
    ret

/* =======================================================================
 *  MRET with MPP = 1 enters S-mode
 * ======================================================================= */
test_sms_enter:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    TEST_BEGIN str_sms_ent_once
    LIXT    s5, SMS_PAT
    li      s6, 0                   /* poison: the sscratch read-back */
    SM_COUNT s3
    .option push
    .option norelax
    la      s2, .Lsms_ent_s
    la      s7, .Lsms_ent_m
    .option pop
    TRAP_ARM .Lsms_ent_back
    SM_TO_S s2
.Lsms_ent_s:                        /* S-mode from here */
    csrw    sscratch, s5
    csrr    s6, sscratch
.Lsms_ent_m:
    csrr    t0, mscratch            /* illegal in S-mode */
    ecall                           /* backstop */
.Lsms_ent_back:
    TRAP_DISARM
    SM_COUNT t0
    sub     s3, t0, s3
    SM_CHK  str_sms_ent_once, 1, s3
    TEST_BEGIN str_sms_ent_sscratch
    LIXT    t2, SMS_PAT
    SM_CHKR str_sms_ent_sscratch, t2, s6
    TEST_BEGIN str_sms_ent_cause
    TRAP_LD t2, mcause
    SM_CHK  str_sms_ent_cause, 2, t2
    TEST_BEGIN str_sms_ent_mepc
    TRAP_LD t2, mepc
    SM_CHKR str_sms_ent_mepc, s7, t2
    TEST_BEGIN str_sms_ent_mpp
    TRAP_LD t2, mstatus
    SM_FIELD t2, t2, 11, 3
    SM_CHK  str_sms_ent_mpp, 1, t2
    jal     ra, sm_clean

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  ECALL from S-mode
 * ======================================================================= */
test_sms_ecall:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    /* SM_RUN S, nop: the ECALL under test is SM_RUN's own, at s2 + 4 */
    TEST_BEGIN str_sms_ec_once
    SM_RUN  S, nop
    SM_ONCE_M t2
    SM_CHK  str_sms_ec_once, 1, t2
    TEST_BEGIN str_sms_ec_cause
    TRAP_LD t2, mcause
    SM_CHK  str_sms_ec_cause, 9, t2
    TEST_BEGIN str_sms_ec_mepc
    TRAP_LD t2, mepc
    addi    t3, s2, 4
    SM_CHKR str_sms_ec_mepc, t3, t2
    TEST_BEGIN str_sms_ec_mtval
    TRAP_LD t2, mtval
    SM_CHK  str_sms_ec_mtval, 0, t2
    TEST_BEGIN str_sms_ec_mpp
    TRAP_LD t2, mstatus
    SM_FIELD t2, t2, 11, 3
    SM_CHK  str_sms_ec_mpp, 1, t2
    jal     ra, sm_clean

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  The interrupt-enable stacks on a trap from S-mode into M-mode
 * ======================================================================= */

/* T_SMS_MSTACK mie, s_mpie, s_mie, s_mpp -- enter S-mode with MIE = mie
 * (MPIE = mie before the MRET), ECALL there, check the M-mode stack
 * the trap recorded. */
.macro T_SMS_MSTACK mie, s_mpie, s_mie, s_mpp
    TEST_BEGIN \s_mpie
    .option push
    .option norelax
    la      s2, .Lsms_ms_at\@
    .option pop
    TRAP_ARM .Lsms_ms_back\@
    li      t0, MSTATUS_MPP | MSTATUS_MPIE
    csrc    mstatus, t0
    li      t0, MSTATUS_MPP_S
    .if \mie
    ori     t0, t0, MSTATUS_MPIE
    .endif
    csrs    mstatus, t0
    csrw    mepc, s2
    mret
.Lsms_ms_at\@:
    ecall                           /* in S-mode */
    csrr    t0, mscratch            /* backstop */
.Lsms_ms_back\@:
    csrci   mstatus, MSTATUS_MIE    /* the handler's MRET restored it */
    TRAP_DISARM
    TRAP_LD t2, mstatus
    SM_FIELD t2, t2, 7, 1
    SM_CHK  \s_mpie, \mie, t2
    TEST_BEGIN \s_mie
    TRAP_LD t2, mstatus
    SM_FIELD t2, t2, 3, 1
    SM_CHK  \s_mie, 0, t2
    TEST_BEGIN \s_mpp
    TRAP_LD t2, mstatus
    SM_FIELD t2, t2, 11, 3
    SM_CHK  \s_mpp, 1, t2
    jal     ra, sm_clean
.endm

/* T_SMS_SSTACK pat, name -- set sstatus's SIE/SPIE/SPP to pat in
 * M-mode, ECALL from S-mode, check that mstatus on entry still holds
 * pat there. SIE = 1 in S-mode is harmless: mie = 0. */
.macro T_SMS_SSTACK pat, name
    TEST_BEGIN \name
    TRAP_ARM .Lsms_ss_back\@
    li      t0, SM_SSTATUS_CLR
    csrc    sstatus, t0
    li      t0, \pat
    csrs    sstatus, t0
    SM_RUN  S, nop
.Lsms_ss_back\@:
    TRAP_DISARM
    TRAP_LD t2, mstatus
    li      t0, SM_SSTATUS_CLR
    and     t2, t2, t0
    SM_CHK  \name, \pat, t2
    jal     ra, sm_clean
.endm

test_sms_stack:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    T_SMS_MSTACK 0, str_sms_m0_mpie, str_sms_m0_mie, str_sms_m0_mpp
    T_SMS_MSTACK 1, str_sms_m1_mpie, str_sms_m1_mie, str_sms_m1_mpp
    T_SMS_SSTACK (MSTATUS_SIE | MSTATUS_SPP), str_sms_ss_102
    T_SMS_SSTACK MSTATUS_SPIE, str_sms_ss_020

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  MRET into S-mode clears MPRV
 * ======================================================================= */
test_sms_mprv:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    /* MPRV = 1 with MPP = S: M-mode loads/stores until the MRET use
     * S-mode's permissions, which (Bare, PMP entry 0) are the same */
    TEST_BEGIN str_sms_mprv
    .option push
    .option norelax
    la      s2, .Lsms_mprv_s
    .option pop
    TRAP_ARM .Lsms_mprv_back
    li      t0, MSTATUS_MPP | MSTATUS_MPIE
    csrc    mstatus, t0
    li      t0, MSTATUS_MPP_S | MSTATUS_MPRV
    csrs    mstatus, t0
    csrw    mepc, s2
    mret
.Lsms_mprv_s:
    ecall                           /* in S-mode */
.Lsms_mprv_back:
    li      t0, MSTATUS_MPRV
    csrc    mstatus, t0
    TRAP_DISARM
    TRAP_LD t2, mstatus
    SM_FIELD t2, t2, 17, 1
    SM_CHK  str_sms_mprv, 0, t2
    jal     ra, sm_clean

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  The chain M -> S -> U -> S -> U -> S -> U -> M
 *
 *  s4 = passes through the chain's S-mode handler, s6 = ECALLs U-mode
 *  got past.
 * ======================================================================= */

/* The chain's own S-mode handler: step sepc past the ECALL and SRET
 * back to U-mode (SPP = 0, set by the trap from U-mode). After four
 * passes, leave through an ECALL to M-mode instead. Clobbers t0. */
    .balign 4
sms_chain_sh:
    addi    s4, s4, 1
    li      t0, 4
    bgeu    s4, t0, 1f
    csrr    t0, sepc
    addi    t0, t0, 4
    csrw    sepc, t0
    sret
1:  ecall

test_sms_chain:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    TEST_BEGIN str_sms_ch_passes
    li      s4, 0
    li      s6, 0
    .option push
    .option norelax
    la      s2, .Lsms_ch_s
    la      s7, .Lsms_ch_ill
    .option pop
    TRAP_ARM .Lsms_ch_back
    .option push
    .option norelax
    la      t0, sms_chain_sh
    .option pop
    csrw    stvec, t0
    li      t0, EDELEG_ECALL_U
    csrw    medeleg, t0
    SM_TO_S s2
.Lsms_ch_s:                         /* S-mode: SRET into U-mode */
    .option push
    .option norelax
    la      t0, .Lsms_ch_u
    .option pop
    csrw    sepc, t0
    li      t0, MSTATUS_SPP | MSTATUS_SPIE
    csrc    sstatus, t0
    sret
    ecall                           /* backstop: SRET fell through */
.Lsms_ch_u:                         /* U-mode */
    ecall                           /* -> S-mode handler -> back */
    addi    s6, s6, 1
    ecall
    addi    s6, s6, 1
.Lsms_ch_ill:
    csrr    t0, sscratch            /* illegal in U-mode: to M-mode */
    csrr    t0, mscratch            /* backstops */
    ecall
.Lsms_ch_back:
    TRAP_DISARM
    SM_CHK  str_sms_ch_passes, 2, s4
    TEST_BEGIN str_sms_ch_resumed
    SM_CHK  str_sms_ch_resumed, 2, s6
    TEST_BEGIN str_sms_ch_cause
    TRAP_LD t2, mcause
    SM_CHK  str_sms_ch_cause, 2, t2
    TEST_BEGIN str_sms_ch_mepc
    TRAP_LD t2, mepc
    SM_CHKR str_sms_ch_mepc, s7, t2
    TEST_BEGIN str_sms_ch_mpp
    TRAP_LD t2, mstatus
    SM_FIELD t2, t2, 11, 3
    SM_CHK  str_sms_ch_mpp, 0, t2
    SM_SETUP                        /* stvec back to sm_shandler */
    jal     ra, sm_clean

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

    SM_HANDLER_CODE

/* =======================================================================
 *  Strings
 * ======================================================================= */
    .section .rodata
str_sms_ent_once:     .asciz "MRET with MPP=1 (S): traps exactly once (the mscratch read)"
str_sms_ent_sscratch: .asciz "MRET with MPP=1 (S): sscratch written and read back in S-mode"
str_sms_ent_cause:    .asciz "MRET with MPP=1 (S): mscratch read in S-mode, mcause == 2"
str_sms_ent_mepc:     .asciz "MRET with MPP=1 (S): mscratch read in S-mode, mepc == the read"
str_sms_ent_mpp:      .asciz "MRET with MPP=1 (S): mscratch read in S-mode, trap entry MPP == 1 (S)"
str_sms_ec_once:      .asciz "ECALL from S-mode traps exactly once, into M-mode"
str_sms_ec_cause:     .asciz "ECALL from S-mode: mcause == 9"
str_sms_ec_mepc:      .asciz "ECALL from S-mode: mepc == the ECALL"
str_sms_ec_mtval:     .asciz "ECALL from S-mode: mtval == 0"
str_sms_ec_mpp:       .asciz "ECALL from S-mode: trap entry MPP == 1 (S)"
str_sms_m0_mpie:      .asciz "ECALL from S-mode with MIE=0: trap entry MPIE == 0"
str_sms_m0_mie:       .asciz "ECALL from S-mode with MIE=0: trap entry MIE == 0"
str_sms_m0_mpp:       .asciz "ECALL from S-mode with MIE=0: trap entry MPP == 1 (S)"
str_sms_m1_mpie:      .asciz "ECALL from S-mode with MIE=1: trap entry MPIE == 1"
str_sms_m1_mie:       .asciz "ECALL from S-mode with MIE=1: trap entry MIE == 0"
str_sms_m1_mpp:       .asciz "ECALL from S-mode with MIE=1: trap entry MPP == 1 (S)"
str_sms_ss_102:       .asciz "ECALL from S-mode into M-mode: SIE=1 SPIE=0 SPP=1 unchanged"
str_sms_ss_020:       .asciz "ECALL from S-mode into M-mode: SIE=0 SPIE=1 SPP=0 unchanged"
str_sms_mprv:         .asciz "MRET with MPP=1 (S) clears MPRV"
str_sms_ch_passes:    .asciz "ECALL from U-mode delegated to S, SRET back, twice: S handler entered twice"
str_sms_ch_resumed:   .asciz "ECALL from U-mode delegated to S, SRET back, twice: U-mode resumed after each"
str_sms_ch_cause:     .asciz "ECALL from U-mode delegated to S, SRET back, twice: then sscratch read in U, mcause == 2"
str_sms_ch_mepc:      .asciz "ECALL from U-mode delegated to S, SRET back, twice: then sscratch read in U, mepc == the read"
str_sms_ch_mpp:       .asciz "ECALL from U-mode delegated to S, SRET back, twice: then sscratch read in U, MPP == 0 (U)"
