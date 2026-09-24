/* =====================================================================
 * main_tests.S  --  top-level test dispatcher
 *
 * This is the single file that ties independent instruction-set test
 * suites together. It defines run_tests, the one symbol common.S's
 * reset calls into (see common.S's header for the harness this sits
 * on: boot, UART, "check", pass_count/fail_count). All it does is call
 * each suite's own entry point in turn:
 *
 *   run_c_tests     (c/tests.S + c/quadrant0/1/2.S)      -- RV64C
 *   run_i_tests     (i/tests.S + i/*.S)                  -- RV64I base ISA
 *   run_m_tests     (m/tests.S + m/mul.S + m/div.S)      -- RV64M
 *   run_a_tests     (a/tests.S + a/amo.S + a/lrsc.S)     -- RV64A
 *   run_zicsr_tests (zicsr/tests.S + zicsr/reg.S + zicsr/imm.S) -- Zicsr
 *   run_zifencei_tests (zifencei/tests.S + zifencei/fencei.S) -- Zifencei
 *   run_zicboz_tests (zicboz/tests.S + zicboz/cbozero.S)      -- Zicboz
 *   run_zabha_tests (zabha/tests.S + zabha/amo.S)            -- Zabha
 *   run_priv_tests  (priv/tests.S + priv/mret.S + priv/wfi.S) -- MRET, WFI
 *
 * Adding a new suite means writing its own top-level file (following
 * c/tests.S or i/tests.S as a template: print a banner, call into
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

    call    run_c_tests
    call    run_i_tests
    call    run_m_tests
    call    run_a_tests
    call    run_zicsr_tests
    call    run_zifencei_tests
    call    run_zicboz_tests
    call    run_zabha_tests
    call    run_priv_tests

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret
