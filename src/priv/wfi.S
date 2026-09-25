/* =====================================================================
 * priv/wfi.S  --  WFI (wait for interrupt)
 *
 * Part of the privileged-architecture suite; see priv/tests.S for how
 * this plugs into the rest (main_tests.S -> priv/tests.S -> here), and
 * common.S for the boot/UART/reporting harness everything sits on
 * ("check", "test_begin" and the armed trap mode -- trap_resume/
 * trap_count/trap_mcause/... -- are used from there).
 *
 * WFI stalls the hart until an interrupt that is enabled in mie is
 * pending, whether or not mstatus.MIE lets it be taken; an
 * implementation may also treat it as a NOP. So the only thing a test
 * can demand is what happens *around* the wait, never how long it
 * lasts. The interrupt used is the machine timer (mip.MTIP, raised by
 * the CLINT when mtime >= mtimecmp). What is checked:
 *   - with the interrupt already pending (mtimecmp = 0) and MIE = 0:
 *     WFI completes, execution goes on at the next instruction, no
 *     trap;
 *   - with the interrupt in the future (mtimecmp = mtime + WFI_DELAY)
 *     and MIE = 0: the canonical "while (!MTIP) wfi;" loop ends with
 *     no trap (it terminates whether WFI waits or is a NOP);
 *   - with MIE = 1: the interrupt is taken -- mcause = interrupt bit |
 *     7, mepc = the instruction after the WFI (where execution would
 *     have resumed; the WFI is followed by a jump-to-self, so a WFI
 *     that doesn't wait gives the same mepc), MIE = 0 / MPIE = 1 / MPP
 *     = M on entry, exactly one trap, and MIE = 1 again after MRET;
 *   - mstatus.TW = 1 doesn't affect M-mode: WFI completes as usual;
 *   - in U-mode with TW = 1 and nothing pending, WFI is illegal
 *     (mcause 2, mepc on the WFI, MPP = 0 on entry). The spec lets a
 *     WFI that completes within an implementation-defined time limit
 *     not trap; with nothing pending it can only complete by being a
 *     NOP, so this pins down the usual (and QEMU's) behaviour. Neither
 *     alternative hangs: a WFI that completes runs into an ECALL, and
 *     one that really waits is woken by a timer interrupt set
 *     WFI_DELAY ticks ahead -- both trap into the armed handler with
 *     the wrong mcause;
 *   - the general registers are unchanged.
 * All run with the handler armed (TRAP_ARM in harness.inc), so an
 * unexpected trap is a FAIL rather than a hang; a WFI that waits
 * forever (the interrupt never arrives) hangs with its test's name as
 * the last line printed.
 *
 * ASSUMPTIONS: a CLINT/ACLINT at CLINT_BASE (QEMU virt: 0x02000000,
 * hart 0's mtimecmp at +0x4000, mtime at +0xbff8) whose timer ticks
 * fast enough that WFI_DELAY ticks pass quickly (QEMU virt: 10 MHz,
 * so 1 ms) but slowly enough that the few instructions between arming
 * the timer and the WFI take less; U-mode and PMP as for the ECALL/
 * EBREAK tests (common.S's reset sets PMP up). mie is zeroed and
 * mtimecmp left at all ones when this file is done.
 *
 * Bit independence across fields: WFI has a single fixed encoding (no
 * variable field), so C(0,2) = 0 cases.
 *
 * Built for both widths; on RV32 mtime/mtimecmp are two 32-bit halves
 * (see the wfi_timer_* helpers).
 * ===================================================================== */

    .include "xlen.inc"
    .include "harness.inc"

    .option norvc            /* mandatory, not stylistic -- see i/loads.S */

    .global tests_priv_wfi

    .equ CLINT_BASE,     0x02000000
    .equ CLINT_MTIMECMP, CLINT_BASE + 0x4000   /* hart 0 */
    .equ CLINT_MTIME,    CLINT_BASE + 0xbff8
    .equ WFI_DELAY,      10000                 /* timer ticks */

    .section .text

/* =======================================================================
 *  Shared macros
 * ======================================================================= */

/* WF_COUNT reg -- reg = trap_count (pc-relative). */
.macro WF_COUNT reg
    .option push
    .option norelax
    lw      \reg, trap_count
    .option pop
.endm

