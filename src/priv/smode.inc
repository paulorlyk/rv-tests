/* =====================================================================
 * priv/smode.inc  --  shared S-mode machinery for the privileged
 *                     suite's supervisor-mode files (smode.S, sret.S,
 *                     deleg.S, sirq.S, scsr.S, counteren.S, sfence.S),
 *                     .include'd after xlen.inc and harness.inc.
 *
 * Macros and .equ constants only, like harness.inc and bitx.inc: the
 * S-mode trap handler and its record are emitted by SM_HANDLER_CODE,
 * which each including file instantiates once, so each file keeps its
 * own (file-local, non-global) copy and still exposes exactly one
 * entry point.
 *
 * THE S-MODE TRAP HANDLER (SM_HANDLER_CODE, at sm_shandler). A trap
 * delegated to S-mode (medeleg/mideleg) goes to stvec in S-mode, where
 * common.S's armed handler can't see it. So every file points stvec at
 * sm_shandler (SM_SETUP), which, in S-mode:
 *   - records scause, sepc, stval and sstatus as they were on entry
 *     (sm_scause/_sepc/_stval/_sstatus, read with SM_SLD) and bumps
 *     sm_scount;
 *   - then executes ECALL. That is an environment call from S-mode
 *     (cause 9), which no test ever delegates, so it goes to M-mode --
 *     to common.S's handler, which the test has armed (TRAP_ARM) -- and
 *     resumes the test at its resume label in M-mode.
 * So a trap that should be delegated shows up as: sm_scount + 1 with
 * the right scause, and one M-mode trap with mcause 9 and MPP = 1 (the
 * handler's ECALL). A trap that should NOT be delegated goes straight
 * to the armed handler: sm_scount unchanged, mcause = its own cause.
 * Both ways end at the resume label, so a wrongly delegated (or wrongly
 * not delegated) trap is a FAIL, never a hang. The handler uses no
 * stack and clobbers only t0 and t1 (of the interrupted S/U-mode code;
 * the test is resumed in M-mode and keeps nothing there). The one path
 * that could loop is an ECALL from S-mode that the hart delegates to
 * S-mode although medeleg[9] = 0; that is a documented assumption.
 *
 * The record is poisoned (all ones) by SM_SCLEAR before each test, so a
 * check that reads it can't pass on what an earlier test left there
 * (bug class 4 in CLAUDE.md).
 *
 * ENTERING S- AND U-MODE. SM_TO_S / SM_TO_U reg: MRET with MPP = S
 * (1) or U (0), MPIE = 0 (so M-mode's MIE comes out 0 below M, see
 * "Every hand-written MRET clears MPIE first" in CLAUDE.md), mepc = reg.
 * satp is 0 (Bare, SM_SETUP): S- and U-mode run the code in place,
 * through common.S's all-memory PMP entry.
 *
 * SM_RUN mode, insn -- the workhorse for "this instruction in this
 * mode": runs insn once in S- or U-mode, armed, with an ECALL after it
 * as the backstop, and leaves s2 = insn's address, s3 = M-mode traps
 * taken, s8 = S-mode traps taken. T_SM_ILL checks that it trapped into
 * M-mode as an illegal instruction; T_SM_OK that it ran without
 * trapping (the backstop ECALL is the first trap).
 *
 * CLEANUP. sm_clean (instantiated by SM_HANDLER_CODE, called after
 * every test that changes S-mode state and on the way out of each
 * file) puts medeleg, mideleg, the S-mode interrupt-enable stack, the
 * S-level mip bits, mie and the mstatus trap bits (TSR, TW, TVM, MPRV,
 * MIE, MPIE) back to 0. Every write to a CSR that only exists with
 * S-mode runs armed and on its own, so on a hart without S-mode the
 * cleanup steps over the ones that trap instead of hanging.
 *
 * WITHOUT S-MODE (misa.S = 0) every test here still reaches its checks:
 * the first S-mode CSR access, SRET, or delegation-dependent step traps
 * into the armed handler, which resumes the test, and its checks FAIL.
 * ===================================================================== */

    /* mstatus / sstatus */
    .equ MSTATUS_SIE,    0x2            /* bit 1 */
    .equ MSTATUS_SPIE,   0x20           /* bit 5 */
    .equ MSTATUS_SPP,    0x100          /* bit 8 */
    .equ MSTATUS_MPP_S,  0x800          /* MPP = 1 */
    .equ MSTATUS_SUM,    0x40000        /* bit 18 */
    .equ MSTATUS_MXR,    0x80000        /* bit 19 */
    .equ MSTATUS_TVM,    0x100000       /* bit 20 */
    .equ MSTATUS_TSR,    0x400000       /* bit 22 */
    /* the trap-control bits sm_clean resets */
    .equ SM_MSTATUS_CLR, (MSTATUS_MIE | MSTATUS_MPIE | MSTATUS_MPRV | MSTATUS_TW | MSTATUS_TVM | MSTATUS_TSR)
    .equ SM_SSTATUS_CLR, (MSTATUS_SIE | MSTATUS_SPIE | MSTATUS_SPP)

    /* mie / mip (and sie / sip) */
    .equ MIP_SSIP,       0x2            /* bit 1 */
    .equ MIP_MSIP,       0x8            /* bit 3 */
    .equ MIP_STIP,       0x20           /* bit 5 */
    .equ MIP_MTIP,       0x80           /* bit 7 */
    .equ MIP_SEIP,       0x200          /* bit 9 */
    .equ MIP_MEIP,       0x800          /* bit 11 */
    .equ SM_S_IRQS,      (MIP_SSIP | MIP_STIP | MIP_SEIP)

    /* medeleg bits (exception causes) */
    .equ EDELEG_ILL,     1 << 2         /* illegal instruction */
    .equ EDELEG_BRK,     1 << 3         /* breakpoint */
    .equ EDELEG_ECALL_U, 1 << 8
    .equ EDELEG_ECALL_S, 1 << 9
    .equ EDELEG_ECALL_M, 1 << 11

    .equ MISA_S,         1 << 18

    .equ SM_PAT,  0x5ac3a55a3cc3a5c3    /* rd's preset value (LIXT) */
    .equ SM_SPIN, 1000                  /* iterations of a bounded spin */

