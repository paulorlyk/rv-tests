/* =====================================================================
 * priv/irqpriv.S  --  M-mode interrupts are always enabled in U-mode
 *
 * Part of the privileged-architecture suite; see priv/tests.S for how
 * this plugs into the rest (main_tests.S -> priv/tests.S -> here), and
 * common.S for the boot/UART/reporting harness everything sits on
 * ("check", "test_begin" and the armed trap mode -- trap_resume/
 * trap_count/trap_mcause/... -- are used from there).
 *
 * mstatus.MIE is the global interrupt enable for M-mode only. While the
 * hart runs in a less-privileged mode, interrupts destined for M-mode
 * are enabled whatever MIE says: otherwise U-mode code could keep the
 * machine from ever getting control back. mie still selects which
 * sources may interrupt. So, for each of two sources -- the machine
 * software interrupt (the CLINT's msip register, mip.MSIP, cause 3)
 * and the machine timer (mtimecmp = 0, mip.MTIP, cause 7):
 *   - M-mode, MIE = 0, the source enabled in mie and pending: mip
 *     shows it pending, and it is not taken (no trap over a short
 *     spin);
 *   - U-mode entered with MIE = 0 (MPIE = 0 before the MRET), the same
 *     source enabled and pending: it is taken, exactly once, with
 *     mcause = interrupt bit | cause, MPP = 0 (it came from U-mode),
 *     MPIE = 0 (U-mode's MIE), and mepc inside the U-mode code (from
 *     its first instruction to the ECALL at its end: the spec doesn't
 *     say how many instructions may retire before a newly enabled
 *     interrupt is taken, so a short spin is allowed for);
 *   - U-mode with the same source pending but *not* enabled in mie:
 *     it is not taken -- the ECALL at the end of the U-mode code traps
 *     instead (mcause 8).
 * And in M-mode with MIE = 1:
 *   - the machine software interrupt is taken (direct mtvec, the
 *     armed handler): exactly once, mcause = interrupt bit | 3;
 *   - vectored mtvec (MODE = 1): an interrupt enters at BASE + 4 *
 *     cause (MSI at +12, MTI at +28), an exception (ECALL) at BASE;
 *   - priority: with MSI and MTI both pending and enabled, MSI (the
 *     higher priority) is taken first.
 * The vectored tests point mtvec at ip_vtable: 16 slots of "addi s4,
 * s4, 1" and then a stub that silences the source (mie = 0), steps
 * mepc past an exception and MRETs. Entering at slot k runs 16 - k
 * increments, so s4 says exactly which slot the hart went to: 13 for
 * MSI, 9 for MTI, 16 for an exception. A hart without vectored mode
 * (MODE is WARL) lands everything at BASE: 16, a FAIL. The handler
 * stays armed meanwhile, so an mtvec write that is ignored altogether
 * sends the trap to common.S's handler instead: s4 = 0, a FAIL.
 *
 * FAIL, NOT HANG: all of it runs armed (TRAP_ARM in harness.inc). The
 * U-mode code is a bounded spin followed by an ECALL, so a hart that
 * doesn't take the interrupt in U-mode comes back through the ECALL
 * (mcause 8: FAILs), and one that wrongly takes it in M-mode comes back
 * through the handler (a trap where none is expected: a FAIL). The
 * handler clears mie on every interrupt; the source itself (msip,
 * mtimecmp) is cleared by the test afterwards.
 *
 * ASSUMPTIONS: a CLINT/ACLINT at CLINT_BASE (QEMU virt: 0x02000000;
 * hart 0's msip at +0, mtimecmp at +0x4000), the same one priv/wfi.S
 * uses; U-mode and PMP as for the other U-mode tests (common.S's reset
 * sets PMP up); vectored mtvec accepting a 64-byte-aligned BASE. mie =
 * 0 on entry and on exit, msip = 0 and mtimecmp = all ones on exit,
 * mtvec restored.
 *
 * Bit independence across fields: nothing to pair -- this is about
 * interrupt delivery, not an instruction encoding (MRET and ECALL are
 * covered by priv/mret.S and i/system.S).
 *
 * Built for both widths; on RV32 mtimecmp is two 32-bit halves.
 * ===================================================================== */

    .include "xlen.inc"
    .include "harness.inc"

    .option norvc            /* mandatory, not stylistic -- see i/loads.S */

    .global tests_priv_irqpriv

    .equ CLINT_BASE,     0x02000000
    .equ CLINT_MSIP,     CLINT_BASE             /* hart 0 */
    .equ CLINT_MTIMECMP, CLINT_BASE + 0x4000    /* hart 0 */
    .equ MIE_MSIE,       0x8                    /* bit 3, also mip.MSIP */
    .equ IP_SPIN,        1000                   /* iterations */

    .section .text

/* =======================================================================
 *  Shared macros
 * ======================================================================= */

/* IP_NAME label, text -- define a test name string at label in .rodata. */
.macro IP_NAME label, text
    .pushsection .rodata
\label: .asciz "\text"
    .popsection
.endm

/* IP_COUNT reg -- reg = trap_count (pc-relative). */
.macro IP_COUNT reg
    .option push
    .option norelax
    lw      \reg, trap_count
    .option pop
.endm

/* IP_CHK name, expected, actual -- check(name, LIX expected, actual).
 * actual must not be a0/a1. */
.macro IP_CHK name, exp, act
    la      a0, \name
    LIX     a1, \exp
    mv      a2, \act
    call    check
.endm

/* =======================================================================
 *  Interrupt sources (each clobbers t0-t1)
 *  ip_on_<src>: raise it and wait (bounded) until mip shows it.
 *  ip_off_<src>: lower it and wait (bounded) until mip clears.
 * ======================================================================= */
ip_on_msip:
    li      t0, CLINT_MSIP
    li      t1, 1
    sw      t1, 0(t0)
    li      t1, MIE_MSIE
    j       ip_wait_set

ip_off_msip:
    li      t0, CLINT_MSIP
    sw      zero, 0(t0)
    li      t1, MIE_MSIE
    j       ip_wait_clear

ip_on_mtip:
    li      t0, CLINT_MTIMECMP
    .if XLEN == 64
    sd      zero, 0(t0)
    .else
    sw      zero, 0(t0)
    sw      zero, 4(t0)
    .endif
    li      t1, MIE_MTIE
    j       ip_wait_set

ip_off_mtip:
    li      t0, CLINT_MTIMECMP
    li      t1, -1
    .if XLEN == 64
    sd      t1, 0(t0)
    .else
    sw      t1, 4(t0)
    sw      t1, 0(t0)
    .endif
    li      t1, MIE_MTIE
    j       ip_wait_clear

/* ip_wait_set / ip_wait_clear: t1 = the mip bit; poll mip until it is
 * set / clear, at most 1000000 times. Clobbers t0-t2. */
ip_wait_set:
    li      t2, 1000000
1:  csrr    t0, mip
    and     t0, t0, t1
    bnez    t0, 2f
    addi    t2, t2, -1
    bnez    t2, 1b
2:  ret

ip_wait_clear:
    li      t2, 1000000
1:  csrr    t0, mip
    and     t0, t0, t1
    beqz    t0, 2f
    addi    t2, t2, -1
    bnez    t2, 1b
2:  ret

/* =======================================================================
 *  T_IP src, bit, cause, NAME -- the three cases for one source:
 *  src selects ip_on_<src>/ip_off_<src>, bit is its mie/mip bit, cause
 *  its interrupt cause, NAME the text in the test names.
 * ======================================================================= */
.macro T_IP src, bit, cause, name
    IP_NAME .Lip_m_pend\@,  "\name pending, MIE=0 in M-mode: mip shows it"
    IP_NAME .Lip_m_none\@,  "\name pending, MIE=0 in M-mode: not taken"
    IP_NAME .Lip_u_once\@,  "\name pending, MIE=0 in U-mode: taken exactly once"
    IP_NAME .Lip_u_cause\@, "\name pending, MIE=0 in U-mode: mcause == interrupt | \cause"
    IP_NAME .Lip_u_mpp\@,   "\name pending, MIE=0 in U-mode: trap entry MPP == 0 (U)"
    IP_NAME .Lip_u_mpie\@,  "\name pending, MIE=0 in U-mode: trap entry MPIE == 0 (U-mode MIE)"
    IP_NAME .Lip_u_mepc\@,  "\name pending, MIE=0 in U-mode: mepc in the U-mode code"
    IP_NAME .Lip_d_once\@,  "\name pending, not in mie, in U-mode: not taken (ECALL traps once)"
    IP_NAME .Lip_d_cause\@, "\name pending, not in mie, in U-mode: mcause == 8 (the ECALL)"

    /* --- M-mode, MIE = 0: pending and enabled in mie, not taken --- */
    TEST_BEGIN .Lip_m_pend\@
    csrci   mstatus, MSTATUS_MIE
    jal     ra, ip_on_\src
    csrr    s5, mip
    IP_COUNT s3
    TRAP_ARM .Lip_m_back\@
    li      t0, \bit
    csrw    mie, t0
    li      t0, IP_SPIN
1:  addi    t0, t0, -1
    bnez    t0, 1b
.Lip_m_back\@:
    TRAP_DISARM
    csrw    mie, zero
    jal     ra, ip_off_\src
    IP_COUNT t0
    sub     s3, t0, s3
    andi    s5, s5, \bit
    IP_CHK  .Lip_m_pend\@, \bit, s5
    TEST_BEGIN .Lip_m_none\@
    IP_CHK  .Lip_m_none\@, 0, s3

    /* --- U-mode entered with MIE = 0: taken. s2/s6 = the first and
     *     last address the interrupt may be taken at --- */
    TEST_BEGIN .Lip_u_once\@
    jal     ra, ip_on_\src
    IP_COUNT s3
    .option push
    .option norelax
    la      s2, .Lip_u_entry\@
    la      s6, .Lip_u_ecall\@
    .option pop
    TRAP_ARM .Lip_u_back\@
    li      t0, \bit
    csrw    mie, t0
    li      t0, MSTATUS_MPP | MSTATUS_MPIE
    csrc    mstatus, t0
    csrw    mepc, s2
    mret
.Lip_u_entry\@:                     /* U-mode from here */
    li      t0, IP_SPIN
1:  addi    t0, t0, -1
    bnez    t0, 1b
.Lip_u_ecall\@:
    ecall                           /* backstop: interrupt never taken */
.Lip_u_back\@:
    TRAP_DISARM
    csrw    mie, zero
    jal     ra, ip_off_\src
    IP_COUNT t0
    sub     s3, t0, s3
    IP_CHK  .Lip_u_once\@, 1, s3
    TEST_BEGIN .Lip_u_cause\@
    TRAP_LD t2, mcause
    IP_CHK  .Lip_u_cause\@, (INTX_MIN + \cause), t2
    TEST_BEGIN .Lip_u_mpp\@
    TRAP_LD t2, mstatus
    srli    t2, t2, 11
    andi    t2, t2, 3
    IP_CHK  .Lip_u_mpp\@, 0, t2
    TEST_BEGIN .Lip_u_mpie\@
    TRAP_LD t2, mstatus
    srli    t2, t2, 7
    andi    t2, t2, 1
    IP_CHK  .Lip_u_mpie\@, 0, t2
    /* mepc in [s2, s6]: t2 = 1 if so */
    TEST_BEGIN .Lip_u_mepc\@
    TRAP_LD t0, mepc
    sltu    t1, t0, s2              /* below the entry */
    sltu    t2, s6, t0              /* past the ECALL */
    or      t2, t2, t1
    xori    t2, t2, 1
    IP_CHK  .Lip_u_mepc\@, 1, t2

    /* --- U-mode, pending but not enabled in mie: the ECALL traps --- */
    TEST_BEGIN .Lip_d_once\@
    jal     ra, ip_on_\src
    IP_COUNT s3
    .option push
    .option norelax
    la      s2, .Lip_d_entry\@
    .option pop
    TRAP_ARM .Lip_d_back\@
    csrw    mie, zero
    li      t0, MSTATUS_MPP | MSTATUS_MPIE
    csrc    mstatus, t0
    csrw    mepc, s2
    mret
.Lip_d_entry\@:                     /* U-mode from here */
    li      t0, IP_SPIN
1:  addi    t0, t0, -1
    bnez    t0, 1b
    ecall
.Lip_d_back\@:
    TRAP_DISARM
    jal     ra, ip_off_\src
    IP_COUNT t0
    sub     s3, t0, s3
    IP_CHK  .Lip_d_once\@, 1, s3
    TEST_BEGIN .Lip_d_cause\@
    TRAP_LD t2, mcause
    IP_CHK  .Lip_d_cause\@, 8, t2
.endm

/* =======================================================================
 *  M-mode, MIE = 1: taken; vectored mtvec; priority
 * ======================================================================= */

/* ip_vtable: vectored-mode mtvec BASE (see the file header). The stub
 * uses s5/s6 only, so the interrupted spin (t0) is undisturbed; its
 * MRET leaves MPIE = 1, which the tests clear afterwards. */
    .balign 64
ip_vtable:
    .rept   16
    addi    s4, s4, 1
    .endr
    csrw    mie, zero               /* silence the source */
    csrr    s5, mcause
    bltz    s5, 1f
    csrr    s6, mepc                /* an exception: step past it */
    addi    s6, s6, 4
    csrw    mepc, s6
1:  mret

/* T_IPV mask, expect, name -- vectored mtvec, the sources in mask
 * already pending: enable them in mie, set MIE for a bounded spin,
 * check s4 (the slot count) against expect. */
.macro T_IPV mask, expect, name
    TEST_BEGIN \name
    li      s4, 0
    csrr    s7, mtvec
    TRAP_ARM .Lipv_back\@          /* mtvec write ignored: common.S's */
    .option push
    .option norelax
    la      t0, ip_vtable
    .option pop
    ori     t0, t0, 1               /* MODE = vectored */
    csrw    mtvec, t0
    li      t0, \mask
    csrw    mie, t0
    csrsi   mstatus, MSTATUS_MIE
    li      t0, IP_SPIN
