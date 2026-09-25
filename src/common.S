/* =====================================================================
 * common.S  --  bare-metal M-mode test harness (boot / UART / reporter)
 *
 * This file has no knowledge of what is being tested. It provides the
 * reusable boot + I/O + pass/fail-reporting infrastructure that any
 * instruction-set test suite can sit on top of:
 *
 *   - reset vector / M-mode entry at 0x80000000, gp setup, .bss
 *     zeroing, sp/mtvec setup
 *   - a minimal M-mode trap handler on a private stack (expects only
 *     C.EBREAK, reports and hangs on anything else -- unless a test has
 *     armed it with trap_resume, see below)
 *   - a FENCE.I probe at reset (has_fencei, for SYNC_I in harness.inc)
 *   - an ns16550a UART driver (init for 115200 8N1, putc/puts, hex/dec
 *     printing)
 *   - "check": a generic named pass/fail comparator that prints
 *     failures and one OK/FAIL per instruction over the UART (see
 *     "Output format" below) and tracks a running failure count, and
 *     "check_trap", the FAIL for a check whose instruction trapped
 *   - the top-level summary/halt sequence; if anything failed, the
 *     summary lists the first FAIL_LOG_MAX failed checks with their
 *     expected and actual values
 *
 * It calls out to a single external entry point, run_tests, which the
 * actual test-suite file (e.g. c/tests.S) must define as .global.
 * run_tests should print its own banner (after insn_close, which ends
 * the previous suite's last instruction group), run whatever it wants
 * (using "check" to report each case), and ret when done -- fail_count will
 * already reflect every check() call by then. This is the seam meant
 * for adding new suites later: a new test file just needs to provide
 * its own run_tests (and can freely reuse uart_puts/check/etc. from
 * here), and gets linked in alongside or instead of this one.
 *
 * Runs entirely in M-mode. Assembles to a single flat binary that must
 * be loaded at physical address 0x80000000 and entered at that address
 * (reset vector / -kernel style boot).
 *
 * An ns16550a UART sits at 0x10000000 with 1-byte register stride (the
 * common QEMU-virt style mapping):
 *   +0 RBR/THR/DLL   +1 IER/DLM   +2 IIR/FCR   +3 LCR
 *   +4 MCR           +5 LSR       +6 MSR       +7 SCR
 * LSR bit 5 (0x20) = THRE (transmit holding register empty).
 * At boot, uart_init() programs it for 115200 8N1: interrupts off, DLAB
 * set to load the baud divisor, then DLAB cleared with LCR = 8 data
 * bits / no parity / 1 stop bit, FIFOs enabled, and modem control
 * lines (DTR/RTS/OUT2) asserted. See UART_CLK_HZ below -- the divisor
 * is computed from it at assemble time, so if your UART's reference
 * clock differs from the 1.8432 MHz default assumed here, change that
 * one constant and everything else follows.
 *
 * Build: see the Makefile, which assembles every file twice, for RV64
 * and RV32 (--defsym XLEN=64|32, see xlen.inc). common.o must be listed
 * first at link time, so that _start ends up at the very base of .text,
 * i.e. at the 0x80000000 load address.
 * ===================================================================== */

    .include "xlen.inc"

    .option norvc           /* this file is hand-written plain RV[64|32]IMA; */
                             /* keep the assembler from silently          */
                             /* compressing it, so the disassembly stays  */
                             /* predictable. Each test-suite file makes   */
                             /* its own choice for the code it owns. */

    .equ UART_BASE, 0x10000000
    .equ UART_RBR,  0              /* receive buffer (read), DLAB=0 */
    .equ UART_THR,  0              /* transmit holding (write), DLAB=0 */
    .equ UART_DLL,  0              /* divisor latch low, DLAB=1 */
    .equ UART_IER,  1              /* interrupt enable, DLAB=0 */
    .equ UART_DLM,  1              /* divisor latch high, DLAB=1 */
    .equ UART_FCR,  2              /* FIFO control (write) */
    .equ UART_LCR,  3              /* line control */
    .equ UART_MCR,  4              /* modem control */
    .equ UART_LSR,  5              /* line status */
    .equ UART_THRE, 0x20           /* LSR: transmit holding reg empty */

    /* --- 115200 8N1 configuration --- */
    .equ UART_CLK_HZ,   1843200    /* ns16550 reference clock; the classic
                                     * PC/16550 value. Change to match your
                                     * actual UART input clock if different
                                     * (e.g. many SoCs use their peripheral
                                     * bus clock instead). */
    .equ UART_BAUD,     115200
    .equ UART_DIVISOR,  (UART_CLK_HZ / (16 * UART_BAUD))
    .equ UART_DIV_LO,   (UART_DIVISOR & 0xff)
    .equ UART_DIV_HI,   ((UART_DIVISOR >> 8) & 0xff)
    .equ UART_LCR_8N1,  0x03       /* 8 data bits, no parity, 1 stop bit */
    .equ UART_LCR_DLAB, 0x80
    .equ UART_FCR_INIT, 0xc7       /* enable FIFO, clear RX/TX, 14-byte trig */
    .equ UART_MCR_INIT, 0x0b       /* DTR | RTS | OUT2 */

