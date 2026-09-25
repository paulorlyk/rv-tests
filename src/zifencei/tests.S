/* =====================================================================
 * zifencei/tests.S  --  Zifencei (instruction-fetch fence) suite
 *                        (orchestrator)
 *
 * Same role as c/tests.S / i/tests.S / zicsr/tests.S: defines
 * run_zifencei_tests, the entry point main_tests.S calls into, which
 * prints a banner and calls each category file's entry point in turn:
 *
 *   zifencei/fencei.S  - FENCE.I
 *
 * Zifencei is a single instruction, but it is its own extension, not
 * part of RV64I/RV32I, so it gets its own suite like every other
 * extension. The category file exposes exactly one symbol and keeps its
 * macros/strings local. Built unchanged for both widths; see
 * zifencei/fencei.S's header for what is and isn't testable about a
 * fence.
 * ===================================================================== */

    .include "xlen.inc"

    .option norvc

    .global run_zifencei_tests

    .section .text

run_zifencei_tests:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    call    insn_close          /* end the previous suite's last group */
    la      a0, str_zifencei_banner
    call    uart_puts

    call    tests_zifencei_fencei

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

    .section .rodata
    .if XLEN == 64
str_zifencei_banner: .asciz "\r\n\r\n=== RV64 Zifencei instruction-fetch fence test suite ===\r\n\r\n"
    .else
str_zifencei_banner: .asciz "\r\n\r\n=== RV32 Zifencei instruction-fetch fence test suite ===\r\n\r\n"
    .endif
