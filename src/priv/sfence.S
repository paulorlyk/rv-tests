/* =====================================================================
 * priv/sfence.S  --  SFENCE.VMA, and the mstatus bits that trap S-mode
 *                    operations: TVM (satp, SFENCE.VMA) and TW (WFI)
 *
 * Part of the privileged-architecture suite; see priv/tests.S for how
 * this plugs into the rest (main_tests.S -> priv/tests.S -> here), and
 * common.S for the boot/UART/reporting harness everything sits on
 * ("check", "test_begin" and the armed trap mode -- trap_resume/
 * trap_count/trap_mcause/... -- are used from there). The SM_* and
 * T_SM_* macros are in priv/smode.inc.
 *
 * SFENCE.VMA orders stores to the page tables before later address
 * translation; with satp = 0 (Bare) there is nothing to translate, so
 * what a test can pin down is who may execute it and that it does
 * nothing else. mstatus.TVM = 1 lets M-mode trap S-mode's attempts at
 * virtual-memory management (satp and SFENCE.VMA), and mstatus.TW = 1
 * traps WFI below M-mode (priv/wfi.S checks that in U-mode). What is
 * checked:
 *   - SFENCE.VMA x0, x0 and SFENCE.VMA a0, a1 in M-mode don't trap;
 *   - in S-mode with TVM = 0 it doesn't trap; with TVM = 1 it is
 *     illegal (T_SM_ILL: one trap, into M-mode, mcause 2, mepc on it,
 *     MPP = 1); in U-mode it is illegal;
 *   - satp in S-mode with TVM = 1: a read and a write (of 0, Bare) are
 *     illegal (rd not written); with TVM = 0 the write doesn't trap;
 *     TVM = 1 doesn't affect other S-mode CSRs (an sscratch read
 *     doesn't trap), nor M-mode (a satp read doesn't trap);
 *   - WFI in S-mode with TW = 1 and nothing pending is illegal (MPP =
 *     1); with TW = 0 and a delegated supervisor software interrupt
 *     pending and enabled in sie but SIE = 0, WFI completes (an enabled
 *     pending interrupt ends the wait whatever SIE says) and nothing is
 *     taken;
 *   - WFI in U-mode with TW = 0, on a hart with S-mode, nothing pending,
 *     is illegal (MPP = 0). The spec lets a WFI that completes within
 *     an implementation-defined bounded time not trap; with nothing
 *     pending it can only complete by being a NOP, so this pins down
 *     the usual (and QEMU's) behaviour, as priv/wfi.S's TW = 1 case
 *     does.
 * The WFI cases arm the machine timer WFI_DELAY ticks ahead (mie.MTIE,
 * not delegatable), so a WFI that waits when it should trap, or waits
 * forever, is ended by an M-mode timer interrupt: the wrong mcause, a
 * FAIL, not a hang.
 *
 * FAIL, NOT HANG: every case runs armed (TRAP_ARM in harness.inc), the
 * S-/U-mode ones through SM_RUN with an ECALL after the instruction.
 * SFENCE.VMA itself may be unimplemented (no S-mode): it runs armed in
 * M-mode too, and the bitx cases use BX_TRAP_FAILS.
 *
 * ASSUMPTIONS: S-mode and U-mode; PMP and satp as for priv/smode.S; a
 * CLINT/ACLINT at CLINT_BASE as for priv/wfi.S (mtimecmp at +0x4000,
 * mtime at +0xbff8), whose timer takes much longer than a few
 * instructions to count WFI_DELAY ticks. mie = 0 on entry and exit,
 * mtimecmp all ones on exit.
 *
 * Bit independence across fields (bitx_sfence, at the end): SFENCE.VMA
 * has two variable fields, rs1 and rs2 (rd and the funct fields are
 * fixed), so C(10,2) = 45 cases, each run in M-mode (legal there
 * whatever TVM says) with the background x0 for the field not
 * involved. rs1 and rs2 are loaded with the sentinel first; the check
 * is that the instruction doesn't trap and leaves them unchanged: t6
 * = x[rs1] + x[rs2] against the sentinel times the number of nonzero
 * fields. See BX_C_SF and bitx.inc.
 *
 * Built for both widths; on RV32 mtime/mtimecmp are two 32-bit halves.
 * ===================================================================== */

    .include "xlen.inc"
    .include "harness.inc"
    .include "bitx.inc"
    .include "priv/smode.inc"

    .option norvc            /* mandatory, not stylistic -- see i/loads.S */

    .global tests_priv_sfence

    .equ CLINT_BASE,     0x02000000
    .equ CLINT_MTIMECMP, CLINT_BASE + 0x4000   /* hart 0 */
    .equ CLINT_MTIME,    CLINT_BASE + 0xbff8
    .equ WFI_DELAY,      10000                 /* timer ticks */

    .section .text