1:  addi    t0, t0, -1
    bnez    t0, 1b
.Lipv_back\@:
    csrci   mstatus, MSTATUS_MIE
    csrw    mtvec, s7
    TRAP_DISARM
    csrw    mie, zero
    li      t0, MSTATUS_MPIE
    csrc    mstatus, t0
    IP_CHK  \name, \expect, s4
.endm

test_ip_mmode:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    /* --- direct mtvec: MSI taken in M-mode with MIE = 1 --- */
    TEST_BEGIN str_ip_msi_m_once
    csrci   mstatus, MSTATUS_MIE
    jal     ra, ip_on_msip
    IP_COUNT s3
    TRAP_ARM .Lip_mm_back
    li      t0, MIE_MSIE
    csrw    mie, t0
    csrsi   mstatus, MSTATUS_MIE
    li      t0, IP_SPIN
1:  addi    t0, t0, -1
    bnez    t0, 1b
.Lip_mm_back:
    csrci   mstatus, MSTATUS_MIE
    TRAP_DISARM
    csrw    mie, zero
    li      t0, MSTATUS_MPIE
    csrc    mstatus, t0
    jal     ra, ip_off_msip
    IP_COUNT t0
    sub     s3, t0, s3
    IP_CHK  str_ip_msi_m_once, 1, s3
    TEST_BEGIN str_ip_msi_m_cause
    TRAP_LD t2, mcause
    IP_CHK  str_ip_msi_m_cause, (INTX_MIN + 3), t2

    /* --- vectored mtvec --- */
    jal     ra, ip_on_msip
    T_IPV   MIE_MSIE, 13, str_ip_vec_msi
    jal     ra, ip_off_msip
    jal     ra, ip_on_mtip
    T_IPV   MIE_MTIE, 9, str_ip_vec_mti
    jal     ra, ip_off_mtip

    /* --- priority: MSI before MTI --- */
    jal     ra, ip_on_msip
    jal     ra, ip_on_mtip
    T_IPV   (MIE_MSIE | MIE_MTIE), 13, str_ip_prio
    jal     ra, ip_off_msip
    jal     ra, ip_off_mtip

    /* --- vectored mtvec: an exception enters at BASE --- */
    TEST_BEGIN str_ip_vec_ecall
    li      s4, 0
    csrr    s7, mtvec
    TRAP_ARM .Lip_ve_back
    .option push
    .option norelax
    la      t0, ip_vtable
    .option pop
    ori     t0, t0, 1
    csrw    mtvec, t0
    ecall                           /* the stub steps past it */
.Lip_ve_back:
    csrw    mtvec, s7
    TRAP_DISARM
    li      t0, MSTATUS_MPIE
    csrc    mstatus, t0
    IP_CHK  str_ip_vec_ecall, 16, s4

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  Entry point
 * ======================================================================= */
tests_priv_irqpriv:
    addi    sp, sp, -64
    REG_S   ra, 0(sp)
    REG_S   s2, 8(sp)
    REG_S   s3, 16(sp)
    REG_S   s5, 24(sp)
    REG_S   s6, 32(sp)
    REG_S   s4, 40(sp)
    REG_S   s7, 48(sp)

    csrci   mstatus, MSTATUS_MIE
    csrw    mie, zero
    jal     ra, ip_off_msip
    jal     ra, ip_off_mtip

    T_IP    msip, MIE_MSIE, 3, "IRQ machine software interrupt"
    T_IP    mtip, MIE_MTIE, 7, "IRQ machine timer interrupt"
    jal     ra, test_ip_mmode

    csrci   mstatus, MSTATUS_MIE
    csrw    mie, zero
    REG_L   ra, 0(sp)
    REG_L   s2, 8(sp)
    REG_L   s3, 16(sp)
    REG_L   s5, 24(sp)
    REG_L   s6, 32(sp)
    REG_L   s4, 40(sp)
    REG_L   s7, 48(sp)
    addi    sp, sp, 64
    ret

    .section .rodata
str_ip_msi_m_once:  .asciz "IRQ machine software interrupt, MIE=1 in M-mode: taken exactly once"
str_ip_msi_m_cause: .asciz "IRQ machine software interrupt, MIE=1 in M-mode: mcause == interrupt | 3"
str_ip_vec_msi:     .asciz "IRQ with vectored mtvec: machine software interrupt enters at BASE + 4*3"
str_ip_vec_mti:     .asciz "IRQ with vectored mtvec: machine timer interrupt enters at BASE + 4*7"
str_ip_prio:        .asciz "IRQ MSI and MTI both pending and enabled: MSI (higher priority) taken first"
str_ip_vec_ecall:   .asciz "ECALL with vectored mtvec: the exception enters at BASE"