/* WF_FIELD rd, rs, shift, mask -- rd = (rs >> shift) & mask */
.macro WF_FIELD rd, rs, shift, mask
    srli    \rd, \rs, \shift
    andi    \rd, \rd, \mask
.endm

/* WF_CHK name, expected, actual -- check(name, LIX expected, actual).
 * actual must not be a0/a1. */
.macro WF_CHK name, exp, act
    la      a0, \name
    LIX     a1, \exp
    mv      a2, \act
    call    check
.endm

/* WF_MTIE -- mie = MTIE only. Clobbers t0. */
.macro WF_MTIE
    li      t0, MIE_MTIE
    csrw    mie, t0
.endm

/* =======================================================================
 *  Timer helpers (clobber t0-t3)
 * ======================================================================= */

/* wfi_timer_off: mtimecmp = all ones, so MTIP clears and stays clear. */
wfi_timer_off:
    li      t0, CLINT_MTIMECMP
    li      t1, -1
    .if XLEN == 64
    sd      t1, 0(t0)
    .else
    sw      t1, 0(t0)
    sw      t1, 4(t0)
    .endif
    ret

/* wfi_timer_soon: mtimecmp = mtime + WFI_DELAY. On RV32 mtime is read
 * hi/lo/hi until the two high halves agree, and mtimecmp is written
 * high = all ones first, so no half-written value is ever in the past. */
wfi_timer_soon:
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

/* wfi_timer_now: mtimecmp = 0, then wait (bounded) until mip.MTIP
 * shows it, so the interrupt is pending before the caller goes on. */
wfi_timer_now:
    li      t0, CLINT_MTIMECMP
    .if XLEN == 64
    sd      zero, 0(t0)
    .else
    sw      zero, 0(t0)
    sw      zero, 4(t0)
    .endif
    li      t1, 1000000
1:  csrr    t0, mip
    andi    t0, t0, MIE_MTIE
    bnez    t0, 2f
    addi    t1, t1, -1
    bnez    t1, 1b
2:  ret

/* =======================================================================
 *  Entry point
 * ======================================================================= */
tests_priv_wfi:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    csrw    mie, zero
    jal     ra, wfi_timer_off

    jal     ra, test_wfi_no_trap
    jal     ra, test_wfi_irq
    jal     ra, test_wfi_tw
    jal     ra, test_wfi_regs

    csrci   mstatus, MSTATUS_MIE
    csrw    mie, zero
    jal     ra, wfi_timer_off
    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  MIE = 0: WFI completes, no trap
 * ======================================================================= */
test_wfi_no_trap:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    /* --- interrupt already pending: s4 = 1 if execution went on at
     *     the next instruction, 3 if it came back through a trap --- */
    TEST_BEGIN str_wfi_pending_next
    jal     ra, wfi_timer_now
    WF_MTIE
    WF_COUNT s3
    TRAP_ARM .Lwf_p_back
    li      s4, 0
    wfi
    li      s4, 1
    j       .Lwf_p_done
.Lwf_p_back:
    li      s4, 3
.Lwf_p_done:
    TRAP_DISARM
    csrw    mie, zero
    jal     ra, wfi_timer_off
    WF_COUNT t0
    sub     s3, t0, s3
    WF_CHK  str_wfi_pending_next, 1, s4
    TEST_BEGIN str_wfi_pending_no_trap
    WF_CHK  str_wfi_pending_no_trap, 0, s3

    /* --- interrupt in the future: "while (!MTIP) wfi;" ends with no
     *     trap; s4 = 1 if the loop exited, 3 through a trap --- */
    TEST_BEGIN str_wfi_loop_exit
    jal     ra, wfi_timer_soon
    WF_MTIE
    WF_COUNT s3
    TRAP_ARM .Lwf_l_back
    li      s4, 0
1:  csrr    t0, mip
    andi    t0, t0, MIE_MTIE
    bnez    t0, 2f
    wfi
    j       1b
2:  li      s4, 1
    j       .Lwf_l_done
.Lwf_l_back:
    li      s4, 3
.Lwf_l_done:
    TRAP_DISARM
    csrw    mie, zero
    jal     ra, wfi_timer_off
    WF_COUNT t0
    sub     s3, t0, s3
    WF_CHK  str_wfi_loop_exit, 1, s4
    TEST_BEGIN str_wfi_loop_no_trap
    WF_CHK  str_wfi_loop_no_trap, 0, s3

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  MIE = 1: the interrupt is taken, mepc = after the WFI
 * ======================================================================= */
