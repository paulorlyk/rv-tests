/* =====================================================================
 * priv/deleg.S  --  exception delegation to S-mode (medeleg, mideleg)
 *
 * Part of the privileged-architecture suite; see priv/tests.S for how
 * this plugs into the rest (main_tests.S -> priv/tests.S -> here), and
 * common.S for the boot/UART/reporting harness everything sits on
 * ("check", "test_begin" and the armed trap mode -- trap_resume/
 * trap_count/trap_mcause/... -- are used from there). The S-mode trap
 * handler and SM_* macros are in priv/smode.inc.
 *
 * By default every trap goes to M-mode. A set bit in medeleg sends
 * that exception to S-mode instead -- to stvec, with scause/sepc/stval
 * and the S-mode stack (SPP, SPIE <- SIE, SIE <- 0) updated and the
 * M-mode ones left alone -- but only when it happens in S- or U-mode:
 * a trap never goes to a less-privileged mode, so an exception in
 * M-mode is taken in M-mode whatever medeleg says. What is checked:
 *   - medeleg / mideleg are WARL: medeleg[11] (ECALL from M-mode,
 *     which can't be delegated) reads 0 after writing all ones, and
 *     the bits used below (2, 3, 8) read 1; mideleg's SSIP, STIP and
 *     SEIP bits read 1 after writing all ones;
 *   - delegated, from U-mode: ECALL (medeleg[8]; with sstatus.SIE = 0
 *     and = 1 beforehand), an illegal instruction (an mscratch read,
 *     medeleg[2]), EBREAK (medeleg[3]);
 *   - delegated, from S-mode into S-mode: the same illegal
 *     instruction and EBREAK;
 *     for each: taken in S-mode exactly once (and nothing in M-mode
 *     until the S-mode handler's ECALL), scause = the cause, sepc on
 *     the instruction, SPP = the mode it came from, stval (0 for
 *     ECALL; 0 or the instruction bits for the illegal instruction; 0
 *     or the pc for EBREAK), and for the ECALL cases SIE = 0, SPIE =
 *     the SIE before;
 *   - not delegated: ECALL from U-mode with medeleg = bits 2 and 3 only
 *     goes to M-mode (mcause 8), and ECALL from S-mode with
 *     medeleg[8] set goes to M-mode (mcause 9: environment calls from
 *     S- and U-mode are separate causes with separate bits);
 *   - never delegated from M-mode: an illegal instruction (a CSRRW to
 *     the read-only mhartid) with medeleg[2] = 1 and an EBREAK with
 *     medeleg[3] = 1 are taken in M-mode, not in S-mode.
 *
 * FAIL, NOT HANG: all of it runs armed (TRAP_ARM in harness.inc),
 * through SM_RUN (priv/smode.inc): a trap delegated when it shouldn't
 * be reaches M-mode through the S-mode handler's ECALL (mcause 9), one
 * not delegated when it should be reaches M-mode directly; every
 * sequence ends in an ECALL. medeleg is written armed, so without
 * S-mode (no medeleg) the checks FAIL instead of hanging.
 *
 * ASSUMPTIONS: S-mode and U-mode are implemented; PMP and satp as for
 * priv/smode.S; medeleg bits 2, 3 and 8 and mideleg bits 1, 5 and 9 are
 * writable (true of any hart with S-mode that delegates at all). mie =
 * 0 on entry.
 *
 * Bit independence across fields: nothing to pair -- this is about trap
 * routing (ECALL, EBREAK and the CSR instructions are covered by
 * i/system.S and the Zicsr suite).
 *
 * Built unchanged for both widths.
 * ===================================================================== */

    .include "xlen.inc"
    .include "harness.inc"
    .include "priv/smode.inc"

    .option norvc            /* mandatory, not stylistic -- see i/loads.S */

    .global tests_priv_deleg

    .section .text

/* DG_EDELEG v -- medeleg = v, armed (medeleg exists only with S-mode).
 * Clobbers t0. */
.macro DG_EDELEG v
    TRAP_ARM .Ldg_ed\@
    li      t0, \v
    csrw    medeleg, t0
    TRAP_DISARM
.Ldg_ed\@:
.endm

/* T_DG_S mode, edeleg, sie, tval, desc, cause, insn -- insn in mode (S
 * or U) with medeleg = edeleg (and sstatus.SIE = sie beforehand) must
 * trap into S-mode with scause = cause. tval says what stval may be:
 * zero (0), insn (0 or the instruction bits), pc (0 or its address).
 * sie = 0 / 1 also checks SIE = 0, SPIE = sie on entry; sie = - skips
 * that. */
