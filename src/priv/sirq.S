/* =====================================================================
 * priv/sirq.S  --  supervisor-level interrupts: delegation, enables
 *                  across M/S/U-mode, priority, vectored stvec
 *
 * Part of the privileged-architecture suite; see priv/tests.S for how
 * this plugs into the rest (main_tests.S -> priv/tests.S -> here), and
 * common.S for the boot/UART/reporting harness everything sits on
 * ("check", "test_begin" and the armed trap mode -- trap_resume/
 * trap_count/trap_mcause/... -- are used from there). The S-mode trap
 * handler and SM_* macros are in priv/smode.inc.
 *
 * An interrupt is taken in M-mode unless its mideleg bit is set, in
 * which case it is taken in S-mode. Whether it may be taken at all
 * depends on the mode the hart is in, not only on the enable bits:
 *   - an interrupt for M-mode is enabled in M-mode if mstatus.MIE,
 *     and always enabled in S- and U-mode;
 *   - an interrupt for S-mode is disabled in M-mode whatever SIE says,
 *     enabled in S-mode if sstatus.SIE, and always enabled in U-mode;
 *   - either way its own bit in mie (sie) must be set;
 *   - M-mode interrupts go before S-mode ones, and within a level the
 *     order is external, software, timer (SEI 9 > SSI 1 > STI 5; see
 *     below for what of that is tested).
 * The three supervisor-level sources are raised from M-mode by writing
 * mip (SSIP, STIP and SEIP are all writable there; STIP as long as
 * the Sstc extension's menvcfg.STCE is 0, its reset value). For each
 * of them (SSI cause 1, STI cause 5, SEI cause 9), pending and enabled
 * in mie:
 *   - not delegated, M-mode with MIE = 1: taken in M-mode, once,
 *     mcause = interrupt bit | cause;
 *   - not delegated, S-mode with MIE = 0: taken in M-mode, once, with
 *     that mcause and MPP = 1;
 *   - delegated, M-mode with MIE = 1 and SIE = 1: not taken;
 *   - delegated, S-mode with SIE = 1: taken in S-mode, once, scause =
 *     interrupt bit | cause, SPP = 1, SPIE = 1, SIE = 0 on entry, sepc
 *     inside the S-mode code;
 *   - delegated, S-mode with SIE = 0: not taken;
 *   - delegated, U-mode with SIE = 0: taken in S-mode, once, with that
 *     scause, SPP = 0, sepc inside the U-mode code;
 *   - delegated, S-mode with SIE = 1 but the bit clear in mie: not
 *     taken.
 * And:
 *   - S-mode raises its own software interrupt (CSRRSI sip, SSIP;
 *     delegated, SIE = 1): taken in S-mode at once, scause =
 *     interrupt bit | 1;
 *   - the machine software interrupt (the CLINT's msip) in S-mode with
 *     MIE = 0, SIE = 1 and mideleg = all ones: taken in M-mode (MPP =
 *     1), mcause = interrupt bit | 3 -- it can't be delegated;
 *   - with that MSI and a delegated SSI both pending and enabled in
 *     S-mode with SIE = 1: the MSI is taken first, in M-mode;
 *   - priority: SSI + STI -> SSI, delegated in S-mode and not
 *     delegated in M-mode. Not tested: that SEI goes before SSI and
 *     STI. The spec requires it, but QEMU (10.0, without Smaia) takes
 *     SSI first when SEI and SSI are both pending (in either mode), so
 *     such a test would fail on the reference platform;
 *   - vectored stvec (MODE = 1): SSI enters at BASE + 4, STI at + 20,
 *     SEI at + 36, a delegated exception (ECALL from U-mode) at BASE.
 *     The table (si_vtable) is 16 slots of "addi s4, s4, 1" and then an
 *     ECALL to M-mode, so s4 says which slot the hart entered: 15, 11,
 *     7, 16. A hart without vectored stvec lands everything at BASE
 *     (16, a FAIL); one that ignores the stvec write reaches
 *     sm_shandler (s4 = 0, a FAIL).
 *
 * "In the S-/U-mode code" means a bounded spin followed by an ECALL
 * (SI_RUN): the spec doesn't say how many instructions may retire
 * before a newly enabled interrupt is taken, and a case that expects
 * no interrupt sees the ECALL (mcause 8/9, mepc on it) as the only
 * trap.
 *
 * FAIL, NOT HANG: everything runs armed (TRAP_ARM in harness.inc); an
 * interrupt taken in S-mode comes back through the S-mode handler's
 * ECALL, one taken in M-mode through the armed handler (which clears
 * mie), one never taken through the ECALL after the spin. Every source
 * is lowered again afterwards (sm_clean clears the S-level mip bits,
 * mie, mideleg; msip is written 0).
 *
 * ASSUMPTIONS: S-mode and U-mode; PMP and satp as for priv/smode.S; M
 * can write mip.SSIP/STIP/SEIP (see above); a CLINT/ACLINT at
 * CLINT_BASE (hart 0's msip at +0) as for priv/irqpriv.S; vectored
 * stvec accepting a 64-byte-aligned BASE. mie = 0, msip = 0 on entry
 * and on exit.
 *
 * Bit independence across fields: nothing to pair -- this is about
 * interrupt delivery, not an instruction encoding.
 *
 * Built unchanged for both widths.
 * ===================================================================== */

    .include "xlen.inc"
    .include "harness.inc"
    .include "priv/smode.inc"

    .option norvc            /* mandatory, not stylistic -- see i/loads.S */

    .global tests_priv_sirq

    .equ CLINT_BASE,     0x02000000
    .equ CLINT_MSIP,     CLINT_BASE             /* hart 0 */

    .section .text

