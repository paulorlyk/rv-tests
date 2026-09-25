/* =====================================================================
 * cache/dcache.S  --  data-cache stress: capacity and write-back,
 *                     address-bit (tag/index) independence, sub-word
 *                     stores merged into resident and evicted lines,
 *                     AMO / LR/SC / CBO.ZERO on dirty and evicted lines
 *
 * One of the two category files of the cache suite; see cache/tests.S
 * for how this plugs into the rest (main_tests.S -> cache/tests.S ->
 * here), cache/cache.inc for the scratch RAM and the address window,
 * and common.S for the harness ("check" is used from there).
 *
 * WHAT IS UNDER TEST. Not an instruction's encoding (every instruction
 * used here has its own per-field and bit-independence coverage in its
 * own suite) but the memory hierarchy behind it: a data cache must be
 * invisible. Every test here gives the same answer on a hart without
 * any cache, and under QEMU (which has none), so a passing run there
 * only shows the tests are right; on hardware with caches they are the
 * real test. The faults they are built to expose:
 *   - a dirty line lost, or written back to the wrong place, when it is
 *     evicted (capacity: more data than any cache holds);
 *   - a tag or set-index bit that is ignored, stuck, or coupled to
 *     another address bit, so two addresses share a line (the
 *     address-bit pairs, the data-side twin of the bitx method);
 *   - a byte/halfword/word store that misses the cache and is merged
 *     wrongly with the line fetched after it (write-allocate refill
 *     overwriting the stored bytes, the wrong lane, a whole-word write);
 *   - an AMO, LR/SC or CBO.ZERO performed outside the L1 (at a shared
 *     cache or the memory) while the L1 holds a dirty or stale copy.
 *
 * EVICTION. There is no cache-flush instruction in the base ISA (Zicbom
 * isn't assumed), so cx_flush evicts by capacity: it loads one word
 * every CX_FLUSH_STRIDE bytes across all of CX_REGION_BYTES (1 MiB) of
 * bx_region. That evicts every line of the test buffer (cx_line, which
 * lies outside that region) from any cache of up to half that size
 * with LRU-like replacement; a bigger cache, or a random replacement
 * policy, makes a flush likely rather than certain, which weakens the
 * "evicted" cases into "resident" ones but never makes them wrong.
 * CX_FLUSH_STRIDE must not exceed the smallest line size.
 *
 * What is checked (REG_S/REG_L are SD/LD on RV64, SW/LW on RV32; the
 * names say which):
 *   - capacity: all of the 1 MiB region written with its own address
 *     XOR a seed ("address in address"), read back in the opposite
 *     order; again with the complementary seed and the directions
 *     swapped. One check each: the first wrong address found (0 = none).
 *   - address-bit pairs: in the 512 KiB window, the location at every
 *     offset of CX_ADDR_TABLE (0, each single bit 3..18, each pair)
 *     written with its address XOR a seed, then read back: once
 *     straight away, once (other seed, written in reverse order) after
 *     a flush. A tag compare that ignores bit i makes base and
 *     base + (1 << i) one line; a bit coupled to another shows as a
 *     pair that aliases. One check each, as above.
 *   - sub-word merge: a 128-byte buffer (cx_line, two 64-byte lines,
 *     byte b holding 0x80 + b) gets one SB/SH/SW/SD at the start, the
 *     middle and the last lane of the first line, with the line
 *     (a) resident, (b) evicted before the store, (c) evicted before
 *     and after it. Two checks each: the register-sized word that holds
 *     the store (against the fill with the stored bytes put in by
 *     register arithmetic), and every other word of both lines.
 *   - AMOADD.W on a line dirty in the cache (rd and memory), and on an
 *     evicted one (rd, memory straight after, memory after write-back);
 *     LR.W/SC.W on an evicted line (LR reads memory, SC succeeds, the
 *     stored value survives write-back);
 *   - CBO.ZERO on a dirty line and on an evicted one: the zeros
 *     survive write-back (the dirty data is not written back over them)
 *     and the next line keeps its data.
 *
 * TRAPS: loads and stores are base ISA and run unarmed, like every
 * base-ISA test (a trap is an UNEXPECTED TRAP). The AMO, LR/SC and
 * CBO.ZERO cases need A or Zicboz and run armed: without the extension
 * each of their checks is a check_trap FAIL. Every loop here is
 * bounded by a register count, never by what memory holds, so wrong
 * data can't make one run away.
 *
 * No bitx cases: this file tests no instruction of its own (the
 * address-bit pairs are the bit-independence method applied to the
 * address instead of the encoding).
 *
 * Built for both widths; the SD cases are RV64-only.
 * ===================================================================== */

    .include "xlen.inc"
    .include "harness.inc"

    .option norvc            /* mandatory, not stylistic -- see i/loads.S */

    .include "cache/cache.inc"

    .global tests_cache_dcache

    .equ    CX_FLUSH_STRIDE, 16         /* <= the smallest line size */
    .equ    CX_BUF_BYTES,    128        /* cx_line: two 64-byte lines */
    .equ    CX_LINE_BYTES,   64         /* the line the stores go into */
    /* CBO.ZERO's block size: keep equal to CBOZ_BLOCK_BYTES in
     * zicboz/cbozero.S (see README "Porting"). */
    .equ    CX_CBOZ_BLOCK,   64
    .if CX_CBOZ_BLOCK > CX_BUF_BYTES
    .error  "CX_CBOZ_BLOCK must not exceed CX_BUF_BYTES"
    .endif

    /* cx_line's fill: byte b = 0x80 + b, as register-sized words
     * CX_FILL + i * CX_STEP (no carries: every byte stays <= 0xff).
     * CX_VAL is what the merge stores write: bytes 0x01..0x78, never a
     * fill byte. */
    .if XLEN == 64
    .equ    CX_FILL, 0x8786858483828180
    .equ    CX_STEP, 0x0808080808080808
    .equ    CX_VAL,  0x7867564534231201
    .equ    CX_REG_LOG2, 3
    .else
    .equ    CX_FILL, 0x83828180
    .equ    CX_STEP, 0x04040404
    .equ    CX_VAL,  0x34231201
    .equ    CX_REG_LOG2, 2
    .endif
    /* Address-in-address seeds: capacity, address-bit pairs. The
     * second pass of each uses the complement. All four differ, so a
     * write that does nothing leaves a value the read-back rejects. */
    .equ    CX_SEED_CAP,  0x5a5aa5a5c3c33c3c
    .equ    CX_SEED_PAIR, 0x3c3cc3c35a5aa5a5

    .section .text

