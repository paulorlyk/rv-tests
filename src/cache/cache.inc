/* =====================================================================
 * cache/cache.inc  --  constants and macros shared by the cache suite's
 *                      two category files (cache/dcache.S,
 *                      cache/icache.S), .include'd after xlen.inc and
 *                      harness.inc. Macros and .equ constants only;
 *                      the address table is emitted local to each file
 *                      that asks for it (CX_ADDR_TABLE).
 *
 * SCRATCH RAM. The suite needs about 1 MiB of RAM it may overwrite and
 * execute from. It borrows bitx.S's bx_region (1 MiB + 20 bytes of
 * .bss, already required for the control-transfer bitx cases) rather
 * than adding a region of its own, so it costs no RAM; each file calls
 * bx_sled_release first, so whoever calls bx_sled_init next rebuilds
 * the sled.
 *
 * THE WINDOW. The address-bit tests need a base whose bits
 * CX_LO_BIT..CX_WIN_LOG2-1 are all 0, so that base + (1 << i) + (1 << j)
 * differs from base in exactly bits i and j (no carries). bx_region is
 * only 4-byte aligned and its address moves with every change to the
 * image, so CX_WIN rounds it up to a CX_WIN_BYTES boundary at run time.
 * Rounding up moves it by less than CX_WIN_BYTES, and the region is
 * twice that, so the window always lies inside it.
 *
 * THE ADDRESS TABLE. CX_ADDR_TABLE emits, as .words, the offsets 0,
 * every 1 << i, and every (1 << i) | (1 << j) for i < j, with i and j
 * from CX_LO_BIT to CX_WIN_LOG2-1: CX_ADDR_N = 1 + 16 + 120 = 137
 * offsets for bits 3..18. Every offset is a multiple of 8 and all are
 * distinct, so an 8-byte object at each one never overlaps another.
 * ===================================================================== */

    .equ    CX_WIN_LOG2,  19                    /* 512 KiB window */
    .equ    CX_WIN_BYTES, 1 << CX_WIN_LOG2
    .equ    CX_LO_BIT,    3                     /* lowest address bit paired */
    .equ    CX_NBITS,     CX_WIN_LOG2 - CX_LO_BIT
    .equ    CX_ADDR_N,    1 + CX_NBITS + CX_NBITS * (CX_NBITS - 1) / 2

    /* The part of bx_region the suite uses as a whole: its first
     * CX_REGION_BYTES bytes (the 20 left over are never touched). */
    .equ    CX_REGION_BYTES, 1 << 20

    .if (2 * CX_WIN_BYTES) > CX_REGION_BYTES
    .error  "cache.inc: the window must fit in bx_region at any alignment"
    .endif

/* CX_WIN reg -- reg = bx_region rounded up to a CX_WIN_BYTES boundary
 * (pc-relative, never gp-relative). */
.macro CX_WIN reg
    .option push
    .option norelax
    la      \reg, bx_region + CX_WIN_BYTES - 1
    .option pop
    srli    \reg, \reg, CX_WIN_LOG2
    slli    \reg, \reg, CX_WIN_LOG2
.endm

/* CX_NAME label, text -- a name string in .rodata, defined where the
 * test that uses it is. */
.macro CX_NAME label, text
    .pushsection .rodata
\label: .asciz "\text"
    .popsection
.endm

/* CX_ADDR_TABLE label -- the address-bit offsets described above, as
 * .words at label in .rodata (label_end just past the last). */
.macro CX_ADDR_TABLE label
    .pushsection .rodata
    .balign 4
\label:
    .word   0
    .set    .Lcx_i, CX_LO_BIT
    .rept   CX_NBITS
    .word   1 << .Lcx_i
    .set    .Lcx_i, .Lcx_i + 1
    .endr
    .set    .Lcx_i, CX_LO_BIT
    .rept   CX_NBITS - 1
    .set    .Lcx_j, .Lcx_i + 1
    .rept   CX_WIN_LOG2 - .Lcx_i - 1
    .word   (1 << .Lcx_i) | (1 << .Lcx_j)
    .set    .Lcx_j, .Lcx_j + 1
    .endr
    .set    .Lcx_i, .Lcx_i + 1
    .endr
\label\()_end:
    .if (\label\()_end - \label) != 4 * CX_ADDR_N
    .error  "CX_ADDR_TABLE: wrong number of entries"
    .endif
    .popsection
.endm