test_wfi_irq:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    TEST_BEGIN str_wfi_irq_once
    jal     ra, wfi_timer_soon
    WF_MTIE
    WF_COUNT s3
    la      s2, .Lwf_i_after
    TRAP_ARM .Lwf_i_back
    csrsi   mstatus, MSTATUS_MIE
    wfi
.Lwf_i_after:
    j       .Lwf_i_after            /* a WFI that doesn't wait spins here */
.Lwf_i_back:
    csrr    s5, mstatus
    csrci   mstatus, MSTATUS_MIE
    TRAP_DISARM
    csrw    mie, zero
    jal     ra, wfi_timer_off
    WF_COUNT t0
    sub     s3, t0, s3
    WF_CHK  str_wfi_irq_once, 1, s3

    TEST_BEGIN str_wfi_irq_mcause
    TRAP_LD t2, mcause
    WF_CHK  str_wfi_irq_mcause, (INTX_MIN + 7), t2

    TEST_BEGIN str_wfi_irq_mepc
    TRAP_LD t2, mepc
    la      a0, str_wfi_irq_mepc
    mv      a1, s2
    mv      a2, t2
    call    check

    TEST_BEGIN str_wfi_irq_mie
    TRAP_LD t2, mstatus
    WF_FIELD t2, t2, 3, 1
    WF_CHK  str_wfi_irq_mie, 0, t2
    TEST_BEGIN str_wfi_irq_mpie
    TRAP_LD t2, mstatus
    WF_FIELD t2, t2, 7, 1
    WF_CHK  str_wfi_irq_mpie, 1, t2
    TEST_BEGIN str_wfi_irq_mpp
    TRAP_LD t2, mstatus
    WF_FIELD t2, t2, 11, 3
    WF_CHK  str_wfi_irq_mpp, 3, t2
    TEST_BEGIN str_wfi_irq_after
    WF_FIELD t2, s5, 3, 1
    WF_CHK  str_wfi_irq_after, 1, t2

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  mstatus.TW: no effect in M-mode, WFI illegal in U-mode
 * ======================================================================= */
test_wfi_tw:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    /* --- M-mode, TW = 1, interrupt pending: completes as usual --- */
    TEST_BEGIN str_wfi_tw_m_next
    jal     ra, wfi_timer_now
    WF_MTIE
    li      t0, MSTATUS_TW
    csrs    mstatus, t0
    WF_COUNT s3
    TRAP_ARM .Lwf_tm_back
    li      s4, 0
    wfi
    li      s4, 1
    j       .Lwf_tm_done
.Lwf_tm_back:
    li      s4, 3
.Lwf_tm_done:
    TRAP_DISARM
    li      t0, MSTATUS_TW
    csrc    mstatus, t0
    csrw    mie, zero
    jal     ra, wfi_timer_off
    WF_COUNT t0
    sub     s3, t0, s3
    WF_CHK  str_wfi_tw_m_next, 1, s4
    TEST_BEGIN str_wfi_tw_m_no_trap
    WF_CHK  str_wfi_tw_m_no_trap, 0, s3

    /* --- U-mode, TW = 1, nothing pending: illegal. If the WFI
     *     completes instead, the ECALL after it traps (mcause 8); if it
     *     waits, the timer interrupt ends the wait (MIE doesn't mask
     *     M-mode interrupts in U-mode), so it's a FAIL either way --- */
    TEST_BEGIN str_wfi_tw_u
    jal     ra, wfi_timer_soon
    WF_MTIE
    li      t0, MSTATUS_TW
    csrs    mstatus, t0
    WF_COUNT s3
    la      s2, .Lwf_tu_at
    TRAP_ARM .Lwf_tu_back
    li      t0, MSTATUS_MPP | MSTATUS_MPIE   /* MPIE: see i/system.S's */
    csrc    mstatus, t0                      /* SYS_RUN_U */
    csrw    mepc, s2
    mret
.Lwf_tu_at:
    wfi                             /* in U-mode */
    ecall