/* The summary lists the first FAIL_LOG_MAX failed checks; check() and
 * check_trap() record them in fail_log. An entry is (name, expected,
 * actual, 0) from check(), or (name, mcause, mepc, 1) from
 * check_trap(). */
    .equ FAIL_LOG_MAX,  8
    .equ FAIL_LOG_ENT,  4 * REG_BYTES  /* name ptr, two values, trapped */

/* Symbols other test-suite files are expected to call/reference.
 * run_tests is the one symbol *this* file expects someone else to
 * provide (see file header). */
    .global _start
    .global uart_init
    .global uart_putc
    .global uart_puts
    .global uart_put_hex64
    .global uart_put_dec
    .global check
    .global check_trap
    .global test_begin
    .global insn_close
    .global has_fencei
    .global fail_count
    .global pass_count
    .global ebreak_flag
    .global ebreak_mepc
    .global ebreak_mcause
    .global ebreak_hit_count
    .global trap_resume
    .global trap_count
    .global trap_mcause
    .global trap_mepc
    .global trap_mtval
    .global trap_mstatus

/* ----------------------------------------------------------------------
 * Header / vector area. We keep this minimal: a single instruction at
 * the load/entry address that jumps to the real start, immediately
 * followed by the M-mode trap handler (must be 4-byte aligned, which
 * it naturally is here).
 * -------------------------------------------------------------------- */
    .section .text
    .align 2
_start:
    j       reset

    .align 4
trap_handler:
    /* Minimal M-mode trap handler. Unarmed, we only *expect* to ever
     * land here from a deliberate C.EBREAK test (mcause == 3,
     * breakpoint). Anything else is a genuine failure (e.g. illegal
     * instruction because the target doesn't really implement an
     * extension being tested) and we report it and hang, since
     * continuing would be meaningless.
     *
     * ARMED (trap_resume != 0): the one mode for tests that trap on
     * purpose in any other way -- ECALL, the 4-byte EBREAK, an
     * instruction that must be illegal in U-mode, an interrupt taken
     * out of WFI. The test stores a resume address in trap_resume
     * (TRAP_ARM in harness.inc) before the trapping instruction. The
     * next trap, whatever its cause and from whatever privilege mode,
     * then records mcause, mepc, mtval and mstatus as they were on
     * entry (trap_mcause/_mepc/_mtval/_mstatus), bumps trap_count,
     * disarms (one-shot), and returns with MRET to the resume address
     * in M-mode (MPP is set to M first; MIE comes back from MPIE, as
     * any MRET does). For an interrupt it also clears mie, so the
     * source can't fire again the moment MRET re-enables interrupts;
     * the test re-programs whatever raised it. So the test itself
     * judges the cause, and a trap it didn't expect comes out as a
     * FAIL with the recorded mcause rather than as a hang.
     *
     * PRIVATE STACK. The handler never touches the interrupted code's
     * sp: a bitx case may be sweeping sp as an operand (holding a pool
     * value, or the address of the very buffer under test) when its
     * instruction traps. So t0 is parked in mscratch, sp is saved at
     * the top of trap_stack and replaced by it, and trap_return puts
     * it back. mscratch holds nothing the handler relies on, so any
     * value a test left there is fine -- but a trap overwrites it
     * (the Zicsr tests write and read it back with no trap between).
     * The whole handler is norelax: gp may be swept too. */
    .option push
    .option norelax
    csrw    mscratch, t0
    la      t0, trap_stack_top
    REG_S   sp, -16(t0)             /* the interrupted sp */
    addi    sp, t0, -16
    csrr    t0, mscratch
    addi    sp, sp, -32
    REG_S   t0, 0(sp)
    REG_S   t1, 8(sp)
    REG_S   a0, 16(sp)
    REG_S   ra, 24(sp)

    la      t1, trap_resume
    REG_L   t0, 0(t1)
    bnez    t0, trap_armed

    csrr    t0, mcause
    li      t1, 3                   /* 3 = breakpoint exception */
    bne     t0, t1, trap_unexpected

    /* Expected EBREAK: record mcause and the raw (pre-advance) mepc so
     * the test suite can check both explicitly rather than trusting
     * this handler's own internal comparison above, bump a hit
     * counter (so a test can confirm the trap really fires every time
     * across repeated EBREAKs, not just once), set the "we got here"
     * flag, then skip past the instruction (mepc += 2 assumes a
     * compressed C.EBREAK; the uncompressed EBREAK is tested through
     * the armed mode below, which resumes at an explicit address
     * instead) and resume. */
    la      t1, ebreak_mcause
    sw      t0, 0(t1)

    csrr    t0, mepc
    la      t1, ebreak_mepc
    REG_S   t0, 0(t1)

    la      t1, ebreak_hit_count
    lw      t0, 0(t1)
    addi    t0, t0, 1
    sw      t0, 0(t1)

    la      t1, ebreak_flag
    li      t0, 1
    sw      t0, 0(t1)
    csrr    t0, mepc
    addi    t0, t0, 2
    csrw    mepc, t0

