/* =====================================================================
 * priv/swfi.S  --  WFI below M-mode on a hart with S-mode: mstatus.TW
 *                  in S-mode, and WFI in U-mode with TW = 0
 *
 * Part of the privileged-architecture suite; see priv/tests.S for how
 * this plugs into the rest (main_tests.S -> priv/tests.S -> here), and
 * common.S for the boot/UART/reporting harness everything sits on
 * ("check", "test_begin" and the armed trap mode -- trap_resume/
 * trap_count/trap_mcause/... -- are used from there). The SM_* and
 * T_SM_* macros are in priv/smode.inc.
 *
 * mstatus.TW = 1 traps WFI below M-mode (priv/wfi.S checks that in
 * U-mode). What is checked:
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
 * The cases arm the machine timer WFI_DELAY ticks ahead (mie.MTIE,
 * not delegatable), so a WFI that waits when it should trap, or waits
 * forever, is ended by an M-mode timer interrupt: the wrong mcause, a
 * FAIL, not a hang.
 *
 * Virtual-memory management (SFENCE.VMA, satp, mstatus.TVM) is not
 * tested for now.
 *
 * FAIL, NOT HANG: every case runs armed (TRAP_ARM in harness.inc),
 * through SM_RUN with an ECALL after the instruction.
 *
 * ASSUMPTIONS: S-mode and U-mode; PMP and satp as for priv/smode.S; a
 * CLINT/ACLINT at CLINT_BASE as for priv/wfi.S (mtimecmp at +0x4000,
 * mtime at +0xbff8), whose timer takes much longer than a few
 * instructions to count WFI_DELAY ticks. mie = 0 on entry and exit,
 * mtimecmp all ones on exit.
 *
 * WFI has a single fixed encoding, so there are no bitx cases.
 *
 * Built for both widths; on RV32 mtime/mtimecmp are two 32-bit halves.
 * ===================================================================== */

    .include "xlen.inc"
    .include "harness.inc"
    .include "priv/smode.inc"

    .option norvc            /* mandatory, not stylistic -- see i/loads.S */

    .global tests_priv_swfi

    .equ CLINT_BASE,     0x02000000
    .equ CLINT_MTIMECMP, CLINT_BASE + 0x4000   /* hart 0 */
    .equ CLINT_MTIME,    CLINT_BASE + 0xbff8
    .equ WFI_DELAY,      10000                 /* timer ticks */

    .section .text

/* =======================================================================
 *  Setup hooks for T_SM_ILL / T_SM_OK (SM_PRE); each clobbers t0
 * ======================================================================= */

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
tests_priv_swfi:
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

    jal     ra, test_sf_wfi

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

    SM_HANDLER_CODE

