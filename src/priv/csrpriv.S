/* =====================================================================
 * priv/csrpriv.S  --  M-mode CSRs are out of U-mode's reach
 *
 * Part of the privileged-architecture suite; see priv/tests.S for how
 * this plugs into the rest (main_tests.S -> priv/tests.S -> here), and
 * common.S for the boot/UART/reporting harness everything sits on
 * ("check", "test_begin" and the armed trap mode -- trap_resume/
 * trap_count/trap_mcause/... -- are used from there).
 *
 * A CSR's lowest permitted privilege is encoded in the CSR number
 * itself, bits 9:8 (3 = M), and bits 11:10 = 3 mark it read-only. Any
 * access to a CSR from a mode below its privilege is an illegal
 * instruction -- including one that doesn't write it (CSRRS/CSRRC with
 * rs1 = x0, CSRRSI/CSRRCI with uimm = 0): "no write" only waives the
 * read-only check, never the privilege check. So a hart that checks
 * privilege only on writes, only for some CSR numbers, or only for
 * some of the six instructions leaks M-mode state to U-mode (or lets
 * U-mode change it). What is checked, for each CSR below, each case
 * run once in U-mode (MRET with MPP = U):
 *   - the four forms that don't write: CSRRS/CSRRC rd, csr, x0 and
 *     CSRRSI/CSRRCI rd, csr, 0;
 *   - for the writable CSRs, the seven forms that do: CSRRW rd,
 *     CSRRW x0 (a pure write, no read), CSRRS/CSRRC with rs1 != x0,
 *     CSRRWI/CSRRSI/CSRRCI with uimm != 0;
 * and for each case:
 *   - it traps, exactly once;
 *   - mcause == 2 (illegal instruction);
 *   - mepc == the CSR instruction;
 *   - mtval == 0 or the instruction's own bits (the spec allows
 *     either);
 *   - rd is not written (rd = a3, preset to CP_PAT; not for CSRRW x0):
 *     an instruction that traps doesn't retire, so the CSR's value
 *     must not reach U-mode;
 *   - for the write forms, the CSR is not written: its value, read
 *     back in M-mode after the trap, is the value it had before
 *     (compared under a per-CSR mask, see below).
 *
 * The CSRs: the read-only mvendorid, marchid, mimpid, mhartid (the
 * four non-writing forms only: a write to them is illegal even in
 * M-mode, so it wouldn't show anything about privilege), and the
 * writable mstatus, misa, mie, mtvec, mscratch, mepc, mcause, mtval,
 * mip. Not covered here: mcounteren, the counters (mcycle,
 * minstret, ...) and the PMP CSRs.
 *
 * WHAT A WRITE CASE WRITES. If the write wrongly goes through, the
 * value written must not wreck the harness, and it must differ from
 * what was there, so the check can see it. Per CSR:
 *   - mstatus: register forms flip TW (bit 21, harmless: nothing here
 *     executes WFI), immediate forms flip SIE (bit 1; read-only 0
 *     without S-mode, which just makes the side effect invisible).
 *     CSRRWI writes the value 2 (SIE alone). Compared without MIE,
 *     MPIE and MPP, which the MRET into U-mode and the trap change.
 *   - misa: a successful write could switch an extension off, so
 *     every write puts back what is already there: CSRRW writes the
 *     current value, CSRRS sets bits already set (the current value;
 *     CSRRSI: C, uimm 4), CSRRC clears bits already clear (its
 *     complement; CSRRCI: D and E, uimm 0x18). Still a write attempt,
 *     so still illegal. No CSRRWI (it can't write misa unchanged).
 *   - mie: MSIE (bit 3; uimm 8). The CLINT's msip is 0, so nothing is
 *     pending for it.
 *   - mtvec: MODE bit 0 (vectored). Exceptions still go to BASE, the
 *     handler, so the backstop ECALL is caught either way. For the
 *     clearing forms mtvec is set to vectored in M-mode first. No
 *     CSRRWI (it would replace BASE).
 *   - mip: SSIP (bit 1; uimm 2), compared on that bit only (the
 *     others are driven by hardware). Nothing is enabled in mie, so a
 *     pending SSIP is never taken.
 *   - mscratch, mepc, mcause, mtval: the trap itself (or the handler,
 *     for mscratch) overwrites them, so there is nothing to compare;
 *     the write cases still check the trap and rd. The values written
 *     (4, uimm 4) are harmless for the same reason.
 * A clearing form finds the bit set (set in M-mode first), a setting
 * form finds it clear, and a flipping CSRRW writes the current value
 * with the bit flipped. Every CSR is put back to its original value
 * after each case.
 *
 * FAIL, NOT HANG: every case runs armed (TRAP_ARM in harness.inc).
 * The instruction under test is followed by an ECALL, so one that
 * wrongly doesn't trap is caught there instead (mcause 8, mepc on the
 * ECALL: FAILs) and execution never stays in U-mode.
 *
 * ASSUMPTIONS: U-mode is implemented and PMP (if any) lets U-mode reach
 * all memory -- common.S's reset sets that up. mtvec accepts vectored
 * mode at trap_handler's alignment (16 bytes), or ignores the MODE
 * write. mie = 0 and msip = 0 on entry (priv/wfi.S leaves mie = 0).
 *
 * Bit independence across fields: nothing new -- the six CSR
 * instructions have their bitx cases in the Zicsr suite; the csr
 * field is what this file walks, one fixed value per case.
 *
 * Built unchanged for both widths (mstatus bit numbers are the same).
 * ===================================================================== */

    .include "xlen.inc"
    .include "harness.inc"

    .option norvc            /* mandatory, not stylistic -- see i/loads.S */

    .global tests_priv_csrpriv

    .equ CP_TW,  0x200000            /* mstatus.TW */
    .equ CP_PAT, 0x5ac3a55a3cc3a5c3  /* rd's preset value (LIXT) */
    /* mstatus bits the MRET into U-mode and the trap change */
    .equ CP_MSTATUS_K, ~(MSTATUS_MIE | MSTATUS_MPIE | MSTATUS_MPP)

    .section .text