/* =======================================================================
 *  Setup hooks for T_SM_ILL / T_SM_OK (SM_PRE); each clobbers t0
 * ======================================================================= */

/* SF_TVM -- mstatus.TVM = 1. */
.macro SF_TVM
    li      t0, MSTATUS_TVM
    csrs    mstatus, t0
.endm

/* SF_A4 tvm -- a4 = 0 (the Bare satp), and mstatus.TVM = tvm. */
.macro SF_A4 tvm
    li      a4, 0
    .if \tvm
    SF_TVM
    .endif
.endm

/* SF_WFI_TW tw -- the machine timer WFI_DELAY ticks ahead, enabled in
 * mie (the backstop, see the file header); mstatus.TW = tw. Clobbers
 * t0-t3. */
.macro SF_WFI_TW tw
    jal     ra, sf_timer_soon
    li      t0, MIE_MTIE
    csrw    mie, t0
    .if \tw
    li      t0, MSTATUS_TW
    csrs    mstatus, t0
    .endif
.endm

/* SF_WFI_SSI -- SF_WFI_TW 0, and a supervisor software interrupt
 * delegated (armed), pending and enabled in mie; SIE stays 0. */
.macro SF_WFI_SSI
    SF_WFI_TW 0
    TRAP_ARM .Lsf_ssi\@
    li      t0, MIP_SSIP
    csrw    mideleg, t0
    TRAP_DISARM
.Lsf_ssi\@:
    li      t0, MIE_MTIE | MIP_SSIP
    csrw    mie, t0
    csrsi   mip, MIP_SSIP
.endm

/* =======================================================================
 *  Timer helpers (clobber t0-t3), as in priv/wfi.S
 * ======================================================================= */

/* sf_timer_off: mtimecmp = all ones, so MTIP clears and stays clear. */
sf_timer_off:
    li      t0, CLINT_MTIMECMP
    li      t1, -1
    .if XLEN == 64
    sd      t1, 0(t0)
    .else
    sw      t1, 0(t0)
    sw      t1, 4(t0)
    .endif
    ret

/* sf_timer_soon: mtimecmp = mtime + WFI_DELAY. On RV32 mtime is read
 * hi/lo/hi until the two high halves agree, and mtimecmp is written
 * high = all ones first, so no half-written value is ever in the past. */
sf_timer_soon:
    li      t0, CLINT_MTIME
    .if XLEN == 64
    ld      t1, 0(t0)
    li      t2, WFI_DELAY
    add     t1, t1, t2
    li      t0, CLINT_MTIMECMP
    sd      t1, 0(t0)
    .else
1:  lw      t2, 4(t0)
    lw      t1, 0(t0)
    lw      t3, 4(t0)
    bne     t2, t3, 1b
    li      t3, WFI_DELAY
    add     t3, t1, t3              /* low half */
    sltu    t1, t3, t1              /* carry */
    add     t2, t2, t1              /* high half */
    li      t0, CLINT_MTIMECMP
    li      t1, -1
    sw      t1, 4(t0)
    sw      t3, 0(t0)
    sw      t2, 4(t0)
    .endif
    ret

/* =======================================================================
 *  Entry point
 * ======================================================================= */
tests_priv_sfence:
    addi    sp, sp, -112
    REG_S   ra, 0(sp)
    REG_S   s0, 8(sp)
    REG_S   s1, 16(sp)
    REG_S   s2, 24(sp)
    REG_S   s3, 32(sp)
    REG_S   s4, 40(sp)
    REG_S   s5, 48(sp)
    REG_S   s6, 56(sp)
    REG_S   s7, 64(sp)
    REG_S   s8, 72(sp)
    REG_S   s9, 80(sp)
    REG_S   s10, 88(sp)
    REG_S   s11, 96(sp)

    csrci   mstatus, MSTATUS_MIE
    csrw    mie, zero
    SM_SETUP
    jal     ra, sm_clean

    jal     ra, test_sf_m
    jal     ra, test_sf_su
    jal     ra, test_sf_satp
    jal     ra, test_sf_wfi

    jal     ra, bitx_sfence

    jal     ra, sm_clean
    jal     ra, sf_timer_off
    REG_L   ra, 0(sp)
    REG_L   s0, 8(sp)
    REG_L   s1, 16(sp)
    REG_L   s2, 24(sp)
    REG_L   s3, 32(sp)
    REG_L   s4, 40(sp)
    REG_L   s5, 48(sp)
    REG_L   s6, 56(sp)
    REG_L   s7, 64(sp)
    REG_L   s8, 72(sp)
    REG_L   s9, 80(sp)
    REG_L   s10, 88(sp)
    REG_L   s11, 96(sp)
    addi    sp, sp, 112
    ret

/* =======================================================================
 *  M-mode
 * ======================================================================= */

