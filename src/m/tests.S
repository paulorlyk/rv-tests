/* =====================================================================
 * m/tests.S  --  RV64M/RV32M (integer multiply/divide) instruction-set suite
 *                 (orchestrator)
 *
 * Same role as c/tests.S / i/tests.S: defines run_m_tests, the
 * entry point main_tests.S calls into, which prints a banner and calls
 * each category file's entry point in turn:
 *
 *   m/mul.S  - MUL, MULH, MULHSU, MULHU, MULW
 *   m/div.S  - DIV, DIVU, REM, REMU, DIVW, DIVUW, REMW, REMUW
 *
 * Each exposes exactly one symbol and keeps its macros/strings local.
 * All 13 RV64M instructions are covered; the RV32 image covers the 8 that
 * exist in RV32M (the W forms are RV64-only).
 * ===================================================================== */

    .include "xlen.inc"

    .option norvc

    .global run_m_tests

    .section .text

run_m_tests:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    call    insn_close          /* end the previous suite's last group */
    la      a0, str_m_banner
    call    uart_puts

    call    tests_m_mul
    call    tests_m_div

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

    .section .rodata
    .if XLEN == 64
str_m_banner: .asciz "\r\n\r\n=== RV64M multiply/divide test suite ===\r\n\r\n"
    .else
str_m_banner: .asciz "\r\n\r\n=== RV32M multiply/divide test suite ===\r\n\r\n"
    .endif
