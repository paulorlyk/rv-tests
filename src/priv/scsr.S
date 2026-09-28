/* =====================================================================
 * priv/scsr.S  --  S-mode CSRs: the sstatus/sie/sip views of the
 *                  M-mode registers, and CSR privilege between M-, S-
 *                  and U-mode
 *
 * Part of the privileged-architecture suite; see priv/tests.S for how
 * this plugs into the rest (main_tests.S -> priv/tests.S -> here), and
 * common.S for the boot/UART/reporting harness everything sits on
 * ("check", "test_begin" and the armed trap mode -- trap_resume/
 * trap_count/trap_mcause/... -- are used from there). The SM_* and
 * T_SM_* macros are in priv/smode.inc.
 *
 * sstatus, sie and sip are not registers of their own: they are
 * restricted views of mstatus, mie and mip, and must neither show nor
 * change anything S-mode isn't entitled to. Checked from M-mode:
 *   - sstatus: SIE/SPIE/SPP set through mstatus read back through
 *     sstatus, and set through sstatus read back through mstatus;
 *     with mstatus's M-mode fields (MPIE, MPP, MPRV, TW, TVM, TSR) set,
 *     sstatus reads 0 there; and writing all ones to sstatus leaves
 *     those fields (and MIE) 0 in mstatus;
 *   - sie: SSIE reads 0 while SSI is not delegated (mie.SSIE = 1), and
 *     mirrors mie.SSIE once it is; with mideleg all ones, the M-level
 *     enables (MSIE, MTIE, MEIE) still read 0 in sie; setting sie.SSIE
 *     sets mie.SSIE only if SSI is delegated;
 *   - sip: SSIP reads 0 while not delegated (mip.SSIP = 1) and mirrors
 *     it once delegated, likewise STIP; clearing sip.SSIP clears
 *     mip.SSIP when delegated.
 * mie = 0 throughout the sip cases (and MIE = 0 in all of them), so
 * nothing pending is ever taken.
 *
 * Privilege (a CSR's number, bits 9:8, says the lowest mode that may
 * access it; see priv/csrpriv.S for the M-mode CSRs from U-mode):
 *   - the S-mode CSRs sstatus, sie, stvec, sscratch, sepc, scause,
 *     stval, sip, satp, scounteren from U-mode: a read (CSRRS rd, csr,
 *     x0) and a write of the value already there (CSRRW rd, csr, rs1)
 *     are illegal (T_SM_ILL: one trap, into M-mode, mcause 2, mepc on
 *     it, MPP = 0, rd not written);
 *   - the same S-mode CSRs from S-mode: the read doesn't trap (T_SM_OK);
 *   - the M-mode CSRs mstatus, misa, medeleg, mideleg, mie, mtvec,
 *     mcounteren, menvcfg, mscratch, mepc, mcause, mtval, mip, mhartid
 *     from S-mode: the read, and (except the read-only mhartid) the
 *     write of the value already there, are illegal, with MPP = 1.
 * Writing the value already there means a write that wrongly goes
 * through changes nothing (the CSRs that a trap overwrites anyway --
 * mepc, mcause, sepc, ... -- would be harmless either way).
 *
 * FAIL, NOT HANG: every case runs armed (TRAP_ARM in harness.inc); the
 * privilege cases through SM_RUN, with an ECALL after the access as the
 * backstop. Without S-mode, sstatus/sie/sip/... don't exist: the view
 * cases trap in M-mode (armed) and FAIL.
 *
 * ASSUMPTIONS: S-mode and U-mode; PMP and satp as for priv/smode.S;
 * menvcfg exists (priv/1.12). mie = 0 on entry.
 *
 * Bit independence across fields: nothing new -- the CSR instructions'
 * bitx cases are in the Zicsr suite; the csr field is what this file
 * walks, one fixed value per case.
 *
 * Built unchanged for both widths.
 * ===================================================================== */

    .include "xlen.inc"
    .include "harness.inc"
    .include "priv/smode.inc"

    .option norvc            /* mandatory, not stylistic -- see i/loads.S */

    .global tests_priv_scsr

    /* mstatus's M-mode-only fields (MIE and MPP included) */
    .equ SC_MFIELDS, (MSTATUS_MIE | MSTATUS_MPIE | MSTATUS_MPP | MSTATUS_MPRV | MSTATUS_TW | MSTATUS_TVM | MSTATUS_TSR)
    .equ SC_MIRQS,   (MIP_MSIP | MIP_MTIP | MIP_MEIP)

    .section .text