.macro T_DG_S mode, edeleg, sie, tval, desc, cause, insn:vararg
    SM_NAME .Ldgs_once\@,  "\desc: taken in S-mode, exactly once"
    SM_NAME .Ldgs_cause\@, "\desc: scause == \cause"
    SM_NAME .Ldgs_sepc\@,  "\desc: sepc == the instruction"
    SM_NAME .Ldgs_spp\@,   "\desc: trap entry SPP == \mode"
    .ifc \tval, zero
    SM_NAME .Ldgs_tval\@,  "\desc: stval == 0"
    .endif
    .ifc \tval, insn
    SM_NAME .Ldgs_tval\@,  "\desc: stval == 0 or the instruction"
    .endif
    .ifc \tval, pc
    SM_NAME .Ldgs_tval\@,  "\desc: stval == 0 or its address"
    .endif
    .ifnc \sie, -
    SM_NAME .Ldgs_sie\@,   "\desc: trap entry SIE == 0"
    SM_NAME .Ldgs_spie\@,  "\desc: trap entry SPIE == \sie (SIE before)"
    .endif

    TEST_BEGIN .Ldgs_once\@
    DG_EDELEG \edeleg
    .ifc \sie, 1
    TRAP_ARM .Ldgs_seti\@
    csrsi   sstatus, MSTATUS_SIE
    TRAP_DISARM
.Ldgs_seti\@:
    .endif
    SM_RUN  \mode, \insn
    /* in S-mode, then the handler's ECALL in M-mode: s3 + 16 * s8 = 17 */
    SM_ONCE_M t2
    SM_CHK  .Ldgs_once\@, 17, t2
    TEST_BEGIN .Ldgs_cause\@
    SM_SLD  t2, scause
    SM_CHK  .Ldgs_cause\@, \cause, t2
    TEST_BEGIN .Ldgs_sepc\@
    SM_SLD  t2, sepc
    SM_CHKR .Ldgs_sepc\@, s2, t2
    TEST_BEGIN .Ldgs_spp\@
    SM_SLD  t2, sstatus
    SM_FIELD t2, t2, 8, 1
    .ifc \mode, S
    SM_CHK  .Ldgs_spp\@, 1, t2
    .else
    SM_CHK  .Ldgs_spp\@, 0, t2
    .endif
    TEST_BEGIN .Ldgs_tval\@
    SM_SLD  t2, stval
    li      t3, 0
    .ifc \tval, insn
    beqz    t2, 1f
    LWUX    t3, 0(s2)
1:
    .endif
    .ifc \tval, pc
    beqz    t2, 1f
    mv      t3, s2
1:
    .endif
    SM_CHKR .Ldgs_tval\@, t3, t2
    .ifnc \sie, -
    TEST_BEGIN .Ldgs_sie\@
    SM_SLD  t2, sstatus
    SM_FIELD t2, t2, 1, 1
    SM_CHK  .Ldgs_sie\@, 0, t2
    TEST_BEGIN .Ldgs_spie\@
    SM_SLD  t2, sstatus
    SM_FIELD t2, t2, 5, 1
    SM_CHK  .Ldgs_spie\@, \sie, t2
    .endif
    jal     ra, sm_clean
.endm

/* T_DG_M mode, edeleg, desc, cause, insn -- insn in mode (S, U, or M:
 * run in place) with medeleg = edeleg must trap into M-mode, not
 * S-mode, with mcause = cause (and MPP = mode for S/U). */
.macro T_DG_M mode, edeleg, desc, cause, insn:vararg
    SM_NAME .Ldgm_once\@,  "\desc: taken in M-mode, not S-mode, exactly once"
    SM_NAME .Ldgm_cause\@, "\desc: mcause == \cause"
    .ifnc \mode, M
    SM_NAME .Ldgm_mpp\@,   "\desc: trap entry MPP == \mode"
    .endif

    TEST_BEGIN .Ldgm_once\@
    DG_EDELEG \edeleg
    .ifc \mode, M
    SM_SCLEAR
    SM_COUNT s3
    SM_SCOUNT s8
    TRAP_ARM .Ldgm_back\@
    \insn
    TRAP_DISARM
.Ldgm_back\@:
    SM_COUNT t0
    sub     s3, t0, s3
    SM_SCOUNT t0
    sub     s8, t0, s8
    .else
    SM_RUN  \mode, \insn
    .endif
    SM_ONCE_M t2
    SM_CHK  .Ldgm_once\@, 1, t2
    TEST_BEGIN .Ldgm_cause\@
    TRAP_LD t2, mcause
    SM_CHK  .Ldgm_cause\@, \cause, t2
    .ifnc \mode, M
    TEST_BEGIN .Ldgm_mpp\@
    TRAP_LD t2, mstatus
    SM_FIELD t2, t2, 11, 3
    .ifc \mode, S
    SM_CHK  .Ldgm_mpp\@, 1, t2
    .else
    SM_CHK  .Ldgm_mpp\@, 0, t2
    .endif
    .endif
    jal     ra, sm_clean