/* =======================================================================
 *  Shared macros
 * ======================================================================= */

/* CX_LANE w, off -- .Lcx_mask = the bits of the register-sized word
 * holding cx_line + off that a w-byte store there writes; .Lcx_bits =
 * CX_VAL's low w bytes moved into that lane. */
.macro CX_LANE w, off
    .if (\w) == REG_BYTES
    .set    .Lcx_mask, XLEN_MASK
    .set    .Lcx_bits, CX_VAL
    .else
    .set    .Lcx_mask, ((1 << (8 * (\w))) - 1) << (8 * ((\off) % REG_BYTES))
    .set    .Lcx_bits, (CX_VAL & ((1 << (8 * (\w))) - 1)) << (8 * ((\off) % REG_BYTES))
    .endif
.endm

/* T_CX_MERGE insn, w, off, mode, nm -- one sub-word merge case: fill
 * cx_line, make its first line resident (mode 0: read it) or evicted
 * (modes 1 and 2: cx_flush), store CX_VAL's low w bytes at
 * cx_line + off with insn, evict again for mode 2, then check the
 * register-sized word holding the store and every other word of
 * cx_line (see cx_line_check). nm is the mnemonic, for the names. */
.macro T_CX_MERGE insn, w, off, mode, nm
    .if \mode == 0
    CX_NAME .Lcxm_t\@, "\nm into a resident line, byte \off: the word stored into"
    CX_NAME .Lcxm_r\@, "\nm into a resident line, byte \off: every other word unchanged"
    .elseif \mode == 1
    CX_NAME .Lcxm_t\@, "\nm into an evicted line, byte \off: the word stored into"
    CX_NAME .Lcxm_r\@, "\nm into an evicted line, byte \off: every other word unchanged"
    .else
    CX_NAME .Lcxm_t\@, "\nm into an evicted line, byte \off, written back: the word stored into"
    CX_NAME .Lcxm_r\@, "\nm into an evicted line, byte \off, written back: every other word unchanged"
    .endif
    TEST_BEGIN .Lcxm_t\@
    jal     ra, cx_line_fill
    .if \mode == 0
    jal     ra, cx_line_touch
    .else
    jal     ra, cx_flush
    .endif
    la      t3, cx_line + \off
    LIXT    t4, CX_VAL
    \insn   t4, 0(t3)
    .if \mode == 2
    jal     ra, cx_flush
    .endif
    CX_LANE \w, \off
    li      a3, (\off) & ~(REG_BYTES - 1)
    LIX     a4, .Lcx_mask
    LIX     a5, .Lcx_bits
    jal     ra, cx_line_check
    la      a0, .Lcxm_t\@
    mv      a1, s2
    mv      a2, s1
    call    check
    TEST_BEGIN .Lcxm_r\@
    la      a0, .Lcxm_r\@
    li      a1, 0
    mv      a2, s4
    call    check