/* T_SF_M_OK pre, name, insn -- after the setup pre (SM_PRE), insn in
 * M-mode (armed) doesn't trap. */
.macro T_SF_M_OK pre, name, insn:vararg
    TEST_BEGIN \name
    SM_PRE  "\pre"
    SM_COUNT s3
    TRAP_ARM .Lsf_m\@
    \insn
    TRAP_DISARM
.Lsf_m\@:
    SM_COUNT t0
    sub     s3, t0, s3
    SM_CHK  \name, 0, s3
.endm

test_sf_m:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    T_SF_M_OK -, str_sf_m_00, sfence.vma x0, x0
    T_SF_M_OK -, str_sf_m_ab, sfence.vma a0, a1

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  S- and U-mode, TVM
 * ======================================================================= */
test_sf_su:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    T_SM_OK -, S, "SFENCE.VMA with mstatus.TVM=0", sfence.vma x0, x0
    T_SM_ILL SF_TVM, S, 0, "SFENCE.VMA with mstatus.TVM=1", sfence.vma x0, x0
    jal     ra, sm_clean
    T_SM_ILL -, U, 0, "SFENCE.VMA", sfence.vma x0, x0

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

test_sf_satp:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    T_SM_ILL SF_TVM, S, 1, "CSRRS rd, satp, x0 with mstatus.TVM=1", csrrs a3, satp, x0
    jal     ra, sm_clean
    T_SM_ILL "SF_A4 1", S, 1, "CSRRW rd, satp, rs1 (Bare) with mstatus.TVM=1", csrrw a3, satp, a4
    jal     ra, sm_clean
    T_SM_OK "SF_A4 0", S, "CSRRW rd, satp, rs1 (Bare) with mstatus.TVM=0", csrrw a3, satp, a4
    T_SM_OK SF_TVM, S, "CSRRS rd, sscratch, x0 with mstatus.TVM=1", csrrs a3, sscratch, x0
    jal     ra, sm_clean

    T_SF_M_OK SF_TVM, str_sf_satp_m, csrr a3, satp
    jal     ra, sm_clean
    SM_SETUP                        /* satp = 0 again, whatever happened */

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  WFI in S-mode (TW) and U-mode
 * ======================================================================= */
test_sf_wfi:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    T_SM_ILL "SF_WFI_TW 1", S, 0, "WFI with mstatus.TW=1, nothing pending", wfi
    jal     ra, sm_clean
    jal     ra, sf_timer_off

    T_SM_OK SF_WFI_SSI, S, "WFI with TW=0, a delegated SSI pending and in sie, SIE=0", wfi
    jal     ra, sm_clean
    jal     ra, sf_timer_off

    T_SM_ILL "SF_WFI_TW 0", U, 0, "WFI with TW=0 (S-mode implemented), nothing pending", wfi
    jal     ra, sm_clean
    jal     ra, sf_timer_off

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  Bit independence across fields -- see the file header and bitx.inc
 * ======================================================================= */

/* BX_C_SF nm, rs1, rs2 -- one case: SFENCE.VMA x[rs1], x[rs2] (as .insn
 * r: opcode SYSTEM, funct3 0, funct7 0b0001001, rd x0) in M-mode.
 * Besides the reserved registers of bitx.inc, t4 (disarming) is used;
 * it is never a candidate. */
.macro BX_C_SF nm, rs1, rs2
    BX_NAME .Lbxsf\@, "\nm bitx rs1=x\rs1 rs2=x\rs2"
    BX_ENTER .Lbxsf\@
    TRAP_ARM .Lbxsf_trap\@
    BX_PV   x\rs1, 2
    BX_PV   x\rs2, 2
    .insn   r 0x73, 0, 0x09, x0, x\rs1, x\rs2
    mv      t6, x\rs1
    add     t6, t6, x\rs2
    TRAP_DISARM_R t4
    li      t5, 0
    BX_PV   t4, 2
    .if \rs1 != 0
    add     t5, t5, t4
    .endif
    .if \rs2 != 0
    add     t5, t5, t4
    .endif
    BX_REPORT_AT .Lbxsf\@
    BX_TRAP_FAILS .Lbxsf_trap\@, .Lbxsf\@
.endm

bitx_sfence:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    BX_POOL 0, 0
    BX_E_RR5 BX_C_SF, "SFENCE.VMA", 0, 0

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

    SM_HANDLER_CODE

/* =======================================================================
 *  Strings
 * ======================================================================= */
    .section .rodata
str_sf_m_00:   .asciz "SFENCE.VMA x0, x0 in M-mode: doesn't trap"
str_sf_m_ab:   .asciz "SFENCE.VMA a0, a1 in M-mode: doesn't trap"
str_sf_satp_m: .asciz "CSRRS rd, satp, x0 in M-mode with mstatus.TVM=1: doesn't trap"