/* SM_COUNT reg -- reg = trap_count (M-mode traps, common.S). */
.macro SM_COUNT reg
    .option push
    .option norelax
    lw      \reg, trap_count
    .option pop
.endm

/* SM_SCOUNT reg -- reg = sm_scount (S-mode traps, sm_shandler). */
.macro SM_SCOUNT reg
    .option push
    .option norelax
    lw      \reg, sm_scount
    .option pop
.endm

/* SM_SLD reg, scause|sepc|stval|sstatus -- one field of the S record. */
.macro SM_SLD reg, field
    .option push
    .option norelax
    REG_L   \reg, sm_\field
    .option pop
.endm

/* SM_SCLEAR -- poison the S record (all ones). Clobbers t0, t1. */
.macro SM_SCLEAR
    .option push
    .option norelax
    la      t0, sm_scause
    li      t1, -1
    REG_S   t1, 0(t0)
    REG_S   t1, REG_BYTES(t0)
    REG_S   t1, (2 * REG_BYTES)(t0)
    REG_S   t1, (3 * REG_BYTES)(t0)
    .option pop
.endm

/* SM_FIELD rd, rs, shift, mask -- rd = (rs >> shift) & mask */
.macro SM_FIELD rd, rs, shift, mask
    srli    \rd, \rs, \shift
    andi    \rd, \rd, \mask
.endm

/* SM_CHK name, expected, actual -- check(name, LIX expected, actual).
 * actual must not be a0/a1. */
.macro SM_CHK name, exp, act
    la      a0, \name
    LIX     a1, \exp
    mv      a2, \act
    call    check
.endm

/* SM_CHKR name, expected, actual -- same, expected in a register (not
 * a0/a2). */
.macro SM_CHKR name, exp, act
    la      a0, \name
    mv      a1, \exp
    mv      a2, \act
    call    check
.endm

/* SM_NAME label, text -- define a test name string at label in .rodata. */
.macro SM_NAME label, text
    .pushsection .rodata
\label: .asciz "\text"
    .popsection
.endm

/* SM_TO_S reg / SM_TO_U reg -- MRET into S-mode / U-mode at the address
 * in reg, with MPIE = 0. Clobbers t0 (reg must not be t0). */
