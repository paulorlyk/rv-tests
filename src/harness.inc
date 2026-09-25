/* =====================================================================
 * harness.inc  --  test-side macros for the reporting harness in
 *                  common.S, .include'd by every category file (after
 *                  xlen.inc). Macros and .equ constants only;
 *                  defines no symbols.
 *
 * TEST_BEGIN name -- announce a test before any of its code runs:
 * test_begin(name) opens the name's instruction group ("<INSN>:", see
 * "Output format" in common.S) at once and remembers the name until
 * the check() that reports it. A test that traps (UNEXPECTED TRAP)
 * therefore gets its own name in the trap report, not the name of the
 * test before it, and one that hangs leaves its instruction group as
 * the last line on the UART.
 *
 * Fully register-transparent: ra and a0 are saved on the stack around
 * the call and test_begin preserves everything else, so the macro can
 * sit anywhere sp is valid, before or between a test's own setup. It
 * must not sit where sp/gp are being swept as operands (the la is
 * pinned pc-relative with norelax, but the call itself uses the stack).
 * Encoded uncompressed regardless of the surrounding .option rvc, so
 * its size is fixed. A check() whose name was never announced opens
 * its instruction group itself, so it still reports in full.
 *
 * The bitx cases don't use this macro: BX_ENTER (bitx.inc) announces
 * each case itself.
 *
 * TRAP_ARM resume / TRAP_DISARM / TRAP_LD reg, field -- the test side
 * of common.S's armed trap mode, for tests that trap on purpose (ECALL,
 * EBREAK, anything illegal in U-mode, an interrupt out of WFI).
 * TRAP_ARM stores the resume address in trap_resume; the next trap,
 * whatever its cause or privilege mode, records mcause/mepc/mtval/
 * mstatus as they were on entry, bumps trap_count, disarms and resumes
 * at that address in M-mode (see trap_handler in common.S). TRAP_DISARM
 * clears trap_resume, for the path where the expected trap never came.
 * TRAP_LD reg, mcause|mepc|mtval|mstatus loads one of the records into
 * reg. TRAP_ARM and TRAP_DISARM are register-transparent (they use the
 * stack, like TEST_BEGIN); all three are pc-relative, never
 * gp-relative.
 *
 * TRAP_DISARM_R reg -- TRAP_DISARM without the stack, for where sp may
 * still be swept as an operand; clobbers reg.
 *
 * TRAP_REPORT name / TRAP_FAILS resume, name... -- the armed mode as a
 * guard against an instruction under test that traps when it shouldn't
 * (unimplemented: mcause 2; or an access fault from a misdecoded
 * address). The test arms before that instruction and disarms after
 * it; TRAP_FAILS, placed after the test's own checks, jumps over a
 * resume path at label `resume` that calls check_trap (common.S) for
 * each name in turn -- one per check the test makes -- so a trapping
 * instruction is a FAIL per check with its mcause and mepc, never an
 * UNEXPECTED TRAP hang, and the count of result lines is the same
 * either way. A test that sweeps sp/gp/tp restores them at its resume
 * label before reporting (BX_TRAP_FAILS in bitx.inc does it for the
 * bitx cases). TRAP_REPORT is the single-name report on its own.
 *
 * SYNC_I tmp -- FENCE.I if the hart has it (common.S's has_fencei
 * probe at reset), nothing otherwise; clobbers tmp. For instruction-
 * fetch synchronisation that is test machinery, not the thing under
 * test (the bitx sled). The Zifencei suite's own FENCE.Is are armed
 * instead.
 *
 * The MSTATUS_* / MIE_* constants are the bits those tests look at.
 * ===================================================================== */

    .equ MSTATUS_MIE,  0x8          /* bit 3 */
    .equ MSTATUS_MPIE, 0x80         /* bit 7 */
    .equ MSTATUS_MPP,  0x1800       /* bits 12:11; 3 = M, 0 = U */
    .equ MSTATUS_MPRV, 0x20000      /* bit 17 */
    .equ MSTATUS_TW,   0x200000     /* bit 21 */
    .equ MIE_MTIE,     0x80         /* bit 7, also mip.MTIP */

.macro TEST_BEGIN name
    .option push
    .option norvc
    .option norelax
    addi    sp, sp, -16
    REG_S   a0, 0(sp)
    REG_S   ra, 8(sp)
    la      a0, \name
    call    test_begin
    REG_L   a0, 0(sp)
    REG_L   ra, 8(sp)
    addi    sp, sp, 16
    .option pop
.endm

.macro TRAP_ARM resume
    .option push
    .option norvc
    .option norelax
    addi    sp, sp, -16
    REG_S   t0, 0(sp)
    REG_S   t1, 8(sp)
    la      t0, \resume
    la      t1, trap_resume
    REG_S   t0, 0(t1)
    REG_L   t0, 0(sp)
    REG_L   t1, 8(sp)
    addi    sp, sp, 16
    .option pop
.endm

.macro TRAP_DISARM
    .option push
    .option norvc
    .option norelax
    addi    sp, sp, -16
    REG_S   t1, 0(sp)
    la      t1, trap_resume
    REG_S   zero, 0(t1)
    REG_L   t1, 0(sp)
    addi    sp, sp, 16
    .option pop
.endm

.macro TRAP_LD reg, field
    .option push
    .option norvc
    .option norelax
    REG_L   \reg, trap_\field
    .option pop
.endm

.macro TRAP_DISARM_R reg
    .option push
    .option norvc
    .option norelax
    la      \reg, trap_resume
    REG_S   zero, 0(\reg)
    .option pop
.endm

.macro TRAP_REPORT name
    .option push
    .option norvc
    .option norelax
    TRAP_LD a1, mcause
    TRAP_LD a2, mepc
    la      a0, \name
    call    check_trap
    .option pop
.endm

.macro TRAP_FAILS resume, names:vararg
    .option push
    .option norvc
    j       .Ltrap_fails_done\@
\resume:
    .irp    n, \names
    TRAP_REPORT \n
    .endr
.Ltrap_fails_done\@:
    .option pop
.endm

.macro SYNC_I tmp
    .option push
    .option norvc
    .option norelax
    lw      \tmp, has_fencei
    beqz    \tmp, .Lsync_i_skip\@
    fence.i
.Lsync_i_skip\@:
    .option pop
.endm