.endm

/* T_CX_MERGE3 insn, w, off, nm -- the three modes of one store. */
.macro T_CX_MERGE3 insn, w, off, nm
    T_CX_MERGE \insn, \w, \off, 0, \nm
    T_CX_MERGE \insn, \w, \off, 1, \nm
    T_CX_MERGE \insn, \w, \off, 2, \nm
.endm

tests_cache_dcache:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    call    bx_sled_release         /* bx_region is ours from here on */

    jal     ra, test_cx_capacity
    jal     ra, test_cx_pairs
    jal     ra, test_cx_merge
    jal     ra, test_cx_amo
    jal     ra, test_cx_cboz

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  Subroutines
 * ======================================================================= */

/* cx_flush: evict by capacity (see the file header). Clobbers t0-t2. */
cx_flush:
    la      t0, bx_region
    li      t1, CX_REGION_BYTES
    add     t1, t0, t1
1:  lw      t2, 0(t0)
    addi    t0, t0, CX_FLUSH_STRIDE
    bltu    t0, t1, 1b
    ret

/* cx_line_fill: cx_line[b] = 0x80 + b for all CX_BUF_BYTES bytes,
 * written as register-sized words. Clobbers t0-t3. */
cx_line_fill:
    la      t0, cx_line
    LIX     t1, CX_FILL
    LIX     t2, CX_STEP
    li      t3, CX_BUF_BYTES / REG_BYTES
1:  REG_S   t1, 0(t0)
    add     t1, t1, t2
    addi    t0, t0, REG_BYTES
    addi    t3, t3, -1
    bnez    t3, 1b
    ret

/* cx_line_touch: read every word of cx_line (makes it resident).
 * Clobbers t0-t2. */
cx_line_touch:
    la      t0, cx_line
    li      t1, CX_BUF_BYTES / REG_BYTES
1:  REG_L   t2, 0(t0)
    addi    t0, t0, REG_BYTES
    addi    t1, t1, -1
    bnez    t1, 1b
    ret

/* cx_line_check: a3 = byte offset of the register-sized word the
 * store went into, a4 = its lane mask, a5 = the stored bits in their
 * lane. Returns s1 = that word as read, s2 = what it must be (the fill
 * with the lane replaced), s4 = OR over every other word of
 * (read ^ fill), 0 if all are untouched. Clobbers t0-t6, a0. */
