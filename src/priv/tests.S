/* =====================================================================
 * priv/tests.S  --  privileged-architecture (machine-mode) suite
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
 *
 * MRET and WFI come from the privileged architecture's machine-level
 * ISA, not from RV64I/RV32I (whose own SYSTEM instructions, ECALL and
 * EBREAK, are in i/system.S) or any unprivileged extension, so they
 * get a suite of their own; the other three files check the
 * separation between M-mode and U-mode. All of them need U-mode for
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

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

    .section .rodata
    .if XLEN == 64
str_priv_banner: .asciz "\r\n\r\n=== RV64 privileged (machine-mode) instruction test suite ===\r\n\r\n"
    .else
str_priv_banner: .asciz "\r\n\r\n=== RV32 privileged (machine-mode) instruction test suite ===\r\n\r\n"
    .endif
