/* =====================================================================
 * priv/tests.S  --  privileged-architecture (M/S/U-mode) suite
 *                   (orchestrator)
 *
 * Same role as c/tests.S / i/tests.S / zicsr/tests.S: defines
 * run_priv_tests, the entry point main_tests.S calls into, which prints
 * a banner and calls each category file's entry point in turn:
 *
 *   priv/mret.S     - MRET
 *   priv/wfi.S      - WFI
 *   priv/csrpriv.S  - M-mode CSRs accessed from U-mode
 *   priv/irqpriv.S  - M-mode interrupts while in U-mode; vectored mtvec,
 *                     interrupt priority
 *   priv/mstatus.S  - mstatus MPP/UXL legality, misa.U, the trap-entry
 *                     stack from U-mode
 *   priv/smode.S    - switching between M-, S- and U-mode
 *   priv/sret.S     - SRET (and mstatus.TSR)
 *   priv/deleg.S    - exception delegation (medeleg, mideleg)
 *   priv/sirq.S     - supervisor interrupts: delegation, enables in
 *                     M/S/U-mode, priority, vectored stvec
 *   priv/scsr.S     - sstatus/sie/sip views; S-mode CSRs from U-mode,
 *                     M-mode CSRs from S-mode
 *   priv/counteren.S - mcounteren/scounteren gating the counters
 *   priv/sfence.S   - SFENCE.VMA, mstatus.TVM, TW (WFI) in S-mode
 *
 * MRET and WFI come from the privileged architecture's machine-level
 * ISA, not from RV64I/RV32I (whose own SYSTEM instructions, ECALL and
 * EBREAK, are in i/system.S) or any unprivileged extension, so they
 * get a suite of their own, as do SRET and SFENCE.VMA from the
 * supervisor-level ISA; the other files check the separation between
 * M-, S- and U-mode. The S-mode files share priv/smode.inc (their
 * S-mode trap handler and mode-entry macros). All of them need U-mode for
 * (part of) their coverage and common.S's armed trap mode (TRAP_ARM in
 * harness.inc) for the traps they cause on purpose. Each category file exposes
 * exactly one symbol and keeps its macros/strings local. Built for
 * both widths.
 * ===================================================================== */

    .include "xlen.inc"

    .option norvc

    .global run_priv_tests

    .section .text

run_priv_tests:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    call    insn_close          /* end the previous suite's last group */
    la      a0, str_priv_banner
    call    uart_puts

    call    tests_priv_mret
    call    tests_priv_wfi
    call    tests_priv_csrpriv
    call    tests_priv_irqpriv
    call    tests_priv_mstatus
    call    tests_priv_smode
    call    tests_priv_sret
    call    tests_priv_deleg
    call    tests_priv_sirq
    call    tests_priv_scsr
    call    tests_priv_counteren
    call    tests_priv_sfence

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

    .section .rodata
    .if XLEN == 64
str_priv_banner: .asciz "\r\n\r\n=== RV64 privileged (M/S/U-mode) instruction test suite ===\r\n\r\n"
    .else
str_priv_banner: .asciz "\r\n\r\n=== RV32 privileged (M/S/U-mode) instruction test suite ===\r\n\r\n"
    .endif
