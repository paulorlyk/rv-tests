/* =====================================================================
 * priv/sret.S  --  SRET (supervisor-mode trap return)
 *
 * Part of the privileged-architecture suite; see priv/tests.S for how
 * this plugs into the rest (main_tests.S -> priv/tests.S -> here), and
 * common.S for the boot/UART/reporting harness everything sits on
 * ("check", "test_begin" and the armed trap mode -- trap_resume/
 * trap_count/trap_mcause/... -- are used from there). The S-mode
 * machinery (SM_* macros, sm_clean) is in priv/smode.inc.
 *
 * SRET is MRET's S-mode twin: pc <- sepc, privilege <- sstatus.SPP
 * (1 = S, 0 = U), and the S-mode interrupt-enable stack pops (SIE <-
 * SPIE, SPIE <- 1, SPP <- U); an SRET to a mode below M also clears
 * MPRV. It is legal in M-mode and in S-mode (unless mstatus.TSR = 1),
 * illegal in U-mode. Every SRET here is executed by test code with
 * sepc and sstatus set up by hand. What is checked:
 *   - from M-mode with SPP = 1: it lands on sepc (not on the
 *     instruction after it), in S-mode (the ECALL there is cause 9),
 *     and sepc is unchanged afterwards (read back in S-mode);
 *   - from M-mode with SPP = 0: it drops to U-mode (an sscratch read
 *     there traps, mcause 2, MPP = 0);
 *   - SIE <- SPIE both ways (SPIE = 1 / SIE = 0 -> SIE = 1, SPIE = 0 /
 *     SIE = 1 -> SIE = 0), SPIE = 1 and SPP = 0 afterwards: read from
 *     mstatus on the trap entry of an ECALL made in S-mode afterwards
 *     (a trap into M-mode leaves SIE/SPIE/SPP alone, see
 *     priv/smode.S). SIE = 1 in S-mode is harmless: mie = 0;
 *   - from S-mode: SPP = 1 stays in S-mode, SPP = 0 goes to U-mode,
 *     both at sepc (an mscratch read there traps with MPP = 1 or 0,
 *     mepc on the read);
 *   - with mstatus.TSR = 1, SRET in S-mode is illegal (mcause 2, mepc
 *     on the SRET, MPP = 1); in M-mode it still works;
 *   - SRET in U-mode is illegal (mcause 2, mepc on the SRET, MPP = 0);
 *   - SRET into S-mode clears MPRV.
 *
 * FAIL, NOT HANG: every case runs armed (TRAP_ARM in harness.inc) and
 * ends in an ECALL or an M-mode CSR read, whatever mode it ends up in.
 * The two cases where SRET must trap point sepc at an escape ECALL
 * first, so an SRET that wrongly works jumps there (the wrong mcause
 * and mepc: FAILs) instead of back into itself.
 *
 * ASSUMPTIONS: S-mode and U-mode are implemented; PMP and satp as for
 * priv/smode.S. mie = 0 on entry. Without S-mode (SRET is then
 * illegal everywhere) the checks FAIL; they don't hang.
 *
 * Bit independence across fields: SRET has a single fixed encoding (no
 * variable field), so C(0,2) = 0 cases.
 *
 * Built unchanged for both widths.
 * ===================================================================== */

    .include "xlen.inc"
    .include "harness.inc"
    .include "priv/smode.inc"

    .option norvc            /* mandatory, not stylistic -- see i/loads.S */

    .global tests_priv_sret

    .section .text

/* SR_SSTACK bits -- sstatus SIE/SPIE/SPP = bits (the others as they
 * were). Clobbers t0. */
.macro SR_SSTACK bits
    li      t0, SM_SSTATUS_CLR
    csrc    sstatus, t0
    .if \bits
    li      t0, \bits
    csrs    sstatus, t0
    .endif
.endm

/* SR_SEPC label -- sepc = label. Clobbers t0. */
.macro SR_SEPC label
    .option push
    .option norelax
    la      t0, \label
    .option pop
    csrw    sepc, t0
.endm

/* =======================================================================
 *  Entry point
 * ======================================================================= */