/* =======================================================================
 *  Shared macros
 * ======================================================================= */

/* CP_NAME label, text -- define a test name string at label in .rodata. */
.macro CP_NAME label, text
    .pushsection .rodata
\label: .asciz "\text"
    .popsection
.endm

/* CP_COUNT reg -- reg = trap_count (pc-relative). */
.macro CP_COUNT reg
    .option push
    .option norelax
    lw      \reg, trap_count
    .option pop
.endm

/* CP_RUN_U insn -- run \insn once in U-mode with the handler armed
 * (MPP = U, MPIE = 0, mepc = the instruction, MRET), an ECALL after it
 * as the backstop. Leaves:
 *   s2 = the address of \insn
 *   s3 = traps taken (trap_count delta)
 * Clobbers t0. */
.macro CP_RUN_U insn:vararg
    CP_COUNT s3
    .option push
    .option norelax
    la      s2, .Lcp_at\@
    .option pop
    TRAP_ARM .Lcp_back\@
    li      t0, MSTATUS_MPP | MSTATUS_MPIE
    csrc    mstatus, t0
    csrw    mepc, s2
    mret
.Lcp_at\@:
    \insn                           /* in U-mode: must trap */
    ecall                           /* backstop */
.Lcp_back\@:
    TRAP_DISARM
    CP_COUNT t0
    sub     s3, t0, s3
.endm

/* CP_CHK name, expected, actual -- check(name, LIX expected, actual).
 * actual must not be a0/a1. */
.macro CP_CHK name, exp, act
    la      a0, \name
    LIX     a1, \exp
    mv      a2, \act
    call    check
.endm

/* CP_CHKR name, expected, actual -- same, expected in a register (not
 * a0/a2). */
.macro CP_CHKR name, exp, act
    la      a0, \name
    mv      a1, \exp
    mv      a2, \act
    call    check
.endm

/* T_CP csr, k, pre, bit, a4k, rd, desc, insn...
 *   One case: \insn (text, run in U-mode) must trap without touching
 *   \csr or rd. Names are "<desc> in U-mode: ...".
 *   k    -- mask of \csr bits compared before/after, 0 = no compare
 *           (and then \csr is left alone: no preparation, no restore)
 *   pre  -- none | set | clr: set or clear \bit in \csr in M-mode first
 *   a4k  -- what rs1 (a4) holds: none | bit (\bit) | flip (\csr's
 *           value with \bit flipped) | same (\csr's value) | inv (its
 *           complement)
 *   rd   -- 1 if \insn has rd = a3 (checked unchanged), 0 for rd = x0
 * Uses s2-s7; clobbers t0-t3. */