cx_line_check:
    la      t0, cx_line
    LIX     t1, CX_FILL             /* t1 = this word's fill */
    LIX     t2, CX_STEP
    li      t3, 0                   /* t3 = this word's byte offset */
    li      t6, CX_BUF_BYTES
    li      s4, 0
1:  REG_L   t4, 0(t0)
    bne     t3, a3, 2f
    not     a0, a4
    and     t5, t1, a0
    or      t5, t5, a5
    mv      s1, t4
    mv      s2, t5
    j       3f
2:  xor     t5, t4, t1
    or      s4, s4, t5
3:  add     t1, t1, t2
    addi    t0, t0, REG_BYTES
    addi    t3, t3, REG_BYTES
    bne     t3, t6, 1b
    ret

/* cx_zero_check: a3 = number of leading bytes of cx_line that must be
 * zero. Returns s1 = OR over those words (0 if all zero), s4 = OR over
 * the rest of (read ^ fill). Clobbers t0-t6. */
cx_zero_check:
    la      t0, cx_line
    LIX     t1, CX_FILL
    LIX     t2, CX_STEP
    li      t3, 0
    li      t6, CX_BUF_BYTES
    li      s1, 0
    li      s4, 0
1:  REG_L   t4, 0(t0)
    bgeu    t3, a3, 2f
    or      s1, s1, t4
    j       3f
2:  xor     t5, t4, t1
    or      s4, s4, t5
3:  add     t1, t1, t2
    addi    t0, t0, REG_BYTES
    addi    t3, t3, REG_BYTES
    bne     t3, t6, 1b
    ret

/* cx_cap_bounds: s2 = bx_region rounded up to 64, s3 = the end of its
 * first CX_REGION_BYTES rounded down to 64: the capacity test's range.
 * Clobbers t0. */
cx_cap_bounds:
    la      t0, bx_region
    addi    s2, t0, 63
    andi    s2, s2, -64
    li      s3, CX_REGION_BYTES
    add     s3, s3, t0
    andi    s3, s3, -64
    ret

/* cx_cap_write: every register-sized word p in [s2, s3) = p ^ a3,
 * upwards if a4 = 0, downwards otherwise. Clobbers t0-t3. */
cx_cap_write:
    mv      t0, s2
    li      t1, REG_BYTES
    beqz    a4, 1f
    addi    t0, s3, -REG_BYTES
    li      t1, -REG_BYTES
1:  sub     t2, s3, s2
    srli    t2, t2, CX_REG_LOG2
2:  xor     t3, t0, a3
    REG_S   t3, 0(t0)
    add     t0, t0, t1
    addi    t2, t2, -1
    bnez    t2, 2b
    ret

/* cx_cap_read: read [s2, s3) back, upwards if a4 = 0, downwards
 * otherwise; a5 = the first address found not holding p ^ a3, 0 if
 * none. Clobbers t0-t4. */
cx_cap_read:
    mv      t0, s2
    li      t1, REG_BYTES
    beqz    a4, 1f
    addi    t0, s3, -REG_BYTES
    li      t1, -REG_BYTES
1:  sub     t2, s3, s2
    srli    t2, t2, CX_REG_LOG2
    li      a5, 0
2:  REG_L   t3, 0(t0)
    xor     t4, t0, a3
    beq     t3, t4, 3f
    bnez    a5, 3f
    mv      a5, t0
3:  add     t0, t0, t1
    addi    t2, t2, -1
    bnez    t2, 2b
    ret

/* cx_pair_write: for every offset o of cx_addr_tab, the word at
 * s2 + o = (s2 + o) ^ a3; table order if a4 = 0, reversed otherwise.
 * Clobbers t0-t4. */
cx_pair_write:
    la      t0, cx_addr_tab
    li      t1, 4
    beqz    a4, 1f
    la      t0, cx_addr_tab_end - 4
    li      t1, -4