trap_return:
    REG_L   t0, 0(sp)
    REG_L   t1, 8(sp)
    REG_L   a0, 16(sp)
    REG_L   ra, 24(sp)
    addi    sp, sp, 32
    REG_L   sp, 0(sp)               /* back to the interrupted sp */
    mret

/* Armed (see above): t0 = resume address, t1 = &trap_resume. */
trap_armed:
    REG_S   zero, 0(t1)             /* one-shot: disarm */
    la      t1, trap_mcause
    csrr    a0, mcause
    REG_S   a0, 0(t1)
    la      t1, trap_mepc
    csrr    a0, mepc
    REG_S   a0, 0(t1)
    la      t1, trap_mtval
    csrr    a0, mtval
    REG_S   a0, 0(t1)
    la      t1, trap_mstatus
    csrr    a0, mstatus
    REG_S   a0, 0(t1)
    la      t1, trap_count
    lw      a0, 0(t1)
    addi    a0, a0, 1
    sw      a0, 0(t1)

    csrw    mepc, t0                /* resume there ... */
    li      t0, 0x1800              /* ... in M-mode: MPP = 3 */
    csrs    mstatus, t0
    csrr    t0, mcause
    bgez    t0, trap_return         /* an exception: done */
    csrw    mie, zero               /* an interrupt: silence its source */
    j       trap_return
    .option pop

/* pmp_skip: mtvec during reset's PMP setup only. A PMP CSR write that
 * traps (no PMP on this hart) is skipped: mepc += 4 (common.S is
 * norvc, so every instruction here is 4 bytes) and back. Clobbers t1;
 * the trap came from M-mode, so MRET returns to M-mode. */
    .align 2
pmp_skip:
    csrr    t1, mepc
    addi    t1, t1, 4
    csrw    mepc, t1
    mret

trap_unexpected:
    .option push
    .option norelax
    la      t1, pending_name        /* the test that trapped, if it was */
    REG_L   a0, 0(t1)               /* announced: "<name> - " first */
    beqz    a0, 1f
    jal     ra, uart_puts
    la      a0, str_dots
    jal     ra, uart_puts
1:  la      a0, str_unexpected_trap
    jal     ra, uart_puts
    csrr    a0, mcause
    jal     ra, uart_put_hex64
    la      a0, str_newline
    jal     ra, uart_puts
    .option pop
trap_hang:
    j       trap_hang

/* ----------------------------------------------------------------------
 * Real entry point
 * -------------------------------------------------------------------- */
reset:
    /* The linker enables relaxation by default, which can turn later
     * "la reg, symbol" sequences into a single gp-relative addi if the
     * symbol lands near __global_pointer$. gp is NOT initialised by
     * hardware at reset, so we must set it up first (with relaxation
     * disabled for this one instruction, to avoid a chicken-and-egg
     * gp-relative load of gp itself). */
    .option push
    .option norelax
    la      gp, __global_pointer$
    .option pop

    /* Zero .bss (__bss_start .. _end, from the default linker script).
     * It isn't part of the flat .bin (objcopy leaves NOBITS sections
     * out), so on hardware it holds whatever RAM held at power-on: every
     * counter, flag and buffer there -- fail_count, trap_resume,
     * bitx.S's bx_ready -- must start from zero here, not from the
     * loader. Both ends are 4-byte aligned. Nothing uses the stack (or
     * any .bss) before this. */
    la      t0, __bss_start
    la      t1, _end
1:  bgeu    t0, t1, 2f
    sw      zero, 0(t0)
    addi    t0, t0, 4
    j       1b