.macro T_CP csr, k, pre, bit, a4k, rd, desc, insn:vararg
    CP_NAME .Lcp_once\@,  "\desc in U-mode: traps exactly once"
    CP_NAME .Lcp_cause\@, "\desc in U-mode: mcause == 2 (illegal instruction)"
    CP_NAME .Lcp_mepc\@,  "\desc in U-mode: mepc == the instruction"
    CP_NAME .Lcp_mtval\@, "\desc in U-mode: mtval == 0 or the instruction"
    .if \rd
    CP_NAME .Lcp_rd\@,    "\desc in U-mode: rd not written"
    .endif
    .if \k
    CP_NAME .Lcp_csr\@,   "\desc in U-mode: \csr not written"
    .endif

    TEST_BEGIN .Lcp_once\@
    .if \k
    csrr    s7, \csr                /* the original, restored below */
    .ifc \pre, set
    LIX     t0, \bit
    csrs    \csr, t0
    .endif
    .ifc \pre, clr
    LIX     t0, \bit
    csrc    \csr, t0
    .endif
    .endif
    csrr    s5, \csr                /* the value U-mode must not change */
    .ifc \a4k, bit
    LIX     a4, \bit
    .endif
    .ifc \a4k, flip
    LIX     a4, \bit
    xor     a4, a4, s5
    .endif
    .ifc \a4k, same
    mv      a4, s5
    .endif
    .ifc \a4k, inv
    not     a4, s5
    .endif
    LIXT    a3, CP_PAT
    CP_RUN_U \insn
    mv      s4, a3                  /* rd, before anything reuses it */
    .if \k
    csrr    s6, \csr
    csrw    \csr, s7
    .endif

    CP_CHK  .Lcp_once\@, 1, s3
    TEST_BEGIN .Lcp_cause\@
    TRAP_LD t2, mcause
    CP_CHK  .Lcp_cause\@, 2, t2
    TEST_BEGIN .Lcp_mepc\@
    TRAP_LD t2, mepc
    CP_CHKR .Lcp_mepc\@, s2, t2
    /* mtval: expected = the instruction if mtval != 0, else 0 */
    TEST_BEGIN .Lcp_mtval\@
    TRAP_LD t2, mtval
    li      t3, 0
    beqz    t2, 1f
    LWUX    t3, 0(s2)
1:  CP_CHKR .Lcp_mtval\@, t3, t2
    .if \rd
    TEST_BEGIN .Lcp_rd\@
    LIXT    t3, CP_PAT
    CP_CHKR .Lcp_rd\@, t3, s4
    .endif
    .if \k
    TEST_BEGIN .Lcp_csr\@
    LIX     t0, \k
    and     s5, s5, t0
    and     s6, s6, t0
    CP_CHKR .Lcp_csr\@, s5, s6
    .endif
.endm

/* T_CP_READS csr, NAME -- the four forms that don't write. */
.macro T_CP_READS csr, name
    T_CP \csr, 0, none, 0, none, 1, "CSRRS rd, \name, x0",  csrrs  a3, \csr, x0
    T_CP \csr, 0, none, 0, none, 1, "CSRRC rd, \name, x0",  csrrc  a3, \csr, x0
    T_CP \csr, 0, none, 0, none, 1, "CSRRSI rd, \name, 0",  csrrsi a3, \csr, 0
    T_CP \csr, 0, none, 0, none, 1, "CSRRCI rd, \name, 0",  csrrci a3, \csr, 0
.endm

/* T_CP_WRITES csr, name, k, bit, ubit, wi -- the seven forms that
 * write, flipping/setting/clearing \bit (register forms) or \ubit
 * (immediate forms, a uimm); wi = 0 leaves out CSRRWI, which writes
 * \ubit as the whole value. With k = 0 nothing is compared or
 * prepared (see T_CP). */
.macro T_CP_WRITES csr, name, k, bit, ubit, wi=1
    .if \k
    T_CP \csr, \k, none, \bit, flip, 1, "CSRRW rd, \name, rs1",  csrrw  a3, \csr, a4
    T_CP \csr, \k, none, \bit, flip, 0, "CSRRW x0, \name, rs1",  csrrw  x0, \csr, a4
    T_CP \csr, \k, clr,  \bit, bit,  1, "CSRRS rd, \name, rs1",  csrrs  a3, \csr, a4
    T_CP \csr, \k, set,  \bit, bit,  1, "CSRRC rd, \name, rs1",  csrrc  a3, \csr, a4
    .if \wi
    T_CP \csr, \k, none, 0,    none, 1, "CSRRWI rd, \name, \ubit", csrrwi a3, \csr, \ubit
    .endif
    T_CP \csr, \k, clr,  \ubit, none, 1, "CSRRSI rd, \name, \ubit", csrrsi a3, \csr, \ubit
    T_CP \csr, \k, set,  \ubit, none, 1, "CSRRCI rd, \name, \ubit", csrrci a3, \csr, \ubit
    .else
    T_CP \csr, 0, none, \bit, bit, 1, "CSRRW rd, \name, rs1",  csrrw  a3, \csr, a4
    T_CP \csr, 0, none, \bit, bit, 0, "CSRRW x0, \name, rs1",  csrrw  x0, \csr, a4
    T_CP \csr, 0, none, \bit, bit, 1, "CSRRS rd, \name, rs1",  csrrs  a3, \csr, a4
    T_CP \csr, 0, none, \bit, bit, 1, "CSRRC rd, \name, rs1",  csrrc  a3, \csr, a4
    T_CP \csr, 0, none, 0,    none, 1, "CSRRWI rd, \name, \ubit", csrrwi a3, \csr, \ubit
    T_CP \csr, 0, none, 0,    none, 1, "CSRRSI rd, \name, \ubit", csrrsi a3, \csr, \ubit
    T_CP \csr, 0, none, 0,    none, 1, "CSRRCI rd, \name, \ubit", csrrci a3, \csr, \ubit
    .endif