tests_priv_sret:
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

    jal     ra, test_sr_from_m
    jal     ra, test_sr_stack
    jal     ra, test_sr_from_s
    jal     ra, test_sr_illegal
    jal     ra, test_sr_mprv

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
 *  From M-mode: the jump, S-mode with SPP = 1, U-mode with SPP = 0
 * ======================================================================= */

/* T_SR_JUMP tsr, s_land, s_cause, s_mpp, s_sepc -- SRET from M-mode with
 * SPP = 1 (and mstatus.TSR = tsr, which must not matter in M-mode):
 * s4 = 1 at sepc, 2 if it fell through; s5 = sepc read in S-mode. With
 * s_sepc empty, only the landing and the cause are checked. */
.macro T_SR_JUMP tsr, s_land, s_cause, s_mpp, s_sepc
    TEST_BEGIN \s_land
    li      s4, 0
    li      s5, 0
    .option push
    .option norelax
    la      s2, .Lsr_j_target\@
    .option pop
    TRAP_ARM .Lsr_j_back\@
    .if \tsr
    li      t0, MSTATUS_TSR
    csrs    mstatus, t0
    .endif
    csrw    sepc, s2
    SR_SSTACK MSTATUS_SPP
    sret
    li      s4, 2                   /* fell through, still in M-mode */
    ecall
.Lsr_j_target\@:
    li      s4, 1
    csrr    s5, sepc                /* S-mode: legal */
    ecall
.Lsr_j_back\@:
    TRAP_DISARM
    li      t0, MSTATUS_TSR
    csrc    mstatus, t0
    SM_CHK  \s_land, 1, s4
    TEST_BEGIN \s_cause
    TRAP_LD t2, mcause
    SM_CHK  \s_cause, 9, t2
    .ifnb \s_mpp
    TEST_BEGIN \s_mpp
    TRAP_LD t2, mstatus
    SM_FIELD t2, t2, 11, 3
    SM_CHK  \s_mpp, 1, t2
    .endif
    .ifnb \s_sepc
    TEST_BEGIN \s_sepc
    SM_CHKR \s_sepc, s2, s5
    .endif
    jal     ra, sm_clean
.endm

test_sr_from_m:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    T_SR_JUMP 0, str_sr_m_land, str_sr_m_cause, str_sr_m_mpp, str_sr_m_sepc

    /* --- SPP = 0: U-mode, where an sscratch read traps --- */
    TEST_BEGIN str_sr_mu_cause
    .option push
    .option norelax
    la      s2, .Lsr_mu_u
    .option pop
    TRAP_ARM .Lsr_mu_back
    csrw    sepc, s2
    SR_SSTACK 0
    sret
    ecall                           /* fell through: M-mode, cause 11 */
.Lsr_mu_u:
    csrr    t0, sscratch            /* U-mode: illegal */
    ecall                           /* backstop */
.Lsr_mu_back:
    TRAP_DISARM
    TRAP_LD t2, mcause
    SM_CHK  str_sr_mu_cause, 2, t2
    TEST_BEGIN str_sr_mu_mepc
    TRAP_LD t2, mepc
    SM_CHKR str_sr_mu_mepc, s2, t2
    TEST_BEGIN str_sr_mu_mpp
    TRAP_LD t2, mstatus
    SM_FIELD t2, t2, 11, 3
    SM_CHK  str_sr_mu_mpp, 0, t2
    jal     ra, sm_clean

    /* --- TSR = 1 changes nothing in M-mode --- */
    T_SR_JUMP 1, str_sr_tsr_m_land, str_sr_tsr_m_cause

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  The S-mode interrupt-enable stack
 * ======================================================================= */

/* T_SR_STACK before, sie, s_sie, s_spie, s_spp -- SRET from M-mode into
 * S-mode with SIE/SPIE/SPP = before (SPP always 1), ECALL there; check
 * SIE == sie, SPIE == 1, SPP == 0 on the trap's entry. */