2:

    /* No interrupts until a test asks for one. mstatus.MIE resets to 0,
     * but mie's reset value is left to the implementation, so clear
     * both: only priv/wfi.S and priv/irqpriv.S enable a source, and
     * each leaves mie = 0 again when it is done. */
    csrci   mstatus, 0x8            /* mstatus.MIE = 0 */
    csrw    mie, zero

    la      sp, stack_top
    la      t0, trap_handler        /* direct mode, low 2 bits = 0 */
    csrw    mtvec, t0

    /* Let U-mode reach all of memory: PMP entry 0 = NAPOT over the
     * whole address space, R/W/X, not locked (so M-mode is unaffected).
     * Without it, once any PMP entry is implemented, every U-mode
     * access fails -- and the suites that drop to U-mode (ECALL/EBREAK
     * from U, MRET, WFI) run their U-mode code in place.
     *
     * A hart with no PMP entries needs none of this (U-mode then has
     * full access), but may not tolerate it either: the 1.12 spec makes
     * the PMP CSRs read-only zero there, while older cores -- and QEMU
     * with pmp=false -- raise an illegal-instruction trap on them. So
     * the two writes run with mtvec pointing at pmp_skip, which steps
     * over a CSR write that traps; then mtvec goes back to
     * trap_handler. */
    la      t0, pmp_skip
    csrw    mtvec, t0
    li      t0, -1
    csrw    pmpaddr0, t0
    li      t0, 0x1f                /* A = NAPOT, X, W, R */
    csrw    pmpcfg0, t0
    la      t0, trap_handler
    csrw    mtvec, t0

    /* Probe FENCE.I once, through the armed handler: has_fencei = 1 if
     * it executes, stays 0 if it traps (no Zifencei). The shared bitx
     * machinery synchronises instruction fetch with SYNC_I
     * (harness.inc), which skips the FENCE.I when has_fencei is 0, so a
     * hart without Zifencei still runs every suite; only the Zifencei
     * suite's own FENCE.Is (armed, reported by check_trap) fail. */
    la      t0, .Lfencei_probed
    la      t1, trap_resume
    REG_S   t0, 0(t1)
    fence.i
    la      t1, trap_resume
    REG_S   zero, 0(t1)
    li      t0, 1
    la      t1, has_fencei
    sw      t0, 0(t1)
.Lfencei_probed:
    la      t1, trap_count          /* the probe's trap, if any, is not */
    sw      zero, 0(t1)             /* a test's */

    jal     ra, uart_init

    la      t1, has_fencei
    lw      t0, 0(t1)
    bnez    t0, 1f
    la      a0, str_no_fencei
    jal     ra, uart_puts
1:

    call    run_tests           /* provided by the test-suite file */
    jal     ra, insn_close      /* end the last instruction group */

    la      a0, str_summary_pass
    jal     ra, uart_puts
    la      t0, pass_count
    lw      a0, 0(t0)
    jal     ra, uart_put_dec

    la      a0, str_summary_fail
    jal     ra, uart_puts
    la      t0, fail_count
    lw      a0, 0(t0)
    jal     ra, uart_put_dec
    la      a0, str_summary_tail
    jal     ra, uart_puts

    la      t0, fail_count
    lw      a1, 0(t0)
    bnez    a1, halt_fail

    la      a0, str_all_pass
    jal     ra, uart_puts
    j       halt

halt_fail:
    jal     ra, fail_log_print
    la      a0, str_some_fail
    jal     ra, uart_puts
    /* All done: park the hart. WFI lets it idle (or a simulator stop
     * burning host CPU) instead of spinning flat out; nothing enables
     * an interrupt, so it never actually wakes -- and if an
     * implementation treats WFI as a no-op or wakes spuriously, the
     * loop simply goes round again. */
halt:
    wfi
    j       halt

/* =======================================================================
 *  UART driver (plain, non-compressed, hand written)
 * ======================================================================= */

/* uart_init: program the ns16550a for 115200 8N1, polling mode (no
 * interrupts). Clobbers t0, t1. Must run before any uart_putc/uart_puts
 * call, and before gp-relative addressing is needed (it uses only an
 * absolute UART_BASE, so it's safe to call this before "la gp, ..." if
 * you ever reorder startup). */
uart_init:
    li      t0, UART_BASE

    li      t1, 0x00
    sb      t1, UART_IER(t0)        /* disable all UART interrupts */

    li      t1, UART_LCR_DLAB
    sb      t1, UART_LCR(t0)        /* set DLAB to expose DLL/DLM */

    li      t1, UART_DIV_LO
    sb      t1, UART_DLL(t0)
    li      t1, UART_DIV_HI
    sb      t1, UART_DLM(t0)        /* divisor -> 115200 baud (see UART_CLK_HZ) */

    li      t1, UART_LCR_8N1
    sb      t1, UART_LCR(t0)        /* 8 data bits, no parity, 1 stop bit;
                                      * clearing DLAB restores RBR/THR/IER */

    li      t1, UART_FCR_INIT
    sb      t1, UART_FCR(t0)        /* enable + clear FIFOs */

    li      t1, UART_MCR_INIT
    sb      t1, UART_MCR(t0)        /* assert DTR/RTS/OUT2 */
    ret

/* uart_putc: a0 = character to send. Clobbers t0, t1. */
uart_putc:
    li      t0, UART_BASE
1:  lb      t1, UART_LSR(t0)
    andi    t1, t1, UART_THRE
    beqz    t1, 1b
    sb      a0, 0(t0)
    ret

/* uart_puts: a0 = pointer to NUL-terminated string. */
uart_puts:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)
    REG_S   s0, 8(sp)
    mv      s0, a0