.macro SM_TO_S reg
    li      t0, MSTATUS_MPP | MSTATUS_MPIE
    csrc    mstatus, t0
    li      t0, MSTATUS_MPP_S
    csrs    mstatus, t0
    csrw    mepc, \reg
    mret
.endm

.macro SM_TO_U reg
    li      t0, MSTATUS_MPP | MSTATUS_MPIE
    csrc    mstatus, t0
    csrw    mepc, \reg
    mret
.endm

/* SM_TO mode, reg -- SM_TO_S or SM_TO_U by mode (S or U). */
.macro SM_TO mode, reg
    .ifc \mode, S
    SM_TO_S \reg
    .else
    SM_TO_U \reg
    .endif
.endm

/* SM_SETUP -- stvec = sm_shandler (direct mode), satp = 0 (Bare). Armed
 * and one at a time, so a hart without S-mode steps over them.
 * Clobbers t0. */
.macro SM_SETUP
    .option push
    .option norelax
    TRAP_ARM .Lsm_setup1\@
    la      t0, sm_shandler
    csrw    stvec, t0
    TRAP_DISARM
.Lsm_setup1\@:
    TRAP_ARM .Lsm_setup2\@
    csrw    satp, zero
    TRAP_DISARM
.Lsm_setup2\@:
    .option pop
.endm

/* SM_RUN mode, insn -- run insn once in mode (S or U) with the handler
 * armed and an ECALL after it as the backstop (see the file header).
 * Leaves s2 = insn's address, s3 = M-mode traps taken, s8 = S-mode
 * traps taken. Clobbers t0, t1. */
.macro SM_RUN mode, insn:vararg
    SM_SCLEAR
    SM_COUNT s3
    SM_SCOUNT s8
    .option push
    .option norelax
    la      s2, .Lsmr_at\@
    .option pop
    TRAP_ARM .Lsmr_back\@
    SM_TO   \mode, s2
.Lsmr_at\@:
    \insn
    ecall                           /* backstop */
.Lsmr_back\@:
    TRAP_DISARM
    SM_COUNT t0
    sub     s3, t0, s3
    SM_SCOUNT t0
    sub     s8, t0, s8
.endm

/* SM_ONCE_M reg -- reg = s3 + 16 * s8: 1 = exactly one trap, taken in
 * M-mode (none in S-mode). Clobbers t0. */
.macro SM_ONCE_M reg
    slli    t0, s8, 4
    add     \reg, s3, t0
.endm

/* SM_PRE pre -- the setup hook of T_SM_ILL / T_SM_OK: pre is "-" for
 * none, or a quoted line of code (a macro call, say) that runs after
 * the test's TEST_BEGIN and before SM_RUN. */
.macro SM_PRE pre
    .ifnc "\pre", "-"
    \pre
    .endif
.endm

/* T_SM_ILL pre, mode, rd, desc, insn -- insn, run in mode (S or U) after
 * the setup pre (SM_PRE), must be
 * an illegal-instruction trap into M-mode. rd = 1 if insn writes a3,
 * which is preset to SM_PAT and checked unchanged. Names are
 * "<desc> in <mode>-mode: ...". Checks: exactly one trap, into M-mode;
 * mcause 2; mepc on insn; MPP = mode; a3 unchanged. Uses s2-s4, s8;
 * clobbers t0-t3. */