.endm

/* =======================================================================
 *  Entry point
 * ======================================================================= */
tests_priv_csrpriv:
    addi    sp, sp, -64
    REG_S   ra, 0(sp)
    REG_S   s2, 8(sp)
    REG_S   s3, 16(sp)
    REG_S   s4, 24(sp)
    REG_S   s5, 32(sp)
    REG_S   s6, 40(sp)
    REG_S   s7, 48(sp)

    jal     ra, test_cp_readonly
    jal     ra, test_cp_trap_csrs
    jal     ra, test_cp_state_csrs
    jal     ra, test_cp_misa_mtvec

    REG_L   ra, 0(sp)
    REG_L   s2, 8(sp)
    REG_L   s3, 16(sp)
    REG_L   s4, 24(sp)
    REG_L   s5, 32(sp)
    REG_L   s6, 40(sp)
    REG_L   s7, 48(sp)
    addi    sp, sp, 64
    ret

/* =======================================================================
 *  Read-only M-mode CSRs: the non-writing forms
 * ======================================================================= */
test_cp_readonly:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    T_CP_READS mvendorid, mvendorid
    T_CP_READS marchid, marchid
    T_CP_READS mimpid, mimpid
    T_CP_READS mhartid, mhartid

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  mscratch, mepc, mcause, mtval: the trap overwrites them, so no
 *  before/after compare
 * ======================================================================= */
test_cp_trap_csrs:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    T_CP_READS  mscratch, mscratch
    T_CP_WRITES mscratch, mscratch, 0, 4, 4
    T_CP_READS  mepc, mepc
    T_CP_WRITES mepc, mepc, 0, 4, 4
    T_CP_READS  mcause, mcause
    T_CP_WRITES mcause, mcause, 0, 4, 4
    T_CP_READS  mtval, mtval
    T_CP_WRITES mtval, mtval, 0, 4, 4

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  mstatus, mie, mip: flip, set and clear one harmless bit
 * ======================================================================= */
test_cp_state_csrs:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    T_CP_READS  mstatus, mstatus
    T_CP_WRITES mstatus, mstatus, CP_MSTATUS_K, CP_TW, 2
    T_CP_READS  mie, mie
    T_CP_WRITES mie, mie, -1, 8, 8
    T_CP_READS  mip, mip
    T_CP_WRITES mip, mip, 2, 2, 2

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  misa (writes that change nothing) and mtvec (MODE bit only); no
 *  CSRRWI for either
 * ======================================================================= */
test_cp_misa_mtvec:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    T_CP_READS misa, misa
    T_CP misa, -1, none, 0,    same, 1, "CSRRW rd, misa, rs1 (unchanged value)",  csrrw  a3, misa, a4
    T_CP misa, -1, none, 0,    same, 0, "CSRRW x0, misa, rs1 (unchanged value)",  csrrw  x0, misa, a4
    T_CP misa, -1, none, 0,    same, 1, "CSRRS rd, misa, rs1 (bits already set)", csrrs  a3, misa, a4
    T_CP misa, -1, none, 0,    inv,  1, "CSRRC rd, misa, rs1 (bits already clear)", csrrc a3, misa, a4
    T_CP misa, -1, none, 0,    none, 1, "CSRRSI rd, misa, 4 (C, already set)",    csrrsi a3, misa, 4
    T_CP misa, -1, none, 0,    none, 1, "CSRRCI rd, misa, 0x18 (D, E, already clear)", csrrci a3, misa, 0x18

    T_CP_READS  mtvec, mtvec
    T_CP_WRITES mtvec, mtvec, -1, 1, 1, 0

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret
