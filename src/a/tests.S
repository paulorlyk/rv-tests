/* =====================================================================
 * a/tests.S  --  RV64A/RV32A (atomic) instruction-set suite
 *                 (orchestrator)
 *
 * Same role as c/tests.S / i/tests.S / m/tests.S: defines
 * run_a_tests, the entry point main_tests.S calls into, which prints a
 * banner and calls each category file's entry point in turn:
 *
 *   a/amo.S  - AMOSWAP, AMOADD, AMOXOR, AMOAND, AMOOR, AMOMIN, AMOMAX,
 *              AMOMINU, AMOMAXU (.W and .D)
 *   a/lrsc.S - LR, SC (.W and .D)
 *
 * Each exposes exactly one symbol and keeps its macros/strings local.
 * All 22 RV64A instructions are covered; the RV32 image covers the 11
 * .W forms (the .D forms are RV64-only).
 * ===================================================================== */

    .include "xlen.inc"

    .option norvc

    .global run_a_tests

    .section .text

run_a_tests:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    la      a0, str_a_banner
    call    uart_puts

    call    tests_a_amo
    call    tests_a_lrsc

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

    .section .rodata
    .if XLEN == 64
str_a_banner: .asciz "\r\n\r\n=== RV64A atomic memory operation test suite ===\r\n\r\n"
    .else
str_a_banner: .asciz "\r\n\r\n=== RV32A atomic memory operation test suite ===\r\n\r\n"
    .endif