/* =======================================================================
 *  Shared macros
 * ======================================================================= */

/* SI_PREP ideleg, mien, sie -- mideleg = ideleg and sstatus.SIE = sie
 * (armed: both only exist with S-mode), then mie = mien. Clobbers t0. */
.macro SI_PREP ideleg, mien, sie
    TRAP_ARM .Lsi_prep\@
    li      t0, \ideleg
    csrw    mideleg, t0
    .if \sie
    csrsi   sstatus, MSTATUS_SIE
    .endif
    TRAP_DISARM
.Lsi_prep\@:
    li      t0, \mien
    csrw    mie, t0
.endm

/* SI_RAISE bits -- set bits in mip. Clobbers t0. */
.macro SI_RAISE bits
    li      t0, \bits
    csrs    mip, t0
.endm

/* SI_RUN mode -- enter mode (S or U) at a bounded spin followed by an
 * ECALL, armed. Leaves s2 / s6 = the spin's first address / the ECALL,
 * s3 = M-mode traps, s8 = S-mode traps. Clobbers t0, t1. */
.macro SI_RUN mode
    SM_SCLEAR
    SM_COUNT s3
    SM_SCOUNT s8
    .option push
    .option norelax
    la      s2, .Lsi_at\@
    la      s6, .Lsi_end\@
    .option pop
    TRAP_ARM .Lsi_back\@
    SM_TO   \mode, s2
.Lsi_at\@:
    li      t0, SM_SPIN
1:  addi    t0, t0, -1
    bnez    t0, 1b
.Lsi_end\@:
    ecall
.Lsi_back\@:
    TRAP_DISARM
    SM_COUNT t0
    sub     s3, t0, s3
    SM_SCOUNT t0
    sub     s8, t0, s8
.endm

/* SI_RUN_M -- MIE = 1 in M-mode for a bounded spin, armed. Leaves s3 =
 * M-mode traps, s8 = S-mode traps. Clobbers t0. */
.macro SI_RUN_M
    SM_SCLEAR
    SM_COUNT s3
    SM_SCOUNT s8
    TRAP_ARM .Lsi_mback\@
    csrsi   mstatus, MSTATUS_MIE
    li      t0, SM_SPIN
1:  addi    t0, t0, -1
    bnez    t0, 1b
.Lsi_mback\@:
    csrci   mstatus, MSTATUS_MIE
    TRAP_DISARM
    li      t0, MSTATUS_MPIE
    csrc    mstatus, t0
    SM_COUNT t0
    sub     s3, t0, s3
    SM_SCOUNT t0
    sub     s8, t0, s8
.endm

/* SI_NONE name, mcause -- check that nothing interrupted SI_RUN: the
 * only trap is its ECALL (in M-mode, mepc = s6, mcause = mcause). */
.macro SI_NONE name, mcause
    SM_ONCE_M t2
    addi    t2, t2, -1
    TRAP_LD t0, mepc
    sub     t0, t0, s6
    or      t2, t2, t0
    TRAP_LD t0, mcause
    addi    t0, t0, -(\mcause)
    or      t2, t2, t0
    seqz    t2, t2
    SM_CHK  \name, 1, t2
.endm