1:  li      t2, CX_ADDR_N
2:  lw      t3, 0(t0)
    add     t3, t3, s2
    xor     t4, t3, a3
    REG_S   t4, 0(t3)
    add     t0, t0, t1
    addi    t2, t2, -1
    bnez    t2, 2b
    ret

/* cx_pair_read: read them back in table order; a5 = the first address
 * not holding its value, 0 if none. Clobbers t0-t4. */
cx_pair_read:
    la      t0, cx_addr_tab
    li      t2, CX_ADDR_N
    li      a5, 0
1:  lw      t3, 0(t0)
    add     t3, t3, s2
    REG_L   t1, 0(t3)
    xor     t4, t3, a3
    beq     t1, t4, 2f
    bnez    a5, 2f
    mv      a5, t3
2:  addi    t0, t0, 4
    addi    t2, t2, -1
    bnez    t2, 1b
    ret

/* =======================================================================
 *  Capacity and write-back
 * ======================================================================= */
test_cx_capacity:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    jal     ra, cx_cap_bounds

    TEST_BEGIN str_cx_cap_up
    LIXT    a3, CX_SEED_CAP
    li      a4, 0
    jal     ra, cx_cap_write
    li      a4, 1
    jal     ra, cx_cap_read
    mv      s1, a5
    la      a0, str_cx_cap_up
    li      a1, 0
    mv      a2, s1
    call    check

    TEST_BEGIN str_cx_cap_down
    LIXT    a3, ~CX_SEED_CAP
    li      a4, 1
    jal     ra, cx_cap_write
    li      a4, 0
    jal     ra, cx_cap_read
    mv      s1, a5
    la      a0, str_cx_cap_down
    li      a1, 0
    mv      a2, s1
    call    check

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  Address-bit pairs (tag and set-index independence)
 * ======================================================================= */
test_cx_pairs:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    CX_WIN  s2

    TEST_BEGIN str_cx_pair_now
    LIXT    a3, CX_SEED_PAIR
    li      a4, 0
    jal     ra, cx_pair_write
    jal     ra, cx_pair_read
    mv      s1, a5
    la      a0, str_cx_pair_now
    li      a1, 0
    mv      a2, s1
    call    check

    TEST_BEGIN str_cx_pair_flush
    LIXT    a3, ~CX_SEED_PAIR
    li      a4, 1
    jal     ra, cx_pair_write
    jal     ra, cx_flush
    jal     ra, cx_pair_read
    mv      s1, a5
    la      a0, str_cx_pair_flush
    li      a1, 0
    mv      a2, s1
    call    check

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  Sub-word stores merged into resident and evicted lines
 * ======================================================================= */
test_cx_merge:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    T_CX_MERGE3 sb, 1, 0,  SB
    T_CX_MERGE3 sb, 1, 13, SB
    T_CX_MERGE3 sb, 1, 63, SB
    T_CX_MERGE3 sh, 2, 0,  SH
    T_CX_MERGE3 sh, 2, 22, SH
    T_CX_MERGE3 sh, 2, 62, SH
    T_CX_MERGE3 sw, 4, 0,  SW
    T_CX_MERGE3 sw, 4, 36, SW
    T_CX_MERGE3 sw, 4, 60, SW
    .if XLEN == 64
    T_CX_MERGE3 sd, 8, 0,  SD
    T_CX_MERGE3 sd, 8, 24, SD
    T_CX_MERGE3 sd, 8, 56, SD
    .endif

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  AMO and LR/SC on dirty and evicted lines (A; armed)
 * ======================================================================= */
test_cx_amo:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    /* --- AMOADD.W on a word just stored (dirty in the cache): an AMO
     *     done past the L1 would miss the store, and a stale L1 copy
     *     would hide the AMO's result --- */
    TEST_BEGIN str_cx_amo_d_rd
    jal     ra, cx_line_fill
    la      s3, cx_line + 8
    LIX     t4, 0x12345678
    sw      t4, 0(s3)
    LIX     t4, 0x01010101
    TRAP_ARM .Lcx_trap_amo_d
    amoadd.w t2, t4, (s3)
    TRAP_DISARM
    mv      s1, t2
    LWUX    s2, 0(s3)
    la      a0, str_cx_amo_d_rd
    LIX     a1, 0x12345678
    mv      a2, s1
    call    check
    TEST_BEGIN str_cx_amo_d_mem
    la      a0, str_cx_amo_d_mem
    LIX     a1, 0x13355779
    mv      a2, s2
    call    check
    TRAP_FAILS .Lcx_trap_amo_d, str_cx_amo_d_rd, str_cx_amo_d_mem

    /* --- AMOADD.W on an evicted line: rd, memory straight after, and
     *     memory once the line has been evicted again --- */
    TEST_BEGIN str_cx_amo_e_rd
    jal     ra, cx_line_fill
    la      s3, cx_line + 8
    LIX     t4, 0x2468ace0
    sw      t4, 0(s3)
    jal     ra, cx_flush
    LIX     t4, 0x11111111
    TRAP_ARM .Lcx_trap_amo_e
    amoadd.w t2, t4, (s3)
    TRAP_DISARM
    mv      s1, t2
    LWUX    s2, 0(s3)
    jal     ra, cx_flush
    LWUX    s4, 0(s3)
    la      a0, str_cx_amo_e_rd
    LIX     a1, 0x2468ace0
    mv      a2, s1
    call    check
    TEST_BEGIN str_cx_amo_e_mem
    la      a0, str_cx_amo_e_mem
    LIX     a1, 0x3579bdf1
    mv      a2, s2
    call    check
    TEST_BEGIN str_cx_amo_e_wb
    la      a0, str_cx_amo_e_wb
    LIX     a1, 0x3579bdf1
    mv      a2, s4
    call    check
    TRAP_FAILS .Lcx_trap_amo_e, str_cx_amo_e_rd, str_cx_amo_e_mem, str_cx_amo_e_wb

    /* --- LR.W/SC.W on an evicted line (nothing between them) --- */
    TEST_BEGIN str_cx_lr
    jal     ra, cx_line_fill
    la      s3, cx_line + 16
    LIX     t4, 0x0badcafe
    sw      t4, 0(s3)
    jal     ra, cx_flush
    LIX     t4, 0x0fedbeef
    li      t3, -1                  /* SC's rd poisoned */
    li      t2, -1                  /* LR's rd poisoned */
    TRAP_ARM .Lcx_trap_lr
    lr.w    t2, (s3)
    sc.w    t3, t4, (s3)
    TRAP_DISARM
    mv      s1, t2
    mv      s2, t3
    jal     ra, cx_flush
    LWUX    s4, 0(s3)
    la      a0, str_cx_lr
    LIX     a1, 0x0badcafe
    mv      a2, s1
    call    check
    TEST_BEGIN str_cx_sc
    la      a0, str_cx_sc
    li      a1, 0
    mv      a2, s2
    call    check
    TEST_BEGIN str_cx_sc_wb
    la      a0, str_cx_sc_wb
    LIX     a1, 0x0fedbeef
    mv      a2, s4
    call    check
    TRAP_FAILS .Lcx_trap_lr, str_cx_lr, str_cx_sc, str_cx_sc_wb

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  CBO.ZERO on dirty and evicted lines (Zicboz; armed)
 * ======================================================================= */