/* =======================================================================
 *  Shared macros
 * ======================================================================= */

/* T_SC_R mode, csr -- the read, CSRRS rd, csr, x0, in mode must be
 * illegal. */
.macro T_SC_R mode, csr
    T_SM_ILL -, \mode, 1, "CSRRS rd, \csr, x0", csrrs a3, \csr, x0
.endm

/* SC_CAPTURE csr -- a4 = csr (read in M-mode, armed; 0 if it traps). */
.macro SC_CAPTURE csr
    li      a4, 0
    TRAP_ARM .Lsc_cap\@
    csrr    a4, \csr
    TRAP_DISARM
.Lsc_cap\@:
.endm

/* T_SC_W mode, csr -- the write of the value already there (SC_CAPTURE
 * first), CSRRW rd, csr, rs1, in mode must be illegal. */
.macro T_SC_W mode, csr
    T_SM_ILL "SC_CAPTURE \csr", \mode, 1, "CSRRW rd, \csr, rs1 (same value)", csrrw a3, \csr, a4
.endm

/* T_SC_S_OK csr -- the read of an S-mode CSR in S-mode doesn't trap. */
.macro T_SC_S_OK csr
    T_SM_OK -, S, "CSRRS rd, \csr, x0", csrrs a3, \csr, x0
.endm

/* =======================================================================
 *  Entry point
 * ======================================================================= */
tests_priv_scsr:
    addi    sp, sp, -64
    REG_S   ra, 0(sp)
    REG_S   s2, 8(sp)
    REG_S   s3, 16(sp)
    REG_S   s4, 24(sp)
    REG_S   s5, 32(sp)
    REG_S   s8, 40(sp)

    csrci   mstatus, MSTATUS_MIE
    csrw    mie, zero
    SM_SETUP
    jal     ra, sm_clean

    jal     ra, test_sc_sstatus
    jal     ra, test_sc_sie
    jal     ra, test_sc_sip
    jal     ra, test_sc_s_from_u
    jal     ra, test_sc_s_from_s
    jal     ra, test_sc_m_from_s

    jal     ra, sm_clean
    REG_L   ra, 0(sp)
    REG_L   s2, 8(sp)
    REG_L   s3, 16(sp)
    REG_L   s4, 24(sp)
    REG_L   s5, 32(sp)
    REG_L   s8, 40(sp)
    addi    sp, sp, 64
    ret

/* =======================================================================
 *  The views. Each case: TEST_BEGIN, s4 = -1, the CSR accesses armed
 *  (resume at local label 7) leaving the result in s4, check,
 *  sm_clean.
 * ======================================================================= */
test_sc_sstatus:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    /* --- mstatus -> sstatus --- */
    TEST_BEGIN str_sc_ss_m2s
    li      s4, -1
    TRAP_ARM 7f
    li      t0, SM_SSTATUS_CLR
    csrs    mstatus, t0
    csrr    s4, sstatus
    and     s4, s4, t0
    TRAP_DISARM
7:  SM_CHK  str_sc_ss_m2s, SM_SSTATUS_CLR, s4
    jal     ra, sm_clean

    /* --- sstatus -> mstatus --- */
    TEST_BEGIN str_sc_ss_s2m
    li      s4, -1
    TRAP_ARM 7f
    li      t0, SM_SSTATUS_CLR
    csrc    mstatus, t0
    csrs    sstatus, t0
    csrr    s4, mstatus
    and     s4, s4, t0
    TRAP_DISARM
7:  SM_CHK  str_sc_ss_s2m, SM_SSTATUS_CLR, s4
    jal     ra, sm_clean

    /* --- the M-mode fields don't show in sstatus (MPRV with MPP = M
     *     leaves M-mode's own accesses alone) --- */
    TEST_BEGIN str_sc_ss_hide
    li      s4, -1
    TRAP_ARM 7f
    LIX     t0, (SC_MFIELDS & ~MSTATUS_MIE)
    csrs    mstatus, t0
    csrr    s4, sstatus
    LIX     t0, SC_MFIELDS
    and     s4, s4, t0
    TRAP_DISARM
7:  SM_CHK  str_sc_ss_hide, 0, s4
    jal     ra, sm_clean

    /* --- writing all ones to sstatus leaves them alone --- */
    TEST_BEGIN str_sc_ss_wr
    li      s4, -1
    csrr    s5, mstatus
    TRAP_ARM 7f
    LIX     t0, SC_MFIELDS
    csrc    mstatus, t0
    li      t0, -1
    csrw    sstatus, t0
    csrr    s4, mstatus
    LIX     t0, SC_MFIELDS
    and     s4, s4, t0
    TRAP_DISARM
7:  csrw    mstatus, s5             /* everything back as it was */
    SM_CHK  str_sc_ss_wr, 0, s4
    jal     ra, sm_clean

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* SC_ID v -- mideleg = v. Clobbers t0. (Armed by the caller.) */
.macro SC_ID v
    li      t0, \v
    csrw    mideleg, t0
.endm

test_sc_sie:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    /* --- SSIE not delegated: reads 0 --- */
    TEST_BEGIN str_sc_sie_nd
    li      s4, -1
    TRAP_ARM 7f
    SC_ID   0
    li      t0, MIP_SSIP
    csrw    mie, t0
    csrr    s4, sie
    andi    s4, s4, MIP_SSIP
    TRAP_DISARM
7:  SM_CHK  str_sc_sie_nd, 0, s4
    jal     ra, sm_clean

    /* --- delegated: mirrors mie.SSIE --- */
    TEST_BEGIN str_sc_sie_d
    li      s4, -1
    TRAP_ARM 7f
    SC_ID   MIP_SSIP
    li      t0, MIP_SSIP
    csrw    mie, t0
    csrr    s4, sie
    andi    s4, s4, MIP_SSIP
    TRAP_DISARM
7:  SM_CHK  str_sc_sie_d, MIP_SSIP, s4
    jal     ra, sm_clean

    /* --- the M-level enables never show (MIE = 0: nothing taken) --- */
    TEST_BEGIN str_sc_sie_m
    li      s4, -1
    TRAP_ARM 7f
    SC_ID   -1
    li      t0, SC_MIRQS
    csrw    mie, t0
    csrr    s4, sie
    and     s4, s4, t0
    TRAP_DISARM
7:  csrw    mie, zero
    SM_CHK  str_sc_sie_m, 0, s4
    jal     ra, sm_clean

    /* --- setting sie.SSIE sets mie.SSIE only when delegated --- */
    TEST_BEGIN str_sc_sie_wd
    li      s4, -1
    TRAP_ARM 7f
    SC_ID   MIP_SSIP
    csrw    mie, zero
    csrsi   sie, MIP_SSIP
    csrr    s4, mie
    andi    s4, s4, MIP_SSIP
    TRAP_DISARM
7:  SM_CHK  str_sc_sie_wd, MIP_SSIP, s4
    jal     ra, sm_clean

    TEST_BEGIN str_sc_sie_wnd
    li      s4, -1
    TRAP_ARM 7f
    SC_ID   0
    csrw    mie, zero
    csrsi   sie, MIP_SSIP
    csrr    s4, mie
    andi    s4, s4, MIP_SSIP
    TRAP_DISARM
7:  SM_CHK  str_sc_sie_wnd, 0, s4
    jal     ra, sm_clean

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

test_sc_sip:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    /* --- SSIP not delegated: reads 0 --- */
    TEST_BEGIN str_sc_sip_nd
    li      s4, -1
    TRAP_ARM 7f
    SC_ID   0
    csrsi   mip, MIP_SSIP
    csrr    s4, sip
    andi    s4, s4, MIP_SSIP
    TRAP_DISARM
7:  SM_CHK  str_sc_sip_nd, 0, s4
    jal     ra, sm_clean

    /* --- delegated: mirrors mip.SSIP --- */
    TEST_BEGIN str_sc_sip_d
    li      s4, -1
    TRAP_ARM 7f
    SC_ID   MIP_SSIP
    csrsi   mip, MIP_SSIP
    csrr    s4, sip
    andi    s4, s4, MIP_SSIP
    TRAP_DISARM