.Lwf_tu_back:
    TRAP_DISARM
    li      t0, MSTATUS_TW
    csrc    mstatus, t0
    csrw    mie, zero
    jal     ra, wfi_timer_off
    WF_COUNT t0
    sub     s3, t0, s3
    WF_CHK  str_wfi_tw_u, 1, s3
    TEST_BEGIN str_wfi_tw_u_mcause
    TRAP_LD t2, mcause
    WF_CHK  str_wfi_tw_u_mcause, 2, t2
    TEST_BEGIN str_wfi_tw_u_mepc
    TRAP_LD t2, mepc
    la      a0, str_wfi_tw_u_mepc
    mv      a1, s2
    mv      a2, t2
    call    check
    TEST_BEGIN str_wfi_tw_u_mpp
    TRAP_LD t2, mstatus
    WF_FIELD t2, t2, 11, 3
    WF_CHK  str_wfi_tw_u_mpp, 0, t2

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  Registers: a0-a7, t4-t6 and s6-s11 get distinct patterns
 *  (k * 0x0101010101010101), one WFI with the interrupt pending, then
 *  (reg ^ pattern) ORed together must be 0. t0-t3 are left out: the
 *  timer helpers use them.
 * ======================================================================= */
test_wfi_regs:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    TEST_BEGIN str_wfi_regs
    jal     ra, wfi_timer_now
    WF_MTIE
    .set    wf_k, 1
    .irp r, a0,a1,a2,a3,a4,a5,a6,a7,t4,t5,t6,s6,s7,s8,s9,s10,s11
    LIXT    \r, (wf_k * 0x0101010101010101)
    .set    wf_k, wf_k + 1
    .endr
    TRAP_ARM .Lwf_r_trap            /* register-transparent */
    wfi
    TRAP_DISARM
    li      t1, 0
    .set    wf_k, 1
    .irp r, a0,a1,a2,a3,a4,a5,a6,a7,t4,t5,t6,s6,s7,s8,s9,s10,s11
    LIXT    t0, (wf_k * 0x0101010101010101)
    xor     t0, t0, \r
    or      t1, t1, t0
    .set    wf_k, wf_k + 1
    .endr
    mv      s6, t1
    csrw    mie, zero
    jal     ra, wfi_timer_off
    WF_CHK  str_wfi_regs, 0, s6
    j       .Lwf_r_done
.Lwf_r_trap:                        /* the WFI trapped: a FAIL, not a hang */
    csrw    mie, zero
    jal     ra, wfi_timer_off
    TRAP_REPORT str_wfi_regs
.Lwf_r_done:

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  Strings
 * ======================================================================= */
    .section .rodata
str_wfi_pending_next:    .asciz "WFI, MTIP pending, MIE=0: goes on at the next instruction"
str_wfi_pending_no_trap: .asciz "WFI, MTIP pending, MIE=0: no trap"
str_wfi_loop_exit:       .asciz "WFI loop until MTIP (MIE=0) exits"
str_wfi_loop_no_trap:    .asciz "WFI loop until MTIP (MIE=0): no trap"
str_wfi_irq_once:        .asciz "WFI, MIE=1: timer interrupt taken exactly once"
str_wfi_irq_mcause:      .asciz "WFI, MIE=1: mcause == interrupt | 7 (machine timer)"
str_wfi_irq_mepc:        .asciz "WFI, MIE=1: mepc == the instruction after WFI"
str_wfi_irq_mie:         .asciz "WFI, MIE=1: trap entry MIE == 0"
str_wfi_irq_mpie:        .asciz "WFI, MIE=1: trap entry MPIE == 1"
str_wfi_irq_mpp:         .asciz "WFI, MIE=1: trap entry MPP == 3 (M)"
str_wfi_irq_after:       .asciz "WFI, MIE=1: MIE == 1 after MRET"
str_wfi_tw_m_next:       .asciz "WFI in M-mode with TW=1: goes on at the next instruction"
str_wfi_tw_m_no_trap:    .asciz "WFI in M-mode with TW=1: no trap"
str_wfi_tw_u:            .asciz "WFI in U-mode with TW=1 traps exactly once"
str_wfi_tw_u_mcause:     .asciz "WFI in U-mode with TW=1: mcause == 2 (illegal instruction)"
str_wfi_tw_u_mepc:       .asciz "WFI in U-mode with TW=1: mepc == the WFI itself"
str_wfi_tw_u_mpp:        .asciz "WFI in U-mode with TW=1: trap entry MPP == 0 (U)"
str_wfi_regs:            .asciz "WFI: a0-a7, t4-t6, s6-s11 unchanged"
