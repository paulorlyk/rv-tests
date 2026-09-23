/* =====================================================================
 * base/tests.S  --  RV64I/RV32I base (non-compressed) instruction-set suite
 *                    (orchestrator)
 *
 * Mirrors rvc/tests.S's role, one level up: defines run_base_tests,
 * the entry point main_tests.S calls into, which prints a banner and
 * calls each category file's entry point in turn. Category files
 * (base/loads.S, base/stores.S, base/lui.S, base/auipc.S, base/jal.S,
 * base/jalr.S, base/branches.S, base/op_alu.S, base/op_imm.S, base/op_imm32.S,
 * base/op_alu32.S so far; more can be added the same way RVC's quadrant0/1/2 files
 * were) each expose exactly one symbol and keep their own
 * macros/subroutines/data local.
 *
 * Every instruction here is written with .option norvc active
 * throughout its file, which is what actually matters for a suite
 * that's supposed to test the *base* ISA: without it, the assembler
 * would happily substitute a compressed encoding whenever the operand
 * choice happens to be compressible (e.g. "lw s0, 0(s1)" -> c.lw),
 * silently testing the wrong instruction. See base/loads.S's header
 * for more on this.
 *
 * Built for both widths (see xlen.inc): LD, SD, LWU and the OP-IMM-32
 * and OP-32 instructions (base/op_imm32.S, base/op_alu32.S) are
 * RV64-only and left out of the RV32 image, shift amounts are 5 bits there, and
 * width-specific values are written with INTX_MIN/INTX_MAX or given an
 * RV32 block of their own.
 * ===================================================================== */

    .include "xlen.inc"

    .option norvc

    .global run_base_tests

    .section .text

run_base_tests:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    la      a0, str_base_banner
    call    uart_puts

    call    tests_base_loads
    call    tests_base_stores
    call    tests_base_lui
    call    tests_base_auipc
    call    tests_base_jal
    call    tests_base_jalr
    call    tests_base_branches
    call    tests_base_op_alu
    call    tests_base_op_imm
    call    tests_base_op_imm32
    call    tests_base_op_alu32

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

    .section .rodata
    .if XLEN == 64
str_base_banner: .asciz "\r\n\r\n=== RV64I base ISA test suite ===\r\n\r\n"
    .else
str_base_banner: .asciz "\r\n\r\n=== RV32I base ISA test suite ===\r\n\r\n"
    .endif
