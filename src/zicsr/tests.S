/* =====================================================================
 * zicsr/tests.S  --  Zicsr (control and status register) instruction
 *                     suite (orchestrator)
 *
 * Same role as c/tests.S / i/tests.S / m/tests.S: defines
 * run_zicsr_tests, the entry point main_tests.S calls into, which prints
 * a banner and calls each category file's entry point in turn:
 *
 *   zicsr/reg.S  - CSRRW, CSRRS, CSRRC
 *   zicsr/imm.S  - CSRRWI, CSRRSI, CSRRCI
 *
 * Each exposes exactly one symbol and keeps its macros/strings local.
 * All six Zicsr instructions are covered, identically on both widths.
 * The CSR under test is mscratch; see zicsr/reg.S's header for why, and
 * for what isn't tested (anything that would have to trap).
 * ===================================================================== */

    .include "xlen.inc"

    .option norvc

    .global run_zicsr_tests

    .section .text

run_zicsr_tests:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    call    insn_close          /* end the previous suite's last group */
    la      a0, str_zicsr_banner
    call    uart_puts

    call    tests_zicsr_reg
    call    tests_zicsr_imm

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

    .section .rodata
    .if XLEN == 64
str_zicsr_banner: .asciz "\r\n\r\n=== RV64 Zicsr CSR instruction test suite ===\r\n\r\n"
    .else
str_zicsr_banner: .asciz "\r\n\r\n=== RV32 Zicsr CSR instruction test suite ===\r\n\r\n"
    .endif