/* SI_IN_CODE name, reg -- check s2 <= reg <= s6. */
.macro SI_IN_CODE name, reg
    sltu    t1, \reg, s2
    sltu    t2, s6, \reg
    or      t2, t2, t1
    xori    t2, t2, 1
    SM_CHK  \name, 1, t2
.endm

/* =======================================================================
 *  T_SI bit, cause, NAME -- the per-source cases (see the file header)
 * ======================================================================= */
.macro T_SI bit, cause, name
    SM_NAME .Lsi_m_once\@,  "\name, not delegated, MIE=1 in M-mode: taken in M-mode, exactly once"
    SM_NAME .Lsi_m_cause\@, "\name, not delegated, MIE=1 in M-mode: mcause == interrupt | \cause"
    SM_NAME .Lsi_ms_once\@, "\name, not delegated, in S-mode with MIE=0: taken in M-mode, exactly once"
    SM_NAME .Lsi_ms_cause\@,"\name, not delegated, in S-mode with MIE=0: mcause == interrupt | \cause"
    SM_NAME .Lsi_ms_mpp\@,  "\name, not delegated, in S-mode with MIE=0: trap entry MPP == 1 (S)"
    SM_NAME .Lsi_dm_none\@, "\name, delegated, MIE=1 SIE=1 in M-mode: not taken"
    SM_NAME .Lsi_ds_once\@, "\name, delegated, in S-mode with SIE=1: taken in S-mode, exactly once"
    SM_NAME .Lsi_ds_cause\@,"\name, delegated, in S-mode with SIE=1: scause == interrupt | \cause"
    SM_NAME .Lsi_ds_spp\@,  "\name, delegated, in S-mode with SIE=1: trap entry SPP == 1 (S)"
    SM_NAME .Lsi_ds_spie\@, "\name, delegated, in S-mode with SIE=1: trap entry SPIE == 1"
    SM_NAME .Lsi_ds_sie\@,  "\name, delegated, in S-mode with SIE=1: trap entry SIE == 0"
    SM_NAME .Lsi_ds_sepc\@, "\name, delegated, in S-mode with SIE=1: sepc in the S-mode code"
    SM_NAME .Lsi_d0_none\@, "\name, delegated, in S-mode with SIE=0: not taken"
    SM_NAME .Lsi_du_once\@, "\name, delegated, in U-mode with SIE=0: taken in S-mode, exactly once"
    SM_NAME .Lsi_du_cause\@,"\name, delegated, in U-mode with SIE=0: scause == interrupt | \cause"
    SM_NAME .Lsi_du_spp\@,  "\name, delegated, in U-mode with SIE=0: trap entry SPP == 0 (U)"
    SM_NAME .Lsi_du_sepc\@, "\name, delegated, in U-mode with SIE=0: sepc in the U-mode code"
    SM_NAME .Lsi_dx_none\@, "\name, delegated, not in sie, in S-mode with SIE=1: not taken"

    /* --- not delegated, M-mode, MIE = 1 --- */
    TEST_BEGIN .Lsi_m_once\@
    SI_PREP 0, \bit, 0
    SI_RAISE \bit
    SI_RUN_M
    SM_ONCE_M t2
    SM_CHK  .Lsi_m_once\@, 1, t2
    TEST_BEGIN .Lsi_m_cause\@
    TRAP_LD t2, mcause
    SM_CHK  .Lsi_m_cause\@, (INTX_MIN + \cause), t2
    jal     ra, sm_clean

    /* --- not delegated, S-mode, MIE = 0 --- */
    TEST_BEGIN .Lsi_ms_once\@
    SI_PREP 0, \bit, 0
    SI_RAISE \bit
    SI_RUN  S
    SM_ONCE_M t2
    SM_CHK  .Lsi_ms_once\@, 1, t2
    TEST_BEGIN .Lsi_ms_cause\@
    TRAP_LD t2, mcause
    SM_CHK  .Lsi_ms_cause\@, (INTX_MIN + \cause), t2
    TEST_BEGIN .Lsi_ms_mpp\@
    TRAP_LD t2, mstatus
    SM_FIELD t2, t2, 11, 3
    SM_CHK  .Lsi_ms_mpp\@, 1, t2
    jal     ra, sm_clean

    /* --- delegated, M-mode, MIE = 1, SIE = 1: not taken --- */
    TEST_BEGIN .Lsi_dm_none\@
    SI_PREP \bit, \bit, 1
    SI_RAISE \bit
    SI_RUN_M
    SM_ONCE_M t2
    SM_CHK  .Lsi_dm_none\@, 0, t2
    jal     ra, sm_clean

    /* --- delegated, S-mode, SIE = 1: taken in S-mode --- */
    TEST_BEGIN .Lsi_ds_once\@
    SI_PREP \bit, \bit, 1
    SI_RAISE \bit
    SI_RUN  S
    SM_ONCE_M t2
    SM_CHK  .Lsi_ds_once\@, 17, t2
    TEST_BEGIN .Lsi_ds_cause\@
    SM_SLD  t2, scause
    SM_CHK  .Lsi_ds_cause\@, (INTX_MIN + \cause), t2
    TEST_BEGIN .Lsi_ds_spp\@
    SM_SLD  t2, sstatus
    SM_FIELD t2, t2, 8, 1
    SM_CHK  .Lsi_ds_spp\@, 1, t2
    TEST_BEGIN .Lsi_ds_spie\@
    SM_SLD  t2, sstatus
    SM_FIELD t2, t2, 5, 1
    SM_CHK  .Lsi_ds_spie\@, 1, t2
    TEST_BEGIN .Lsi_ds_sie\@
    SM_SLD  t2, sstatus
    SM_FIELD t2, t2, 1, 1
    SM_CHK  .Lsi_ds_sie\@, 0, t2
    TEST_BEGIN .Lsi_ds_sepc\@
    SM_SLD  t3, sepc
    SI_IN_CODE .Lsi_ds_sepc\@, t3
    jal     ra, sm_clean

    /* --- delegated, S-mode, SIE = 0: not taken --- */
    TEST_BEGIN .Lsi_d0_none\@
    SI_PREP \bit, \bit, 0
    SI_RAISE \bit
    SI_RUN  S
    SI_NONE .Lsi_d0_none\@, 9
    jal     ra, sm_clean

    /* --- delegated, U-mode, SIE = 0: taken in S-mode --- */
    TEST_BEGIN .Lsi_du_once\@
    SI_PREP \bit, \bit, 0
    SI_RAISE \bit
    SI_RUN  U
    SM_ONCE_M t2
    SM_CHK  .Lsi_du_once\@, 17, t2
    TEST_BEGIN .Lsi_du_cause\@
    SM_SLD  t2, scause
    SM_CHK  .Lsi_du_cause\@, (INTX_MIN + \cause), t2
    TEST_BEGIN .Lsi_du_spp\@
    SM_SLD  t2, sstatus
    SM_FIELD t2, t2, 8, 1
    SM_CHK  .Lsi_du_spp\@, 0, t2
    TEST_BEGIN .Lsi_du_sepc\@
    SM_SLD  t3, sepc
    SI_IN_CODE .Lsi_du_sepc\@, t3
    jal     ra, sm_clean

    /* --- delegated, S-mode, SIE = 1, but not enabled in mie --- */
    TEST_BEGIN .Lsi_dx_none\@
    SI_PREP \bit, 0, 1
    SI_RAISE \bit
    SI_RUN  S
    SI_NONE .Lsi_dx_none\@, 9
    jal     ra, sm_clean
.endm

/* =======================================================================
 *  The machine software interrupt (CLINT msip); each clobbers t0-t2
 * ======================================================================= */
si_on_msip:
    li      t0, CLINT_MSIP
    li      t1, 1
    sw      t1, 0(t0)
    li      t2, 1000000             /* bounded wait for mip.MSIP */
1:  csrr    t0, mip
    andi    t0, t0, MIP_MSIP
    bnez    t0, 2f
    addi    t2, t2, -1
    bnez    t2, 1b
2:  ret

si_off_msip:
    li      t0, CLINT_MSIP
    sw      zero, 0(t0)
    li      t2, 1000000
1:  csrr    t0, mip
    andi    t0, t0, MIP_MSIP
    beqz    t0, 2f
    addi    t2, t2, -1
    bnez    t2, 1b
2:  ret

/* =======================================================================
 *  Entry point
 * ======================================================================= */
tests_priv_sirq:
    addi    sp, sp, -80
    REG_S   ra, 0(sp)
    REG_S   s2, 8(sp)
    REG_S   s3, 16(sp)
    REG_S   s4, 24(sp)
    REG_S   s5, 32(sp)
    REG_S   s6, 40(sp)
    REG_S   s8, 48(sp)

    csrci   mstatus, MSTATUS_MIE
    csrw    mie, zero
    jal     ra, si_off_msip
    SM_SETUP
    jal     ra, sm_clean

    T_SI    MIP_SSIP, 1, "IRQ supervisor software interrupt"
    T_SI    MIP_STIP, 5, "IRQ supervisor timer interrupt"
    T_SI    MIP_SEIP, 9, "IRQ supervisor external interrupt"
    jal     ra, test_si_self
    jal     ra, test_si_msi
    jal     ra, test_si_prio
    jal     ra, test_si_vec

    jal     ra, si_off_msip
    jal     ra, sm_clean
    REG_L   ra, 0(sp)
    REG_L   s2, 8(sp)
    REG_L   s3, 16(sp)
    REG_L   s4, 24(sp)
    REG_L   s5, 32(sp)
    REG_L   s6, 40(sp)
    REG_L   s8, 48(sp)
    addi    sp, sp, 80
    ret

/* =======================================================================
 *  S-mode raises its own software interrupt through sip
 * ======================================================================= */
test_si_self:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    TEST_BEGIN str_si_self_once
    SI_PREP MIP_SSIP, MIP_SSIP, 1
    SM_SCLEAR
    SM_COUNT s3
    SM_SCOUNT s8
    .option push
    .option norelax
    la      s2, .Lsi_self_s
    la      s6, .Lsi_self_end
    .option pop
    TRAP_ARM .Lsi_self_back
    SM_TO_S s2
.Lsi_self_s:                        /* S-mode */
    csrsi   sip, MIP_SSIP
    li      t0, SM_SPIN
1:  addi    t0, t0, -1
    bnez    t0, 1b
.Lsi_self_end:
    ecall
.Lsi_self_back:
    TRAP_DISARM
    SM_COUNT t0
    sub     s3, t0, s3
    SM_SCOUNT t0
    sub     s8, t0, s8
    SM_ONCE_M t2
    SM_CHK  str_si_self_once, 17, t2
    TEST_BEGIN str_si_self_cause
    SM_SLD  t2, scause
    SM_CHK  str_si_self_cause, (INTX_MIN + 1), t2
    TEST_BEGIN str_si_self_sepc
    SM_SLD  t3, sepc
    addi    s2, s2, 4               /* after the CSRRSI */
    SI_IN_CODE str_si_self_sepc, t3
    jal     ra, sm_clean

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  The machine software interrupt in S-mode: never delegated, and
 *  ahead of a supervisor interrupt
 * ======================================================================= */
test_si_msi:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    TEST_BEGIN str_si_msi_once
    SI_PREP -1, MIP_MSIP, 1
    jal     ra, si_on_msip
    SI_RUN  S
    jal     ra, si_off_msip
    SM_ONCE_M t2
    SM_CHK  str_si_msi_once, 1, t2
    TEST_BEGIN str_si_msi_cause
    TRAP_LD t2, mcause
    SM_CHK  str_si_msi_cause, (INTX_MIN + 3), t2
    TEST_BEGIN str_si_msi_mpp
    TRAP_LD t2, mstatus
    SM_FIELD t2, t2, 11, 3
    SM_CHK  str_si_msi_mpp, 1, t2
    jal     ra, sm_clean

    TEST_BEGIN str_si_msi_first
    SI_PREP MIP_SSIP, (MIP_MSIP | MIP_SSIP), 1
    SI_RAISE MIP_SSIP
    jal     ra, si_on_msip
    SI_RUN  S
    jal     ra, si_off_msip
    SM_ONCE_M t2
    SM_CHK  str_si_msi_first, 1, t2
    TEST_BEGIN str_si_msi_fcause
    TRAP_LD t2, mcause
    SM_CHK  str_si_msi_fcause, (INTX_MIN + 3), t2
    jal     ra, sm_clean

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  Priority among the supervisor-level interrupts
 * ======================================================================= */

/* T_SI_PRIO_S bits, cause, name -- bits delegated, pending, enabled, in
 * S-mode with SIE = 1: scause == interrupt | cause. */
.macro T_SI_PRIO_S bits, cause, name
    TEST_BEGIN \name
    SI_PREP \bits, \bits, 1
    SI_RAISE \bits
    SI_RUN  S
    SM_SLD  t2, scause
    SM_CHK  \name, (INTX_MIN + \cause), t2
    jal     ra, sm_clean
.endm

/* T_SI_PRIO_M bits, cause, name -- bits not delegated, pending,
 * enabled, in M-mode with MIE = 1: mcause == interrupt | cause. */
.macro T_SI_PRIO_M bits, cause, name
    TEST_BEGIN \name
    SI_PREP 0, \bits, 0
    SI_RAISE \bits
    SI_RUN_M
    TRAP_LD t2, mcause
    SM_CHK  \name, (INTX_MIN + \cause), t2
    jal     ra, sm_clean
.endm

test_si_prio:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    T_SI_PRIO_S (MIP_SSIP | MIP_STIP), 1, str_si_prio_s2
    T_SI_PRIO_M (MIP_SSIP | MIP_STIP), 1, str_si_prio_m2

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  Vectored stvec
 * ======================================================================= */

/* si_vtable: see the file header. Runs in S-mode; the ECALL returns to
 * the test in M-mode through the armed handler. */
    .balign 64
si_vtable:
    .rept   16
    addi    s4, s4, 1
    .endr
    ecall

/* SI_STVEC_VEC -- stvec = si_vtable | 1 (vectored), armed. Clobbers
 * t0. */
.macro SI_STVEC_VEC
    TRAP_ARM .Lsi_sv\@
    .option push
    .option norelax
    la      t0, si_vtable
    .option pop
    ori     t0, t0, 1
    csrw    stvec, t0
    TRAP_DISARM
.Lsi_sv\@:
.endm

/* T_SI_VEC bit, expect, name -- bit delegated, pending, enabled, in
 * S-mode with SIE = 1, vectored stvec: s4 == expect. */
.macro T_SI_VEC bit, expect, name
    TEST_BEGIN \name
    li      s4, 0
    SI_STVEC_VEC
    SI_PREP \bit, \bit, 1
    SI_RAISE \bit
    SI_RUN  S
    SM_SETUP                        /* stvec back to sm_shandler */
    SM_CHK  \name, \expect, s4
    jal     ra, sm_clean
.endm

test_si_vec:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    T_SI_VEC MIP_SSIP, 15, str_si_vec_ssi
    T_SI_VEC MIP_STIP, 11, str_si_vec_sti
    T_SI_VEC MIP_SEIP, 7, str_si_vec_sei

    /* a delegated exception: ECALL from U-mode enters at BASE */
    TEST_BEGIN str_si_vec_exc
    li      s4, 0
    SI_STVEC_VEC
    TRAP_ARM 1f
    li      t0, EDELEG_ECALL_U
    csrw    medeleg, t0
    TRAP_DISARM
1:  SM_RUN  U, nop
    SM_SETUP
    SM_CHK  str_si_vec_exc, 16, s4
    jal     ra, sm_clean

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

    SM_HANDLER_CODE

/* =======================================================================
 *  Strings
 * ======================================================================= */
    .section .rodata
str_si_self_once:  .asciz "IRQ supervisor software interrupt raised by S-mode (CSRRSI sip): taken in S-mode, exactly once"
str_si_self_cause: .asciz "IRQ supervisor software interrupt raised by S-mode (CSRRSI sip): scause == interrupt | 1"
str_si_self_sepc:  .asciz "IRQ supervisor software interrupt raised by S-mode (CSRRSI sip): sepc after the CSRRSI"
str_si_msi_once:   .asciz "IRQ machine software interrupt in S-mode, MIE=0 SIE=1, mideleg all ones: taken in M-mode, exactly once"
str_si_msi_cause:  .asciz "IRQ machine software interrupt in S-mode, MIE=0 SIE=1, mideleg all ones: mcause == interrupt | 3"
str_si_msi_mpp:    .asciz "IRQ machine software interrupt in S-mode, MIE=0 SIE=1, mideleg all ones: trap entry MPP == 1 (S)"
str_si_msi_first:  .asciz "IRQ MSI and delegated SSI both pending in S-mode with SIE=1: taken in M-mode first, exactly once"
str_si_msi_fcause: .asciz "IRQ MSI and delegated SSI both pending in S-mode with SIE=1: mcause == interrupt | 3"
str_si_prio_s2:    .asciz "IRQ SSI and STI delegated and pending in S-mode: SSI first (scause == interrupt | 1)"
str_si_prio_m2:    .asciz "IRQ SSI and STI not delegated, pending in M-mode: SSI first (mcause == interrupt | 1)"
str_si_vec_ssi:    .asciz "IRQ with vectored stvec: supervisor software interrupt enters at BASE + 4*1"
str_si_vec_sti:    .asciz "IRQ with vectored stvec: supervisor timer interrupt enters at BASE + 4*5"
str_si_vec_sei:    .asciz "IRQ with vectored stvec: supervisor external interrupt enters at BASE + 4*9"
str_si_vec_exc:    .asciz "ECALL from U-mode delegated, with vectored stvec: the exception enters at BASE"
