/* =====================================================================
 * zabha/tests.S  --  Zabha (byte and halfword atomic memory operations)
 *                    suite (orchestrator)
 *
 * Same role as c/tests.S / a/tests.S / zicboz/tests.S: defines
 * run_zabha_tests, the entry point main_tests.S calls into, which
 * prints a banner and calls each category file's entry point in turn:
 *
 *   zabha/amo.S  - AMOSWAP, AMOADD, AMOXOR, AMOAND, AMOOR, AMOMIN,
 *                  AMOMAX, AMOMINU, AMOMAXU (.B and .H)
 *
 * Zabha is its own extension (on top of A's Zaamo), not part of RV64A,
 * so it gets its own suite like every other extension. The category
 * file exposes exactly one symbol and keeps its macros/strings local.
 * All 18 instructions exist on both widths, so both images run the
 * same cases. AMOCAS.B/AMOCAS.H (Zabha together with Zacas) are not
 * tested.
 * ===================================================================== */

    .include "xlen.inc"

    .option norvc

    .global run_zabha_tests

    .section .text

run_zabha_tests:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    call    insn_close          /* end the previous suite's last group */
    la      a0, str_zabha_banner
    call    uart_puts

    call    tests_zabha_amo

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

    .section .rodata
    .if XLEN == 64
str_zabha_banner: .asciz "\r\n\r\n=== RV64 Zabha byte/halfword atomic memory operation test suite ===\r\n\r\n"
    .else
str_zabha_banner: .asciz "\r\n\r\n=== RV32 Zabha byte/halfword atomic memory operation test suite ===\r\n\r\n"
    .endif