.macro T_SR_STACK before, sie, s_sie, s_spie, s_spp
    TEST_BEGIN \s_sie
    .option push
    .option norelax
    la      s2, .Lsr_st_s\@
    .option pop
    TRAP_ARM .Lsr_st_back\@
    csrw    sepc, s2
    SR_SSTACK \before
    sret
    ecall
.Lsr_st_s\@:
    ecall                           /* S-mode */
.Lsr_st_back\@:
    TRAP_DISARM
    TRAP_LD t2, mstatus
    SM_FIELD t2, t2, 1, 1
    SM_CHK  \s_sie, \sie, t2
    TEST_BEGIN \s_spie
    TRAP_LD t2, mstatus
    SM_FIELD t2, t2, 5, 1
    SM_CHK  \s_spie, 1, t2
    TEST_BEGIN \s_spp
    TRAP_LD t2, mstatus
    SM_FIELD t2, t2, 8, 1
    SM_CHK  \s_spp, 0, t2
    jal     ra, sm_clean
.endm

test_sr_stack:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    T_SR_STACK (MSTATUS_SPIE | MSTATUS_SPP), 1, str_sr_s1_sie, str_sr_s1_spie, str_sr_s1_spp
    T_SR_STACK (MSTATUS_SIE | MSTATUS_SPP),  0, str_sr_s0_sie, str_sr_s0_spie, str_sr_s0_spp

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  From S-mode: SPP = 1 stays in S-mode, SPP = 0 goes to U-mode
 * ======================================================================= */

/* T_SR_FROM_S spp, s_cause, s_mepc, s_mpp -- enter S-mode (MRET), set
 * sepc/SPP there and SRET; at sepc an mscratch read traps, with MPP =
 * spp. */
.macro T_SR_FROM_S spp, s_cause, s_mepc, s_mpp
    TEST_BEGIN \s_cause
    .option push
    .option norelax
    la      s2, .Lsr_fs_s\@
    la      s7, .Lsr_fs_probe\@
    .option pop
    TRAP_ARM .Lsr_fs_back\@
    SM_TO_S s2
.Lsr_fs_s\@:                        /* S-mode */
    csrw    sepc, s7
    .if \spp
    SR_SSTACK MSTATUS_SPP
    .else
    SR_SSTACK 0
    .endif
    sret
    ecall                           /* fell through */
.Lsr_fs_probe\@:
    csrr    t0, mscratch            /* illegal in S- and U-mode */
    ecall
.Lsr_fs_back\@:
    TRAP_DISARM
    TRAP_LD t2, mcause
    SM_CHK  \s_cause, 2, t2
    TEST_BEGIN \s_mepc
    TRAP_LD t2, mepc
    SM_CHKR \s_mepc, s7, t2
    TEST_BEGIN \s_mpp
    TRAP_LD t2, mstatus
    SM_FIELD t2, t2, 11, 3
    SM_CHK  \s_mpp, \spp, t2
    jal     ra, sm_clean
.endm

test_sr_from_s:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    T_SR_FROM_S 1, str_sr_ss_cause, str_sr_ss_mepc, str_sr_ss_mpp
    T_SR_FROM_S 0, str_sr_su_cause, str_sr_su_mepc, str_sr_su_mpp

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  Illegal: in S-mode with TSR = 1, and in U-mode
 * ======================================================================= */

/* SR_ESCAPE tsr -- the setup of the two: sepc = the escape ECALL and SPP
 * = 1, so an SRET that wrongly works lands there (armed: sepc/sstatus
 * don't exist without S-mode); mstatus.TSR = tsr. Clobbers t0. */
.macro SR_ESCAPE tsr
    TRAP_ARM .Lsr_esc\@
    SR_SEPC sr_escape
    SR_SSTACK MSTATUS_SPP
    TRAP_DISARM
.Lsr_esc\@:
    .if \tsr
    li      t0, MSTATUS_TSR
    csrs    mstatus, t0
    .endif
.endm

test_sr_illegal:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    T_SM_ILL "SR_ESCAPE 1", S, 0, "SRET with mstatus.TSR=1", sret
    li      t0, MSTATUS_TSR
    csrc    mstatus, t0
    T_SM_ILL "SR_ESCAPE 0", U, 0, "SRET", sret
    jal     ra, sm_clean

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