1:  lb      a0, 0(s0)
    beqz    a0, 2f
    jal     ra, uart_putc
    addi    s0, s0, 1
    j       1b
2:  REG_L   ra, 0(sp)
    REG_L   s0, 8(sp)
    addi    sp, sp, 16
    ret

/* uart_put_hex64: a0 = value, printed as XLEN/4 hex digits (16 on RV64,
 * 8 on RV32) with 0x prefix. The name is historical. */
uart_put_hex64:
    addi    sp, sp, -32
    REG_S   ra, 0(sp)
    REG_S   s0, 8(sp)
    REG_S   s1, 16(sp)
    mv      s0, a0
    li      s1, XLEN - 4            /* start at the top nibble */
    li      a0, '0'
    jal     ra, uart_putc
    li      a0, 'x'
    jal     ra, uart_putc
1:  srl     t0, s0, s1
    andi    t0, t0, 0xf
    li      t1, 10
    blt     t0, t1, 2f
    addi    a0, t0, ('a' - 10)
    j       3f
2:  addi    a0, t0, '0'
3:  jal     ra, uart_putc
    addi    s1, s1, -4
    bgez    s1, 1b
    REG_L   ra, 0(sp)
    REG_L   s0, 8(sp)
    REG_L   s1, 16(sp)
    addi    sp, sp, 32
    ret

/* uart_put_dec: a0 = unsigned value (small, e.g. a fail counter), printed
 * as decimal. Simple/slow, fine for a test counter. */
uart_put_dec:
    addi    sp, sp, -32
    REG_S   ra, 0(sp)
    REG_S   s0, 8(sp)
    mv      s0, a0
    bnez    s0, 1f
    li      a0, '0'
    jal     ra, uart_putc
    j       9f
1:  addi    sp, sp, -16             /* small digit stack, up to 16 digits */
    li      t2, 0                   /* digit count */
2:  beqz    s0, 3f
    li      t3, 10
    remu    t4, s0, t3
    divu    s0, s0, t3
    addi    t4, t4, '0'
    add     t5, sp, t2
    sb      t4, 0(t5)
    addi    t2, t2, 1
    j       2b
3:  beqz    t2, 4f
    addi    t2, t2, -1
    add     t5, sp, t2
    lb      a0, 0(t5)
    jal     ra, uart_putc
    j       3b
4:  addi    sp, sp, 16
9:  REG_L   ra, 0(sp)
    REG_L   s0, 8(sp)
    addi    sp, sp, 32
    ret

/* ----------------------------------------------------------------------
 * Output format. Results are reported per instruction, not per check:
 *
 *     ECALL:
 *      OK
 *     WFI:
 *     WFI woken by the timer interrupt - FAIL
 *      FAIL
 *
 * The instruction is the first word of a test's name (up to the first
 * space, a trailing ':' or ',' dropped), so every name starts with the
 * mnemonic it tests. When a test's instruction differs from the one
 * before it, the open group is closed with " OK" or " FAIL" (FAIL if
 * any of its checks failed) and "<INSN>:" opens the new one. A passing
 * check prints nothing; a failing one prints its full line,
 * "<name> - FAIL" (check_trap adds the mcause and mepc), inside its
 * group. Groups follow run order, so an instruction whose tests are
 * spread over several places (BEQ, CSRRS, ECALL) gets a group for each
 * run of them. Anything else that prints -- a suite banner, the
 * summary -- closes the open group first (insn_close).
 * -------------------------------------------------------------------- */

/* ----------------------------------------------------------------------
 * test_begin: announce a test before it runs.
 *   a0 = pointer to test-name string (NUL terminated, no newline)
 * Opens the name's instruction group ("<INSN>:") if it isn't the open
 * one, and remembers a0 as the pending name until the matching check()
 * reports it. If the test then takes an unexpected trap, the trap
 * report starts with this name; if it hangs, its instruction group is
 * the last line on the UART. Preserves every register except ra. Test
 * code reaches it through the TEST_BEGIN macro (harness.inc), which
 * saves ra and a0 around the call, so it can go anywhere sp is valid.
 * -------------------------------------------------------------------- */
test_begin:
    addi    sp, sp, -32
    REG_S   ra, 0(sp)
    REG_S   t0, 8(sp)
    REG_S   t1, 16(sp)
    REG_S   a0, 24(sp)
    la      t0, pending_name
    REG_S   a0, 0(t0)
    jal     ra, insn_track
    REG_L   ra, 0(sp)
    REG_L   t0, 8(sp)
    REG_L   t1, 16(sp)
    REG_L   a0, 24(sp)
    addi    sp, sp, 32
    ret

/* insn_key: a0 = test name. Returns a0 = the length of its instruction
 * key: the first word (up to the first space or the NUL), less a
 * trailing ':' or ','. Clobbers t0, t1. */
insn_key:
    mv      t1, a0