.macro T_SM_ILL pre, mode, rd, desc, insn:vararg
    SM_NAME .Lsmi_once\@,  "\desc in \mode-mode: traps exactly once, into M-mode"
    SM_NAME .Lsmi_cause\@, "\desc in \mode-mode: mcause == 2 (illegal instruction)"
    SM_NAME .Lsmi_mepc\@,  "\desc in \mode-mode: mepc == the instruction"
    SM_NAME .Lsmi_mpp\@,   "\desc in \mode-mode: trap entry MPP == \mode"
    .if \rd
    SM_NAME .Lsmi_rd\@,    "\desc in \mode-mode: rd not written"
    .endif

    TEST_BEGIN .Lsmi_once\@
    SM_PRE  "\pre"
    LIXT    a3, SM_PAT
    SM_RUN  \mode, \insn
    mv      s4, a3
    SM_ONCE_M t2
    SM_CHK  .Lsmi_once\@, 1, t2
    TEST_BEGIN .Lsmi_cause\@
    TRAP_LD t2, mcause
    SM_CHK  .Lsmi_cause\@, 2, t2
    TEST_BEGIN .Lsmi_mepc\@
    TRAP_LD t2, mepc
    SM_CHKR .Lsmi_mepc\@, s2, t2
    TEST_BEGIN .Lsmi_mpp\@
    TRAP_LD t2, mstatus
    SM_FIELD t2, t2, 11, 3
    .ifc \mode, S
    SM_CHK  .Lsmi_mpp\@, 1, t2
    .else
    SM_CHK  .Lsmi_mpp\@, 0, t2
    .endif
    .if \rd
    TEST_BEGIN .Lsmi_rd\@
    LIXT    t3, SM_PAT
    SM_CHKR .Lsmi_rd\@, t3, s4
    .endif
.endm

/* T_SM_OK pre, mode, desc, insn -- insn, run in mode after the setup
 * pre (SM_PRE), must not trap: the
 * first (and only) trap is the backstop ECALL after it, in M-mode
 * (mepc = insn + 4, mcause 8 from U / 9 from S). One check. Leaves a3
 * (preset to SM_PAT) in s4 for the caller's own checks. Uses s2-s4,
 * s8; clobbers t0-t3. */
.macro T_SM_OK pre, mode, desc, insn:vararg
    SM_NAME .Lsmo_ok\@, "\desc in \mode-mode: doesn't trap (the ECALL after it is the only trap)"
    TEST_BEGIN .Lsmo_ok\@
    SM_PRE  "\pre"
    LIXT    a3, SM_PAT
    SM_RUN  \mode, \insn
    mv      s4, a3
    /* t2 = 1 if: one trap, in M-mode, at s2 + 4, with the ECALL's cause */
    SM_ONCE_M t2
    addi    t2, t2, -1
    TRAP_LD t0, mepc
    addi    t1, s2, 4
    sub     t0, t0, t1
    or      t2, t2, t0
    TRAP_LD t0, mcause
    .ifc \mode, S
    addi    t0, t0, -9
    .else
    addi    t0, t0, -8
    .endif
    or      t2, t2, t0
    seqz    t2, t2
    SM_CHK  .Lsmo_ok\@, 1, t2
.endm

/* SM_HANDLER_CODE -- instantiate, once per including file (in .text):
 * sm_shandler (see the file header), sm_clean, and the S record in
 * .bss. */
.macro SM_HANDLER_CODE
    .balign 4
sm_shandler:
    .option push
    .option norelax
    la      t0, sm_scause
    csrr    t1, scause
    REG_S   t1, 0(t0)
    csrr    t1, sepc
    REG_S   t1, REG_BYTES(t0)
    csrr    t1, stval
    REG_S   t1, (2 * REG_BYTES)(t0)
    csrr    t1, sstatus
    REG_S   t1, (3 * REG_BYTES)(t0)
    lw      t1, (4 * REG_BYTES)(t0)     /* sm_scount */
    addi    t1, t1, 1
    sw      t1, (4 * REG_BYTES)(t0)
    ecall                           /* to M-mode: resumes the test */
    .option pop

/* sm_clean: see the file header. Clobbers t0. */
sm_clean:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)
    li      t0, SM_MSTATUS_CLR
    csrc    mstatus, t0
    csrw    mie, zero
    li      t0, SM_S_IRQS
    csrc    mip, t0
    TRAP_ARM 1f
    csrw    medeleg, zero
    TRAP_DISARM
1:  TRAP_ARM 2f
    csrw    mideleg, zero
    TRAP_DISARM
2:  TRAP_ARM 3f
    li      t0, SM_SSTATUS_CLR
    csrc    sstatus, t0
    TRAP_DISARM
3:  REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

    .pushsection .bss
    .balign 8
sm_scause:  REG_DATA 0              /* the last S-mode trap, on entry */
sm_sepc:    REG_DATA 0
sm_stval:   REG_DATA 0
sm_sstatus: REG_DATA 0
sm_scount:  .word 0                 /* S-mode traps taken */
    .word 0
    .popsection
.endm