sr_escape:
    ecall                           /* an SRET that wrongly worked */

/* =======================================================================
 *  SRET into S-mode clears MPRV
 * ======================================================================= */
test_sr_mprv:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    /* MPRV = 1 with MPP = M: M-mode's own loads/stores are unaffected */
    TEST_BEGIN str_sr_mprv
    .option push
    .option norelax
    la      s2, .Lsr_mprv_s
    .option pop
    TRAP_ARM .Lsr_mprv_back
    csrw    sepc, s2
    SR_SSTACK MSTATUS_SPP
    li      t0, MSTATUS_MPP | MSTATUS_MPRV
    csrs    mstatus, t0
    sret
    ecall
.Lsr_mprv_s:
    ecall                           /* S-mode */
.Lsr_mprv_back:
    li      t0, MSTATUS_MPRV
    csrc    mstatus, t0
    TRAP_DISARM
    TRAP_LD t2, mstatus
    SM_FIELD t2, t2, 17, 1
    SM_CHK  str_sr_mprv, 0, t2
    jal     ra, sm_clean

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

    SM_HANDLER_CODE

/* =======================================================================
 *  Strings
 * ======================================================================= */
    .section .rodata
str_sr_m_land:      .asciz "SRET in M-mode with SPP=1 lands on sepc"
str_sr_m_cause:     .asciz "SRET in M-mode with SPP=1 enters S-mode (the ECALL there is cause 9)"
str_sr_m_mpp:       .asciz "SRET in M-mode with SPP=1: the ECALL in S-mode has MPP == 1"
str_sr_m_sepc:      .asciz "SRET in M-mode with SPP=1 leaves sepc unchanged"
str_sr_mu_cause:    .asciz "SRET in M-mode with SPP=0 enters U-mode: sscratch read there, mcause == 2"
str_sr_mu_mepc:     .asciz "SRET in M-mode with SPP=0 enters U-mode: mepc == the read (lands on sepc)"
str_sr_mu_mpp:      .asciz "SRET in M-mode with SPP=0 enters U-mode: trap entry MPP == 0 (U)"
str_sr_tsr_m_land:  .asciz "SRET in M-mode with TSR=1 lands on sepc (TSR only affects S-mode)"
str_sr_tsr_m_cause: .asciz "SRET in M-mode with TSR=1 enters S-mode (the ECALL there is cause 9)"
str_sr_s1_sie:      .asciz "SRET with SPIE=1 SIE=0: SIE == 1 afterwards"
str_sr_s1_spie:     .asciz "SRET with SPIE=1 SIE=0: SPIE == 1 afterwards"
str_sr_s1_spp:      .asciz "SRET with SPIE=1 SIE=0: SPP == 0 (U) afterwards"
str_sr_s0_sie:      .asciz "SRET with SPIE=0 SIE=1: SIE == 0 afterwards"
str_sr_s0_spie:     .asciz "SRET with SPIE=0 SIE=1: SPIE == 1 afterwards"
str_sr_s0_spp:      .asciz "SRET with SPIE=0 SIE=1: SPP == 0 (U) afterwards"
str_sr_ss_cause:    .asciz "SRET in S-mode with SPP=1 stays in S-mode: mscratch read at sepc, mcause == 2"
str_sr_ss_mepc:     .asciz "SRET in S-mode with SPP=1 stays in S-mode: mepc == the read (lands on sepc)"
str_sr_ss_mpp:      .asciz "SRET in S-mode with SPP=1 stays in S-mode: trap entry MPP == 1 (S)"
str_sr_su_cause:    .asciz "SRET in S-mode with SPP=0 enters U-mode: mscratch read at sepc, mcause == 2"
str_sr_su_mepc:     .asciz "SRET in S-mode with SPP=0 enters U-mode: mepc == the read (lands on sepc)"
str_sr_su_mpp:      .asciz "SRET in S-mode with SPP=0 enters U-mode: trap entry MPP == 0 (U)"
str_sr_mprv:        .asciz "SRET with SPP=1 (S) clears MPRV"