1:  lbu     t0, 0(t1)
    beqz    t0, 2f
    addi    t0, t0, -' '
    beqz    t0, 2f
    addi    t1, t1, 1
    j       1b
2:  sub     a0, t1, a0
    beqz    a0, 3f
    lbu     t0, -1(t1)
    addi    t0, t0, -':'
    beqz    t0, 4f
    addi    t0, t0, (':' - ',')
    bnez    t0, 3f
4:  addi    a0, a0, -1
3:  ret

/* insn_track: a0 = test name. If its instruction key differs from the
 * open group's (insn_name/insn_len), close that group and open this
 * one: print "<key>:\r\n" and clear insn_failed. Clobbers only t0, t1
 * and a0 -- no more than check()'s pass path always did, which some
 * tests have come to rely on (a value kept in t2 across a check). */
insn_track:
    addi    sp, sp, -48
    REG_S   ra, 0(sp)
    REG_S   s0, 8(sp)
    REG_S   s1, 16(sp)
    REG_S   s2, 24(sp)
    REG_S   s3, 32(sp)
    mv      s0, a0
    jal     ra, insn_key
    mv      s1, a0                  /* s0/s1 = the new key */
    la      t1, insn_name
    REG_L   s2, 0(t1)
    beqz    s2, 2f                  /* no group open */
    la      t1, insn_len
    lw      t1, 0(t1)
    bne     t1, s1, 2f
    mv      a0, s0
    mv      s3, s1
1:  beqz    s3, 4f                  /* all bytes equal: same group */
    lbu     t0, 0(s2)
    lbu     t1, 0(a0)
    bne     t0, t1, 2f
    addi    s2, s2, 1
    addi    a0, a0, 1
    addi    s3, s3, -1
    j       1b
2:  jal     ra, insn_close
    la      t0, insn_name
    REG_S   s0, 0(t0)
    la      t0, insn_len
    sw      s1, 0(t0)
    la      t0, insn_failed
    sw      zero, 0(t0)
3:  beqz    s1, 5f
    lbu     a0, 0(s0)
    jal     ra, uart_putc
    addi    s0, s0, 1
    addi    s1, s1, -1
    j       3b
5:  la      a0, str_insn_head
    jal     ra, uart_puts
4:  REG_L   ra, 0(sp)
    REG_L   s0, 8(sp)
    REG_L   s1, 16(sp)
    REG_L   s2, 24(sp)
    REG_L   s3, 32(sp)
    addi    sp, sp, 48
    ret

/* insn_close: if an instruction group is open, end it with " OK" or,
 * if any of its checks failed, " FAIL", and close it. Called before
 * the summary and by each suite orchestrator before its banner.
 * Clobbers t0, t1, a0. */
insn_close:
    la      t1, insn_name
    REG_L   t0, 0(t1)
    beqz    t0, 1f
    REG_S   zero, 0(t1)
    addi    sp, sp, -16
    REG_S   ra, 0(sp)
    la      a0, str_insn_ok
    la      t1, insn_failed
    lw      t0, 0(t1)
    beqz    t0, 2f
    la      a0, str_insn_fail
2:  jal     ra, uart_puts
    REG_L   ra, 0(sp)
    addi    sp, sp, 16
1:  ret

/* ----------------------------------------------------------------------
 * check: generic pass/fail reporter.
 *   a0 = pointer to test-name string (NUL terminated, no newline)
 *   a1 = expected value
 *   a2 = actual value
 * Bumps pass_count or fail_count. A pass prints nothing; a failure
 * prints "<name> - FAIL\r\n" and marks the instruction group failed
 * (see "Output format" above; the group is opened here if test_begin
 * didn't). The first FAIL_LOG_MAX failures are also recorded in
 * fail_log (the name pointer, so it must point at a string that stays
 * put -- every caller passes a .rodata label) for the summary to list.
 * Clobbers t0-t6, a0-a2.
 * -------------------------------------------------------------------- */
check:
    addi    sp, sp, -32
    REG_S   ra, 0(sp)
    REG_S   s0, 8(sp)
    REG_S   s1, 16(sp)
    REG_S   s2, 24(sp)
    mv      s0, a1
    mv      s1, a2
    mv      s2, a0
    jal     ra, verdict_begin
    bne     s0, s1, .Lcheck_fail
    j       .Lpass_count
.Lcheck_fail:
    la      t0, fail_count          /* fail_count, before the bump, is */
    lw      t1, 0(t0)               /* this failure's fail_log index */
    li      t2, FAIL_LOG_MAX
    bgeu    t1, t2, 1f              /* log full: counted, not recorded */
    li      t2, FAIL_LOG_ENT
    mul     t1, t1, t2
    la      t0, fail_log
    add     t0, t0, t1
    REG_S   s2, 0(t0)               /* name */
    REG_S   s0, REG_BYTES(t0)       /* expected */
    REG_S   s1, (2 * REG_BYTES)(t0) /* actual */
    REG_S   zero, (3 * REG_BYTES)(t0) /* not a trap */
