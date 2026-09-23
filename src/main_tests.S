/* =====================================================================
 * main_tests.S  --  top-level test dispatcher
 *
 * This is the single file that ties independent instruction-set test
 * suites together. It defines run_tests, the one symbol common.S's
 * reset calls into (see common.S's header for the harness this sits
 * on: boot, UART, "check", pass_count/fail_count). All it does is call
 * each suite's own entry point in turn:
 *
 *   run_rvc_tests   (rvc/tests.S + rvc/quadrant0/1/2.S)  -- RV64C
 *   run_base_tests  (base/tests.S + base/*.S)            -- RV64I base ISA
 *   run_m_tests     (m/tests.S + m/mul.S + m/div.S)      -- RV64M
 *
 * Adding a new suite means writing its own top-level file (following
 * rvc/tests.S or base/tests.S as a template: print a banner, call into
 * one or more category files, each exposing a single entry symbol),
 * then adding one "call run_yyy_tests" line here and its object
 * file(s) to the Makefile's SUITE_SRCS list. Nothing else needs to
 * change -- every suite already shares common.S's "check"/"uart_puts"
 * and the same pass_count/fail_count totals.
 * ===================================================================== */

    .include "xlen.inc"

    .option norvc

    .global run_tests

    .section .text

run_tests:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    call    run_rvc_tests
    call    run_base_tests
    call    run_m_tests

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret
