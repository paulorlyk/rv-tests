/* =====================================================================
 * cache/tests.S  --  cache suite (orchestrator): data- and
 *                    instruction-cache stress
 *
 * Same role as c/tests.S / i/tests.S / zifencei/tests.S: defines
 * run_cache_tests, the entry point main_tests.S calls into, which
 * prints a banner and calls each category file's entry point in turn:
 *
 *   cache/dcache.S  - capacity/write-back, address-bit pairs, sub-word
 *                     stores into resident and evicted lines, AMO/LR/SC
 *                     and CBO.ZERO on dirty and evicted lines
 *   cache/icache.S  - FENCE.I over large code blocks, code at
 *                     address-bit pairs, instructions straddling line
 *                     and page boundaries
 *
 * Unlike the other suites this one isn't an extension: it tests no new
 * instruction, but the caches behind the ones the other suites test
 * (a cache must never change a result), with access patterns built to
 * make a cache fault visible. Both files share cache/cache.inc and
 * borrow bx_region (bitx.S) as scratch RAM, so this suite needs no RAM
 * beyond what the bitx cases already do. Built unchanged for both
 * widths.
 * ===================================================================== */

    .include "xlen.inc"

    .option norvc

    .global run_cache_tests

    .section .text

run_cache_tests:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    call    insn_close          /* end the previous suite's last group */
    la      a0, str_cache_banner
    call    uart_puts

    call    tests_cache_dcache
    call    tests_cache_icache

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

    .section .rodata
    .if XLEN == 64
str_cache_banner: .asciz "\r\n\r\n=== RV64 data- and instruction-cache stress test suite ===\r\n\r\n"
    .else
str_cache_banner: .asciz "\r\n\r\n=== RV32 data- and instruction-cache stress test suite ===\r\n\r\n"
    .endif
