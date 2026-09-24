/* =====================================================================
 * priv/tests.S  --  privileged-architecture (machine-mode) instruction
 *                   suite (orchestrator)
 *
 * Same role as c/tests.S / i/tests.S / zicsr/tests.S: defines
 * run_priv_tests, the entry point main_tests.S calls into, which prints
 * a banner and calls each category file's entry point in turn:
 *
 *   priv/mret.S  - MRET
 *   priv/wfi.S   - WFI
 *
 * These two come from the privileged architecture's machine-level ISA,
 * not from RV64I/RV32I (whose own SYSTEM instructions, ECALL and
 * EBREAK, are in i/system.S) or any unprivileged extension, so they
 * get a suite of their own. Both need U-mode for part of their
 * coverage and common.S's armed trap mode (TRAP_ARM in harness.inc)
 * for the traps they cause on purpose. Each category file exposes
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

    la      a0, str_priv_banner
    call    uart_puts

    call    tests_priv_mret
    call    tests_priv_wfi

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

    .section .rodata
    .if XLEN == 64
str_priv_banner: .asciz "\r\n\r\n=== RV64 privileged (machine-mode) instruction test suite ===\r\n\r\n"
    .else
str_priv_banner: .asciz "\r\n\r\n=== RV32 privileged (machine-mode) instruction test suite ===\r\n\r\n"
    .endif
