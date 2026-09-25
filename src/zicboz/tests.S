/* =====================================================================
 * zicboz/tests.S  --  Zicboz (cache-block zero) suite (orchestrator)
 *
 * Same role as c/tests.S / i/tests.S / zifencei/tests.S: defines
 * run_zicboz_tests, the entry point main_tests.S calls into, which
 * prints a banner and calls each category file's entry point in turn:
 *
 *   zicboz/cbozero.S  - CBO.ZERO
 *
 * Zicboz is a single instruction, but it is its own extension, not part
 * of RV64I/RV32I, so it gets its own suite like every other extension.
 * The category file exposes exactly one symbol and keeps its
 * macros/strings local. Built unchanged for both widths; see
 * zicboz/cbozero.S's header for the cache-block size it assumes.
 * ===================================================================== */

    .include "xlen.inc"

    .option norvc

    .global run_zicboz_tests

    .section .text

run_zicboz_tests:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    call    insn_close          /* end the previous suite's last group */
    la      a0, str_zicboz_banner
    call    uart_puts

    call    tests_zicboz_cbozero

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

    .section .rodata
    .if XLEN == 64
str_zicboz_banner: .asciz "\r\n\r\n=== RV64 Zicboz cache-block zero test suite ===\r\n\r\n"
    .else
str_zicboz_banner: .asciz "\r\n\r\n=== RV32 Zicboz cache-block zero test suite ===\r\n\r\n"
    .endif