1:  mv      a0, s2
    jal     ra, fail_prefix
    la      a0, str_fail
    jal     ra, uart_puts
    la      t0, fail_count
    lw      t1, 0(t0)
    addi    t1, t1, 1
    sw      t1, 0(t0)
    j       .Lcheck_done
.Lpass_count:
    la      t0, pass_count
    lw      t1, 0(t0)
    addi    t1, t1, 1
    sw      t1, 0(t0)
.Lcheck_done:
    REG_L   ra, 0(sp)
    REG_L   s0, 8(sp)
    REG_L   s1, 16(sp)
    REG_L   s2, 24(sp)
    addi    sp, sp, 32
    ret

/* verdict_begin: a0 = the name about to get its verdict. Clears the
 * pending test_begin announcement and opens the name's instruction
 * group if it isn't the open one. Clobbers t0, t1, a0; preserves
 * s0-s2 (check/check_trap keep their arguments there). */
verdict_begin:
    la      t0, pending_name
    REG_S   zero, 0(t0)
    j       insn_track

/* fail_prefix: a0 = name of a failing check. Prints "<name> - " and
 * marks the open instruction group failed. Clobbers t0, t1, a0. */
fail_prefix:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)
    la      t0, insn_failed
    li      t1, 1
    sw      t1, 0(t0)
    jal     ra, uart_puts
    la      a0, str_dots
    jal     ra, uart_puts
    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* ----------------------------------------------------------------------
 * check_trap: report a check whose instruction trapped.
 *   a0 = pointer to test-name string (as for check: a .rodata label)
 *   a1 = mcause of the trap
 *   a2 = mepc of the trap
 * Always a failure: prints "<name> - FAIL (trap, mcause=..., mepc=...)"
 * in its instruction group and marks the group failed, bumps
 * fail_count and records (name, mcause, mepc, 1) in fail_log. A test
 * whose instruction under test might be unimplemented runs it armed
 * (TRAP_ARM) and, on the resume path, calls this once for every check
 * it would otherwise have made (TRAP_FAILS / TRAP_REPORT in
 * harness.inc), so the number of result lines doesn't depend on
 * whether it trapped. Clobbers t0-t6, a0-a2.
 * -------------------------------------------------------------------- */
check_trap:
    addi    sp, sp, -32
    REG_S   ra, 0(sp)
    REG_S   s0, 8(sp)
    REG_S   s1, 16(sp)
    REG_S   s2, 24(sp)
    mv      s0, a1
    mv      s1, a2
    mv      s2, a0
    jal     ra, verdict_begin
    la      t0, fail_count
    lw      t1, 0(t0)
    li      t2, FAIL_LOG_MAX
    bgeu    t1, t2, 1f
    li      t2, FAIL_LOG_ENT
    mul     t1, t1, t2
    la      t0, fail_log
    add     t0, t0, t1
    REG_S   s2, 0(t0)               /* name */
    REG_S   s0, REG_BYTES(t0)       /* mcause */
    REG_S   s1, (2 * REG_BYTES)(t0) /* mepc */
    li      t1, 1
    REG_S   t1, (3 * REG_BYTES)(t0) /* a trap */
1:  mv      a0, s2
    jal     ra, fail_prefix
    la      a0, str_fail_trap
    jal     ra, uart_puts
    mv      a0, s0
    jal     ra, uart_put_hex64
    la      a0, str_trap_mepc
    jal     ra, uart_puts
    mv      a0, s1
    jal     ra, uart_put_hex64
    la      a0, str_trap_tail
    jal     ra, uart_puts
    la      t0, fail_count
    lw      t1, 0(t0)
    addi    t1, t1, 1
    sw      t1, 0(t0)
    REG_L   ra, 0(sp)
    REG_L   s0, 8(sp)
    REG_L   s1, 16(sp)
    REG_L   s2, 24(sp)
    addi    sp, sp, 32
    ret

/* ----------------------------------------------------------------------
 * fail_log_print: the summary's list of failed checks, one line each,
 *   "  <name> - expected 0x..., got 0x..."
 * or, for a check_trap() entry,
 *   "  <name> - trapped, mcause=0x..., mepc=0x..."
 * for the first FAIL_LOG_MAX of them (in the order they ran), then
 * "  ... and N more" if there were more. Only called with fail_count
 * != 0. Clobbers t0-t6, a0.
 * -------------------------------------------------------------------- */
fail_log_print:
    addi    sp, sp, -32
    REG_S   ra, 0(sp)
    REG_S   s0, 8(sp)
    REG_S   s1, 16(sp)
    REG_S   s2, 24(sp)
    la      a0, str_fail_log_head
    jal     ra, uart_puts
    la      t0, fail_count
    lw      s1, 0(t0)               /* s1 = failures in total */
    mv      s2, s1                  /* s2 = entries left to print */
    li      t0, FAIL_LOG_MAX
    bleu    s2, t0, 1f
    mv      s2, t0