.endm

/* =======================================================================
 *  Entry point
 * ======================================================================= */
tests_priv_deleg:
    addi    sp, sp, -64
    REG_S   ra, 0(sp)
    REG_S   s2, 8(sp)
    REG_S   s3, 16(sp)
    REG_S   s4, 24(sp)
    REG_S   s8, 32(sp)

    csrci   mstatus, MSTATUS_MIE
    csrw    mie, zero
    SM_SETUP
    jal     ra, sm_clean

    jal     ra, test_dg_warl
    jal     ra, test_dg_to_s
    jal     ra, test_dg_to_m

    jal     ra, sm_clean
    REG_L   ra, 0(sp)
    REG_L   s2, 8(sp)
    REG_L   s3, 16(sp)
    REG_L   s4, 24(sp)
    REG_L   s8, 32(sp)
    addi    sp, sp, 64
    ret

/* =======================================================================
 *  medeleg / mideleg WARL
 * ======================================================================= */

/* DG_ALL1 csr, reg -- write all ones to csr, read it back into reg,
 * write 0; armed, reg = 0 if the CSR traps. Clobbers t0. */
.macro DG_ALL1 csr, reg
    li      \reg, 0
    TRAP_ARM .Ldg_a1\@
    li      t0, -1
    csrw    \csr, t0
    csrr    \reg, \csr
    csrw    \csr, zero
    TRAP_DISARM
.Ldg_a1\@:
.endm

test_dg_warl:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    TEST_BEGIN str_dg_ed11
    DG_ALL1 medeleg, s4
    li      t0, EDELEG_ECALL_M
    and     t2, s4, t0
    SM_CHK  str_dg_ed11, 0, t2
    TEST_BEGIN str_dg_edused
    li      t0, EDELEG_ILL | EDELEG_BRK | EDELEG_ECALL_U
    and     t2, s4, t0
    SM_CHK  str_dg_edused, (EDELEG_ILL | EDELEG_BRK | EDELEG_ECALL_U), t2

    TEST_BEGIN str_dg_ids
    DG_ALL1 mideleg, s4
    li      t0, SM_S_IRQS
    and     t2, s4, t0
    SM_CHK  str_dg_ids, SM_S_IRQS, t2
    jal     ra, sm_clean

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  Delegated: taken in S-mode
 * ======================================================================= */
test_dg_to_s:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    T_DG_S U, EDELEG_ECALL_U, 0, zero, "ECALL from U-mode, medeleg[8]=1, SIE=0", 8, ecall
    T_DG_S U, EDELEG_ECALL_U, 1, zero, "ECALL from U-mode, medeleg[8]=1, SIE=1", 8, ecall
    T_DG_S U, EDELEG_ILL, -, insn, "CSRRS mscratch (illegal) in U-mode, medeleg[2]=1", 2, csrr t0, mscratch
    T_DG_S S, EDELEG_ILL, -, insn, "CSRRS mscratch (illegal) in S-mode, medeleg[2]=1", 2, csrr t0, mscratch
    T_DG_S U, EDELEG_BRK, -, pc, "EBREAK in U-mode, medeleg[3]=1", 3, ebreak
    T_DG_S S, EDELEG_BRK, -, pc, "EBREAK in S-mode, medeleg[3]=1", 3, ebreak

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  Not delegated: taken in M-mode
 * ======================================================================= */
test_dg_to_m:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    T_DG_M U, (EDELEG_ILL | EDELEG_BRK), "ECALL from U-mode, medeleg[8]=0", 8, nop
    T_DG_M S, EDELEG_ECALL_U, "ECALL from S-mode, medeleg[8]=1 medeleg[9]=0", 9, nop
    /* CSRRW x0, mhartid, t0: a write to a read-only CSR (as .insn: the
     * assembler rejects it by name). 0xf14 as a signed 12-bit field. */
    T_DG_M M, EDELEG_ILL, "CSRRW mhartid (read-only) in M-mode, medeleg[2]=1", 2, .insn i 0x73, 1, x0, t0, (0xf14 - 0x1000)
    T_DG_M M, EDELEG_BRK, "EBREAK in M-mode, medeleg[3]=1", 3, ebreak

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

    SM_HANDLER_CODE

/* =======================================================================
 *  Strings
 * ======================================================================= */
    .section .rodata
str_dg_ed11:   .asciz "CSRRW medeleg all ones: bit 11 (ECALL from M-mode) reads 0"
str_dg_edused: .asciz "CSRRW medeleg all ones: bits 2, 3, 8 read 1"
str_dg_ids:    .asciz "CSRRW mideleg all ones: SSIP, STIP, SEIP bits read 1"