test_cx_cboz:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    /* --- the whole buffer dirty, its first block zeroed, then all of
     *     it evicted: the dirty data must not come back --- */
    TEST_BEGIN str_cx_cz_d_zero
    jal     ra, cx_line_fill
    la      s3, cx_line
    TRAP_ARM .Lcx_trap_cz_d
    cbo.zero (s3)
    TRAP_DISARM
    jal     ra, cx_flush
    li      a3, CX_CBOZ_BLOCK
    jal     ra, cx_zero_check
    mv      s2, s4
    la      a0, str_cx_cz_d_zero
    li      a1, 0
    mv      a2, s1
    call    check
    TEST_BEGIN str_cx_cz_d_rest
    la      a0, str_cx_cz_d_rest
    li      a1, 0
    mv      a2, s2
    call    check
    TRAP_FAILS .Lcx_trap_cz_d, str_cx_cz_d_zero, str_cx_cz_d_rest

    /* --- the buffer written and evicted, its first block zeroed (not
     *     in the cache), evicted again --- */
    TEST_BEGIN str_cx_cz_e_zero
    jal     ra, cx_line_fill
    jal     ra, cx_flush
    la      s3, cx_line
    TRAP_ARM .Lcx_trap_cz_e
    cbo.zero (s3)
    TRAP_DISARM
    jal     ra, cx_flush
    li      a3, CX_CBOZ_BLOCK
    jal     ra, cx_zero_check
    mv      s2, s4
    la      a0, str_cx_cz_e_zero
    li      a1, 0
    mv      a2, s1
    call    check
    TEST_BEGIN str_cx_cz_e_rest
    la      a0, str_cx_cz_e_rest
    li      a1, 0
    mv      a2, s2
    call    check
    TRAP_FAILS .Lcx_trap_cz_e, str_cx_cz_e_zero, str_cx_cz_e_rest

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  Address table and strings
 * ======================================================================= */
    CX_ADDR_TABLE cx_addr_tab

    .section .rodata
    .if XLEN == 64
str_cx_cap_up:     .asciz "SD fill of 1 MiB upwards, read back downwards: first wrong address (0 = none)"
str_cx_cap_down:   .asciz "SD fill of 1 MiB downwards, complement, read back upwards: first wrong address (0 = none)"
str_cx_pair_now:   .asciz "SD at address-bit pairs over 512 KiB, read back at once: first wrong address (0 = none)"
str_cx_pair_flush: .asciz "SD at address-bit pairs over 512 KiB, reversed, complement, read back after eviction: first wrong address (0 = none)"
    .else
str_cx_cap_up:     .asciz "SW fill of 1 MiB upwards, read back downwards: first wrong address (0 = none)"
str_cx_cap_down:   .asciz "SW fill of 1 MiB downwards, complement, read back upwards: first wrong address (0 = none)"
str_cx_pair_now:   .asciz "SW at address-bit pairs over 512 KiB, read back at once: first wrong address (0 = none)"
str_cx_pair_flush: .asciz "SW at address-bit pairs over 512 KiB, reversed, complement, read back after eviction: first wrong address (0 = none)"
    .endif
str_cx_amo_d_rd:   .asciz "AMOADD.W on a dirty line: rd = the value just stored"
str_cx_amo_d_mem:  .asciz "AMOADD.W on a dirty line: memory = the sum"
str_cx_amo_e_rd:   .asciz "AMOADD.W on an evicted line: rd = the value in memory"
str_cx_amo_e_mem:  .asciz "AMOADD.W on an evicted line: memory = the sum"
str_cx_amo_e_wb:   .asciz "AMOADD.W on an evicted line: the sum survives write-back"
str_cx_lr:         .asciz "LR.W on an evicted line: reads the value in memory"
str_cx_sc:         .asciz "SC.W after LR.W on an evicted line: succeeds (rd = 0)"
str_cx_sc_wb:      .asciz "SC.W after LR.W on an evicted line: the value survives write-back"
str_cx_cz_d_zero:  .asciz "CBO.ZERO on a dirty line: the zeros survive write-back"
str_cx_cz_d_rest:  .asciz "CBO.ZERO on a dirty line: the next line keeps its data"
str_cx_cz_e_zero:  .asciz "CBO.ZERO on an evicted line: the zeros survive write-back"
str_cx_cz_e_rest:  .asciz "CBO.ZERO on an evicted line: the next line keeps its data"

/* =======================================================================
 *  Test buffer: two lines, aligned well past any line size, outside
 *  bx_region (so cx_flush never reads it back in)
 * ======================================================================= */
    .section .bss
    .balign 256
cx_line:    .skip CX_BUF_BYTES