1:  la      s0, fail_log
2:  beqz    s2, 3f
    la      a0, str_fail_log_indent
    jal     ra, uart_puts
    REG_L   a0, 0(s0)
    jal     ra, uart_puts
    la      a0, str_fail_log_exp
    REG_L   t0, (3 * REG_BYTES)(s0)
    beqz    t0, 5f
    la      a0, str_fail_log_trap
5:  jal     ra, uart_puts
    REG_L   a0, REG_BYTES(s0)
    jal     ra, uart_put_hex64
    la      a0, str_fail_log_got
    REG_L   t0, (3 * REG_BYTES)(s0)
    beqz    t0, 6f
    la      a0, str_trap_mepc
6:  jal     ra, uart_puts
    REG_L   a0, (2 * REG_BYTES)(s0)
    jal     ra, uart_put_hex64
    la      a0, str_newline
    jal     ra, uart_puts
    addi    s0, s0, FAIL_LOG_ENT
    addi    s2, s2, -1
    j       2b
3:  li      t0, FAIL_LOG_MAX
    bleu    s1, t0, 4f
    la      a0, str_fail_log_more
    jal     ra, uart_puts
    addi    a0, s1, -FAIL_LOG_MAX
    jal     ra, uart_put_dec
    la      a0, str_fail_log_more_tail
    jal     ra, uart_puts
4:  REG_L   ra, 0(sp)
    REG_L   s0, 8(sp)
    REG_L   s1, 16(sp)
    REG_L   s2, 24(sp)
    addi    sp, sp, 32
    ret

/* =======================================================================
 *  Strings (generic to the harness, not to any particular test suite)
 * ======================================================================= */
    .section .rodata
str_dots:             .asciz " - "
str_fail:             .asciz "FAIL\r\n"
str_newline:          .asciz "\r\n"
str_insn_head:        .asciz ":\r\n"
str_insn_ok:          .asciz " OK\r\n"
str_insn_fail:        .asciz " FAIL\r\n"
str_summary_pass:     .asciz "\r\n--- Summary: pass_count = "
str_summary_fail:     .asciz ", fail_count = "
str_summary_tail:     .asciz " ---\r\n"
str_all_pass:         .asciz "ALL TESTS PASSED\r\n"
str_some_fail:        .asciz "ONE OR MORE TESTS FAILED\r\n"
str_fail_log_head:    .asciz "Failed tests:\r\n"
str_fail_log_indent:  .asciz "  "
str_fail_log_exp:     .asciz " - expected "
str_fail_log_got:     .asciz ", got "
str_fail_log_more:    .asciz "  ... and "
str_fail_log_more_tail: .asciz " more\r\n"
str_unexpected_trap:  .asciz "\r\n!!! UNEXPECTED TRAP, mcause="
str_fail_trap:        .asciz "FAIL (trap, mcause="
str_trap_mepc:        .asciz ", mepc="
str_trap_tail:        .asciz ")\r\n"
str_fail_log_trap:    .asciz " - trapped, mcause="
str_no_fencei:        .asciz "FENCE.I not implemented (it traps): instruction-fetch sync skipped\r\n"

/* =======================================================================
 *  Uninitialised data. Not part of the flat .bin: reset zeroes all of
 *  .bss (this file's and every suite's) before anything reads it.
 * ======================================================================= */
    .section .bss
    .align 3
fail_count:   .word 0
pass_count:   .word 0
ebreak_flag:  .word 0
ebreak_mcause: .word 0
ebreak_hit_count: .word 0
trap_count:   .word 0              /* traps taken while armed */
has_fencei:   .word 0              /* reset's FENCE.I probe: 1 = implemented */
insn_len:     .word 0              /* open group's key length */
insn_failed:  .word 0              /* 1 = a check in the open group failed */
    .align 3
ebreak_mepc:  REG_DATA 0
pending_name: REG_DATA 0           /* name announced by test_begin, not
                                    * yet reported by check(); 0 = none */
insn_name:    REG_DATA 0           /* open instruction group: its key's
                                    * first byte (in a test name); 0 =
                                    * none open */
trap_resume:  REG_DATA 0           /* armed-trap resume address; 0 = unarmed */
trap_mcause:  REG_DATA 0           /* the last armed trap's CSRs on entry */
trap_mepc:    REG_DATA 0
trap_mtval:   REG_DATA 0
trap_mstatus: REG_DATA 0
fail_log:     .space FAIL_LOG_MAX * FAIL_LOG_ENT  /* see check() */

    .align 4
    .space 512                     /* trap_handler's private stack */
trap_stack_top:

    .align 4
    .space 4096
stack_top:
