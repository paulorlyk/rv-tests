/* =====================================================================
 * bitx.S  --  runtime support for the bit-independence tests of the
 *              control-transfer instructions (JAL, JALR, the six
 *              branches, C.J, C.BEQZ, C.BNEZ, C.JR, C.JALR)
 *
 * Not a test file: it exposes bx_sled_init and the bx_region buffer, and
 * reports nothing itself. See bitx.inc for the method as a whole.
 *
 * WHY A SLED
 *
 * Pairing every bit of a branch/jump offset with every other variable
 * bit means building thousands of transfers with specific distances --
 * up to +-1 MiB for JAL. Padding each one out with its own filler (the
 * way the per-field tests do it) would make the image many megabytes.
 * Instead, one shared landing zone is built in RAM at run time:
 *
 *   bx_region + BX_SITE_F   4-byte site for JALR / C.JR / C.JALR
 *               BX_SLED     BX_SLOTS copies of "c.addi s5, 1"
 *               BX_EXIT     jalr x0, 0(s6)
 *               BX_SITE_B   4-byte site; backward transfers start here
 *               BX_NT       addi s5, x0, -1 ; jalr x0, 0(s6)
 *
 * Each case copies the instruction under test -- assembled by the
 * assembler into .rodata, so the encoding is the assembler's, not a
 * hand-built word -- onto its site, executes FENCE.I (SYNC_I in
 * harness.inc: skipped on a hart without Zifencei), zeroes s5 and
 * calls the site with "jalr s6". Wherever the transfer lands in the
 * sled, the increments that follow count the 2-byte slots left before
 * BX_EXIT, which returns through s6. So s5 = (BX_EXIT - landing) / 2
 * identifies the landing address exactly, and a transfer that lands one
 * slot off, or not at all, reports a different number instead of
 * running off into unrelated code.
 *
 * Forward transfers are planted *inside* the sled, a fixed margin plus
 * their own distance before BX_EXIT (and the slots put back afterwards),
 * so every correct forward landing counts the same few slots rather
 * than running most of the sled; a forward branch that falls through
 * lands on the next slot and counts a different number. A backward
 * branch that falls through reaches BX_NT and reports -1. The details
 * are in bitx.inc (BX_PLANT / BX_GO / BX_COUNT).
 *
 * The region is ~1 MiB of .bss, so it costs nothing in the flat binary
 * but does need that much RAM after the image. It's built only once:
 * bx_ready (.bss, so zeroed by common.S's reset -- never by the loader)
 * makes bx_sled_init idempotent, and the tests re-plant only the site
 * they use.
 * ===================================================================== */

    .include "xlen.inc"
    .include "harness.inc"

    .option norvc

    .include "bitx.inc"

    .global bx_sled_init
    .global bx_region
    .global bx_tpl_slot
    .global bx_tpl_cnop

    .section .text

/* bx_sled_init: build the sled on first call, no-op afterwards.
 * Clobbers t0-t4. */
bx_sled_init:
    la      t0, bx_ready
    lw      t1, 0(t0)
    bnez    t1, 9f

    /* BX_SLOTS copies of the counting slot */
    la      t2, bx_tpl_slot
    lhu     t1, 0(t2)
    la      t4, bx_region + BX_SLED
    li      t3, BX_SLOTS
1:  sh      t1, 0(t4)
    addi    t4, t4, 2
    addi    t3, t3, -1
    bnez    t3, 1b

    /* t4 = bx_region + BX_EXIT: exit, backward site (two c.nop until a
     * test plants something), not-taken stub -- 16 bytes of templates,
     * copied as halfwords */
    la      t2, bx_tpl_tail
    li      t3, 8
2:  lhu     t1, 0(t2)
    sh      t1, 0(t4)
    addi    t2, t2, 2
    addi    t4, t4, 2
    addi    t3, t3, -1
    bnez    t3, 2b

    SYNC_I  t1                      /* FENCE.I, if the hart has it */
    li      t1, 1
    sw      t1, 0(t0)
9:  ret

/* Templates, assembled here so their encodings are the assembler's. */
    .section .rodata
    .balign 4
    .option push
    .option rvc
bx_tpl_slot:
    c.addi  s5, 1
    .option pop
    .balign 4
bx_tpl_tail:
    jalr    x0, 0(s6)               /* BX_EXIT */
    .option push
    .option rvc
bx_tpl_cnop:
    c.nop                           /* BX_SITE_B */
    c.nop
    .option pop
    addi    s5, x0, -1              /* BX_NT */
    jalr    x0, 0(s6)

    .section .bss
    .balign 4
bx_ready:
    .word   0
    .balign 4
bx_region:
    .space  BX_REGION_SIZE
