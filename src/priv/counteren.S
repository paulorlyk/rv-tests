/* =====================================================================
 * priv/counteren.S  --  mcounteren / scounteren: which modes may read
 *                       the cycle, time and instret counters
 *
 * Part of the privileged-architecture suite; see priv/tests.S for how
 * this plugs into the rest (main_tests.S -> priv/tests.S -> here), and
 * common.S for the boot/UART/reporting harness everything sits on
 * ("check", "test_begin" and the armed trap mode -- trap_resume/
 * trap_count/trap_mcause/... -- are used from there). The SM_* and
 * T_SM_* macros are in priv/smode.inc.
 *
 * The unprivileged counters cycle, time and instret (and on RV32 their
 * upper halves cycleh, timeh, instreth) are user-level CSRs, but
 * M-mode decides who may read them: mcounteren bit CY (0) / TM (1) /
 * IR (2) lets S-mode read the counter, and U-mode needs that bit *and*
 * the same bit in scounteren. A read that isn't permitted is an
 * illegal instruction. M-mode can always read them. For each counter,
 * with every *other* bit of mcounteren/scounteren set where a bit is
 * cleared (so a hart that looks at the wrong bit fails):
 *   - M-mode, mcounteren = scounteren = 0: the read doesn't trap;
 *   - S-mode, mcounteren bit clear: illegal (T_SM_ILL: one trap, into
 *     M-mode, mcause 2, mepc on it, MPP = 1, rd not written);
 *   - S-mode, mcounteren bit set: doesn't trap (T_SM_OK);
 *   - U-mode, mcounteren bit set, scounteren bit clear: illegal;
 *   - U-mode, mcounteren bit clear, scounteren bit set: illegal;
 *   - U-mode, both set: doesn't trap.
 * The read is CSRRS rd, <counter>, x0 (what the rdcycle/rdtime/
 * rdinstret pseudo-instructions are).
 *
 * FAIL, NOT HANG: every case runs armed (TRAP_ARM in harness.inc),
 * through SM_RUN, with an ECALL after the read as the backstop.
 * scounteren exists only with S-mode, so it's written armed.
 *
 * ASSUMPTIONS: S-mode and U-mode; PMP and satp as for priv/smode.S;
 * the time CSR is implemented (QEMU virt reads it from the ACLINT's
 * mtime), not trapped to M-mode for emulation; mcounteren bits 0-2
 * and scounteren bits 0-2 are writable. mcounteren and scounteren are
 * put back to 0 afterwards.
 *
 * Bit independence across fields: nothing new -- the CSR instructions'
 * bitx cases are in the Zicsr suite.
 *
 * Built for both widths; the upper-half counters are RV32 only.
 * ===================================================================== */

    .include "xlen.inc"
    .include "harness.inc"
    .include "priv/smode.inc"

    .option norvc            /* mandatory, not stylistic -- see i/loads.S */

    .global tests_priv_counteren

    .section .text

/* CE_EN m, s -- mcounteren = m, scounteren = s; each armed on its own
 * (scounteren exists only with S-mode). Clobbers t0. */
.macro CE_EN m, s
    TRAP_ARM .Lce_m\@
    li      t0, \m
    csrw    mcounteren, t0
    TRAP_DISARM
.Lce_m\@:
    TRAP_ARM .Lce_s\@
    li      t0, \s
    csrw    scounteren, t0
    TRAP_DISARM
.Lce_s\@:
.endm

/* T_CE ctr, bit, NAME -- the six cases for one counter CSR (NAME is the
 * enable bit's name, CY/TM/IR). */
.macro T_CE ctr, bit, name
    SM_NAME .Lce_m_ok\@, "CSRRS rd, \ctr, x0 in M-mode, mcounteren=scounteren=0: doesn't trap"

    /* --- M-mode --- */
    TEST_BEGIN .Lce_m_ok\@
    CE_EN   0, 0
    SM_COUNT s3
    TRAP_ARM .Lce_m_back\@
    csrr    a3, \ctr
    TRAP_DISARM
.Lce_m_back\@:
    SM_COUNT t0
    sub     s3, t0, s3
    SM_CHK  .Lce_m_ok\@, 0, s3

    /* --- S-mode --- */
    T_SM_ILL "CE_EN ~(1 << \bit), -1", S, 1, "CSRRS rd, \ctr, x0 with mcounteren.\name=0", csrrs a3, \ctr, x0
    T_SM_OK "CE_EN (1 << \bit), 0", S, "CSRRS rd, \ctr, x0 with mcounteren.\name=1", csrrs a3, \ctr, x0

    /* --- U-mode --- */
    T_SM_ILL "CE_EN (1 << \bit), ~(1 << \bit)", U, 1, "CSRRS rd, \ctr, x0 with mcounteren.\name=1 scounteren.\name=0", csrrs a3, \ctr, x0
    T_SM_ILL "CE_EN ~(1 << \bit), (1 << \bit)", U, 1, "CSRRS rd, \ctr, x0 with mcounteren.\name=0 scounteren.\name=1", csrrs a3, \ctr, x0
    T_SM_OK "CE_EN (1 << \bit), (1 << \bit)", U, "CSRRS rd, \ctr, x0 with mcounteren.\name=1 scounteren.\name=1", csrrs a3, \ctr, x0

    CE_EN   0, 0
.endm

/* =======================================================================
 *  Entry point
 * ======================================================================= */
tests_priv_counteren:
    addi    sp, sp, -48
    REG_S   ra, 0(sp)
    REG_S   s2, 8(sp)
    REG_S   s3, 16(sp)
    REG_S   s4, 24(sp)
    REG_S   s8, 32(sp)

    csrci   mstatus, MSTATUS_MIE
    csrw    mie, zero
    SM_SETUP
    jal     ra, sm_clean

    T_CE    cycle, 0, CY
    T_CE    time, 1, TM
    T_CE    instret, 2, IR
    .if XLEN == 32
    T_CE    cycleh, 0, CY
    T_CE    timeh, 1, TM
    T_CE    instreth, 2, IR
    .endif

    jal     ra, sm_clean
    REG_L   ra, 0(sp)
    REG_L   s2, 8(sp)
    REG_L   s3, 16(sp)
    REG_L   s4, 24(sp)
    REG_L   s8, 32(sp)
    addi    sp, sp, 48
    ret

    SM_HANDLER_CODE