7:  SM_CHK  str_sc_sip_d, MIP_SSIP, s4
    jal     ra, sm_clean

    /* --- STIP, delegated: mirrors mip.STIP --- */
    TEST_BEGIN str_sc_sip_st
    li      s4, -1
    TRAP_ARM 7f
    SC_ID   MIP_STIP
    li      t0, MIP_STIP
    csrs    mip, t0
    csrr    s4, sip
    andi    s4, s4, MIP_STIP
    TRAP_DISARM
7:  SM_CHK  str_sc_sip_st, MIP_STIP, s4
    jal     ra, sm_clean

    /* --- clearing sip.SSIP clears mip.SSIP when delegated --- */
    TEST_BEGIN str_sc_sip_clr
    li      s4, -1
    TRAP_ARM 7f
    SC_ID   MIP_SSIP
    csrsi   mip, MIP_SSIP
    csrci   sip, MIP_SSIP
    csrr    s4, mip
    andi    s4, s4, MIP_SSIP
    TRAP_DISARM
7:  SM_CHK  str_sc_sip_clr, 0, s4
    jal     ra, sm_clean

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  Privilege
 * ======================================================================= */
test_sc_s_from_u:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    .irp    csr, sstatus, sie, stvec, sscratch, sepc, scause, stval, sip, satp, scounteren
    T_SC_R  U, \csr
    T_SC_W  U, \csr
    .endr
    SM_SETUP                        /* stvec, satp as they must be */
    jal     ra, sm_clean

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

test_sc_s_from_s:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    .irp    csr, sstatus, sie, stvec, sscratch, sepc, scause, stval, sip, satp, scounteren
    T_SC_S_OK \csr
    .endr
    jal     ra, sm_clean

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

test_sc_m_from_s:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    .irp    csr, mstatus, misa, medeleg, mideleg, mie, mtvec, mcounteren, menvcfg, mscratch, mepc, mcause, mtval, mip
    T_SC_R  S, \csr
    T_SC_W  S, \csr
    .endr
    T_SC_R  S, mhartid
    jal     ra, sm_clean

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

    SM_HANDLER_CODE

/* =======================================================================
 *  Strings
 * ======================================================================= */
    .section .rodata
str_sc_ss_m2s:  .asciz "CSRRS sstatus reads SIE/SPIE/SPP set through mstatus"
str_sc_ss_s2m:  .asciz "CSRRS sstatus sets SIE/SPIE/SPP in mstatus"
str_sc_ss_hide: .asciz "CSRRS sstatus reads 0 in mstatus's M-mode fields (MPIE, MPP, MPRV, TW, TVM, TSR set)"
str_sc_ss_wr:   .asciz "CSRRW sstatus all ones leaves mstatus's M-mode fields (MIE, MPIE, MPP, MPRV, TW, TVM, TSR) 0"
str_sc_sie_nd:  .asciz "CSRRS sie reads SSIE 0 when SSI is not delegated (mie.SSIE=1)"
str_sc_sie_d:   .asciz "CSRRS sie reads SSIE == mie.SSIE when SSI is delegated"
str_sc_sie_m:   .asciz "CSRRS sie reads MSIE/MTIE/MEIE 0 (mie has them, mideleg all ones)"
str_sc_sie_wd:  .asciz "CSRRSI sie SSIE sets mie.SSIE when SSI is delegated"
str_sc_sie_wnd: .asciz "CSRRSI sie SSIE leaves mie.SSIE 0 when SSI is not delegated"
str_sc_sip_nd:  .asciz "CSRRS sip reads SSIP 0 when SSI is not delegated (mip.SSIP=1)"
str_sc_sip_d:   .asciz "CSRRS sip reads SSIP == mip.SSIP when SSI is delegated"
str_sc_sip_st:  .asciz "CSRRS sip reads STIP == mip.STIP when STI is delegated"
str_sc_sip_clr: .asciz "CSRRCI sip SSIP clears mip.SSIP when SSI is delegated"
