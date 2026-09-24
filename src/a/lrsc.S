/* =====================================================================
 * a/lrsc.S  --  RV64A load-reserved / store-conditional:
 *                LR.W, SC.W, and LR.D, SC.D (RV64 only)
 *
 * Part of the A suite; see a/tests.S for how this plugs into the rest
 * (main_tests.S -> a/tests.S -> here), and common.S for the
 * boot/UART/reporting harness everything sits on ("check" is used from
 * there, nothing else).
 *
 * LR rd, (rs1) loads the word/doubleword at rs1 into rd (.W
 * sign-extended) and registers a reservation on it. SC rd, rs2, (rs1)
 * stores rs2 there only if this hart still holds a reservation covering
 * that address, and writes 0 to rd on success or a nonzero code on
 * failure (memory untouched). Either way, SC invalidates the
 * reservation. The address is rs1 itself (no offset field). LR has no
 * rs2 (the field is fixed at 0).
 *
 * What is checked:
 *   - Values: LR's rd (sign extension for .W, none from bit 31 for .D),
 *     SC's rd = 0 and the stored value, at both word offsets of a
 *     doubleword for .W. On RV64 SC.W's rs2 carries garbage above bit
 *     31 once, which must not be stored.
 *   - LR leaves memory alone, and SC writes exactly w bytes: the target
 *     and the words just below and above it are checked.
 *   - Failure, the rules the spec makes mandatory: an SC with no
 *     reservation fails (the second of two SCs after one LR, and an SC
 *     after a failed SC), an SC outside the reservation of the most
 *     recent LR fails (the reservation set of an earlier LR doesn't
 *     survive a later LR elsewhere), and a failed SC leaves memory
 *     alone. Failure is checked as rd != 0 (snez), since the spec only
 *     fixes "nonzero".
 *   - rd=x0 for SC: the store still happens.
 *   - Register fields swept once through LR.W and SC.W (rd, rs1, rs2).
 *   - Aliasing: LR rd==rs1 (the address must be read before rd is
 *     written, and the reservation must be on that address), SC rd==rs2
 *     (the value must be read before rd is written), SC rd==rs1, SC
 *     rs1==rs2 (stores its own address), SC rd==rs1==rs2, and rs1=sp.
 *     Sources are checked unmodified.
 *   - The aq/rl ordering bits must not change the result: every LR and
 *     SC is also run as .aq, .rl and .aqrl, paired with the plain form
 *     of the other. (Ordering itself is unobservable on a single hart.)
 *   - The standard LR/SC retry loop (an atomic increment, with SC
 *     rd==rs2) run three times.
 *
 * ASSUMPTIONS, beyond what the spec strictly guarantees:
 *   - An LR followed directly by its SC (only plain ALU instructions in
 *     between: the spec's "constrained LR/SC loop" shape) succeeds on
 *     the first try on a single hart. The spec allows spurious SC
 *     failure and only promises eventual success, but no single-hart
 *     implementation fails a constrained pair without cause. The
 *     success cases here keep to that shape: every load, store and call
 *     happens before the LR or after the SC.
 *   - The reservation set is smaller than 4 KiB: the "other address"
 *     cases use lrsc_far, 4096 bytes from the target. (Real reservation
 *     granules are a cache line or less.)
 *
 * TRAPS: every LR/SC under test runs armed, one arming across each
 * LR...SC group (armed before the LR, disarmed after the last SC, so
 * no stack store lands between them): on a hart without A, each check
 * of that test is a check_trap FAIL with the mcause, never an
 * UNEXPECTED TRAP hang.
 *
 * Not tested: misaligned addresses (they must trap), mixed-width pairs (LR.D then SC.W: the spec
 * leaves the outcome open), a regular store between LR and SC by the
 * same hart (also left open), and reservation loss on a trap.
 *
 * Bit independence across fields (bitx_a_lrsc, at the end): for LR
 * every bit pair among rd/rs1 and aq/rl, C(12,2) = 66 cases, each
 * checking rd and that the reservation landed (a following background
 * SC succeeds); for SC every bit pair among rd/rs1/rs2 and aq/rl,
 * C(17,2) = 136 cases, each checking rd and memory. See bitx.inc and
 * BX_C_LR/BX_C_SC below.
 *
 * RV32 image (xlen.inc): LR.D/SC.D and the rs2-upper-half case are
 * RV64-only and left out; everything else runs on both widths.
 * ===================================================================== */

    .include "xlen.inc"
    .include "harness.inc"

    .option norvc            /* no compressed LR/SC exist, but the helper
                               * li/mv/branch sequences must never be
                               * silently re-encoded either */

    .include "bitx.inc"

    .global tests_a_lrsc

    .section .text

/* lrsc_buf: six words, word i = LRSC_FILL + i, and lrsc_far, 4096 bytes
 * further on: six words, word i = LRSC_FAR_FILL + i; both refilled by
 * lrsc_fill before every case. The target is lrsc_buf + 8 (+ 4 for the
 * upper word of that doubleword), so a word below and a word above
 * always hold a known value; the "other address" is lrsc_far + 8. */
    .equ    LRSC_FILL,     0x5a5aa5a0
    .equ    LRSC_FAR_FILL, 0x3c3cc3c0

/* =======================================================================
 *  Shared macros
 * ======================================================================= */

/* CHKI name, expect, actual / CHKR name, ereg, actual -- check(name,
 * expect, actual), the expected value a constant (LIX) or a register.
 * actual and ereg must not be a0/a1. */
.macro CHKI name, expect, actual
    la      a0, \name
    LIX     a1, \expect
    mv      a2, \actual
    call    check
.endm

.macro CHKR name, ereg, actual
    la      a0, \name
    mv      a1, \ereg
    mv      a2, \actual
    call    check
.endm

/* STW w, reg, addr / LDW w, reg, addr -- w-byte store, and a read-back
 * that is zero-extended for w = 4 (so it matches LIX'd 32-bit patterns
 * on RV64). */
.macro STW w, reg, addr
    .if \w == 4
    sw      \reg, \addr
    .else
    sd      \reg, \addr
    .endif
.endm

.macro LDW w, reg, addr
    .if \w == 4
    LWUX    \reg, \addr
    .else
    ld      \reg, \addr
    .endif
.endm

/* T_LRSC_VAL lr, sc, w, off, mem, v, erd, emem, nlr, nsc, nmem -- the
 * w-byte target at lrsc_buf + 8 + off set to mem, then the pair
 *     lr  t2, (t3)
 *     sc  t5, t4, (t3)      rs2 = v
 * back to back. Three checks: LR's rd against erd (for .W: the word
 * sign-extended), SC's rd against 0, and the target, read back
 * zero-extended, against emem. This t2/t3/t4 encoding is also the bitx
 * reference (BX_C_LR/BX_C_SC). */
.macro T_LRSC_VAL lr, sc, w, off, mem, v, erd, emem, nlr, nsc, nmem
    TEST_BEGIN \nlr
    jal     ra, lrsc_fill
    la      t3, lrsc_buf + 8 + \off
    LIX     t4, \mem
    STW     \w, t4, 0(t3)
    LIX     t4, \v
    TRAP_ARM .Llv_trap\@
    \lr     t2, (t3)
    \sc     t5, t4, (t3)
    TRAP_DISARM
    mv      s1, t2                  /* check clobbers t0-t6 */
    mv      s2, t5
    LDW     \w, s4, 0(t3)
    CHKI    \nlr, \erd, s1
    TEST_BEGIN \nsc
    CHKI    \nsc, 0, s2
    TEST_BEGIN \nmem
    CHKI    \nmem, \emem, s4
    TRAP_FAILS .Llv_trap\@, \nlr, \nsc, \nmem
.endm

/* NEIGH_ACC w, off -- t5 = OR of (word ^ its fill value) over the word
 * just below the w-byte target at lrsc_buf + 8 + off (t3) and the word
 * just above it: 0 iff both still hold their fill. */
.macro NEIGH_ACC w, off
    lw      t0, -4(t3)
    LIX     t1, LRSC_FILL + (8 + \off - 4) / 4
    xor     t5, t0, t1
    lw      t0, \w(t3)
    LIX     t1, LRSC_FILL + (8 + \off + \w) / 4
    xor     t0, t0, t1
    or      t5, t5, t0
.endm

/* T_LR_NEIGH lr, w, off, name -- LR on the fill word(s) at
 * lrsc_buf + 8 + off must leave the target and both neighbouring words
 * as they were (one check, 0 = all unchanged). */
.macro T_LR_NEIGH lr, w, off, name
    TEST_BEGIN \name
    jal     ra, lrsc_fill
    la      t3, lrsc_buf + 8 + \off
    TRAP_ARM .Lln_trap\@
    \lr     t2, (t3)
    TRAP_DISARM
    NEIGH_ACC \w, \off
    lw      t0, 0(t3)
    LIX     t1, LRSC_FILL + (8 + \off) / 4
    xor     t0, t0, t1
    or      t5, t5, t0
    .if \w == 8
    lw      t0, 4(t3)
    LIX     t1, LRSC_FILL + (8 + \off + 4) / 4
    xor     t0, t0, t1
    or      t5, t5, t0
    .endif
    mv      s1, t5
    CHKI    \name, 0, s1
    TRAP_FAILS .Lln_trap\@, \name
.endm

/* T_SC_NEIGH lr, sc, w, off, name -- a successful SC of all-ones to
 * lrsc_buf + 8 + off must leave the words just below and above it
 * alone. rs2 = -1 is sign-extended to the full register, so an SC.W
 * that stored 8 bytes would overwrite the word above. */
.macro T_SC_NEIGH lr, sc, w, off, name
    TEST_BEGIN \name
    jal     ra, lrsc_fill
    la      t3, lrsc_buf + 8 + \off
    LIX     t4, -1
    TRAP_ARM .Lsn_trap\@
    \lr     t2, (t3)
    \sc     t2, t4, (t3)
    TRAP_DISARM
    NEIGH_ACC \w, \off
    mv      s1, t5
    CHKI    \name, 0, s1
    TRAP_FAILS .Lsn_trap\@, \name
.endm

/* T_LR_RD / T_LR_RS1 / T_SC_RD / T_SC_RS1 / T_SC_RS2 reg, name -- sweep
 * one register field at a time through LR.W / SC.W, the other fields
 * fixed at t2/t3/t4/t5, none of which is in the swept lists (ra, t0,
 * s0, a0, s10, t6). LR_RD checks rd (0x80000123, sign-extended);
 * LR_RS1 checks rd (0x123), which is only right if the right address
 * was used. SC_RD checks rd = 0 (poisoned first, so "never written"
 * fails); SC_RS1/SC_RS2 check memory (0x456 / 0x789). */
.macro T_LR_RD rdreg, name
    TEST_BEGIN \name
    jal     ra, lrsc_fill
    la      t3, lrsc_buf + 8
    LIX     t4, 0x80000123
    sw      t4, 0(t3)
    TRAP_ARM .Llrd_trap\@
    lr.w    \rdreg, (t3)
    mv      t2, \rdreg              /* capture: rdreg may be a0 */
    TRAP_DISARM
    CHKI    \name, 0xffffffff80000123, t2
    TRAP_FAILS .Llrd_trap\@, \name
.endm

.macro T_LR_RS1 rs1reg, name
    TEST_BEGIN \name
    jal     ra, lrsc_fill
    la      \rs1reg, lrsc_buf + 8
    LIX     t4, 0x123
    sw      t4, 0(\rs1reg)
    TRAP_ARM .Llrs1_trap\@
    lr.w    t2, (\rs1reg)
    TRAP_DISARM
    CHKI    \name, 0x123, t2
    TRAP_FAILS .Llrs1_trap\@, \name
.endm

.macro T_SC_RD rdreg, name
    TEST_BEGIN \name
    jal     ra, lrsc_fill
    la      t3, lrsc_buf + 8
    LIX     t4, 0x456
    LIX     \rdreg, 0x5a5a5a5a      /* poison: must become 0 */
    TRAP_ARM .Lsrd_trap\@
    lr.w    t2, (t3)
    sc.w    \rdreg, t4, (t3)
    mv      t2, \rdreg
    TRAP_DISARM
    CHKI    \name, 0, t2
    TRAP_FAILS .Lsrd_trap\@, \name
.endm

.macro T_SC_RS1 rs1reg, name
    TEST_BEGIN \name
    jal     ra, lrsc_fill
    la      \rs1reg, lrsc_buf + 8
    LIX     t4, 0x456
    TRAP_ARM .Lsrs1_trap\@
    lr.w    t2, (\rs1reg)
    sc.w    t5, t4, (\rs1reg)
    TRAP_DISARM
    la      t3, lrsc_buf + 8
    LWUX    t2, 0(t3)
    CHKI    \name, 0x456, t2
    TRAP_FAILS .Lsrs1_trap\@, \name
.endm

.macro T_SC_RS2 rs2reg, name
    TEST_BEGIN \name
    jal     ra, lrsc_fill
    la      t3, lrsc_buf + 8
    LIX     \rs2reg, 0x789
    TRAP_ARM .Lsrs2_trap\@
    lr.w    t2, (t3)
    sc.w    t5, \rs2reg, (t3)
    TRAP_DISARM
    LWUX    t2, 0(t3)
    CHKI    \name, 0x789, t2
    TRAP_FAILS .Lsrs2_trap\@, \name
.endm

/* BX_C_LR lr, sc, w, nm, rd, rs1, o -- one LR bit-independence case
 * (bitx.inc): rd/rs1 as given, o = the raw aq/rl field (bit 1 = aq,
 * bit 0 = rl), which only selects the mnemonic suffix.
 *
 * Two register-sized slots, bx_lrsc_ref and bx_lrsc_dut, are set to the
 * sentinel with the pool's vb as the w-byte value at offset 0. The
 * reference is the same LR through the background encoding (rd=t2,
 * rs1=t3, no ordering bits) on bx_lrsc_ref -- the encoding the
 * T_LRSC_VAL tables pin down against literals. The case under test runs
 * on bx_lrsc_dut with rd pre-loaded with the sentinel and rs1 = the
 * address, loaded last so it always holds one. It is followed at once
 * by a background SC to bx_lrsc_dut, which only succeeds if the LR
 * under test put its reservation on the right address. Two checks:
 * rd, then that SC's rd (0).
 *
 * Besides the reserved registers listed in bitx.inc, a4 (x14) takes
 * the SC's result, and s3 holds bx_lrsc_dut's address (and is reused
 * to disarm); both have three bits set, so neither is ever a
 * candidate.
 *
 * Trapping: one TRAP_ARM, before anything is swept, covers the
 * reference LR, the LR under test and the SC (one-shot: whichever
 * traps first), and puts no store between an LR and its SC; after a
 * trap, BX_TRAP_FAILS restores sp/gp/tp and reports both names as
 * check_trap FAILs. BX_C_SC_ below does the same. */
.macro BX_C_LR lr, sc, w, nm, rd, rs1, o
    .if (\o) == 0
    BX_C_LR_ \lr, \sc, \w, \nm, \rd, \rs1, \lr, 0, 0
    .elseif (\o) == 1
    BX_C_LR_ \lr, \sc, \w, \nm, \rd, \rs1, \lr\().rl, 0, 1
    .elseif (\o) == 2
    BX_C_LR_ \lr, \sc, \w, \nm, \rd, \rs1, \lr\().aq, 1, 0
    .else
    BX_C_LR_ \lr, \sc, \w, \nm, \rd, \rs1, \lr\().aqrl, 1, 1
    .endif
.endm

.macro BX_C_LR_ lr, sc, w, nm, rd, rs1, dut, aq, rl
    BX_NAME .Lbxl_n\@, "\nm bitx rd=x\rd rs1=x\rs1 aq=\aq rl=\rl"
    BX_NAME .Lbxl_r\@, "\nm bitx rd=x\rd rs1=x\rs1 aq=\aq rl=\rl reserved"
    BX_ENTER .Lbxl_n\@
    TRAP_ARM .Lbxl_trap\@          /* covers every LR/SC below */
    .option push
    .option norelax
    la      t3, bx_lrsc_ref
    la      s3, bx_lrsc_dut
    .option pop
    BX_PV   t4, 2
    REG_S   t4, 0(t3)
    REG_S   t4, 0(s3)
    BX_PV   t4, 1
    STW     \w, t4, 0(t3)
    STW     \w, t4, 0(s3)
    \lr     t2, (t3)
    mv      t5, t2
    BX_PV   x\rd, 2
    mv      x\rs1, s3
    \dut    x\rd, (x\rs1)
    mv      t6, x\rd
    \sc     a4, t4, (s3)
    TRAP_DISARM_R s3
    BX_REPORT_AT .Lbxl_n\@
    mv      t5, zero
    mv      t6, a4
    BX_REPORT_AT .Lbxl_r\@
    BX_TRAP_FAILS .Lbxl_trap\@, .Lbxl_n\@, .Lbxl_r\@
.endm

/* BX_C_SC sc, lr, w, nm, rd, rs1, rs2, o -- one SC bit-independence
 * case: rd/rs1/rs2 as given, o = the raw aq/rl field.
 *
 * Same two slots as BX_C_LR, holding the sentinel with vb as the w-byte
 * old value (so on RV64 an SC.W also has the sentinel's upper word
 * above it, which must survive). The reference is a background LR + SC
 * (rd=t2, rs1=t3, rs2=t4, no ordering bits) on bx_lrsc_ref. The case
 * under test loads rd (the sentinel), rs2 (va) and rs1 (the address,
 * last: when rs2 aliases rs1 the stored value is that address, and the
 * reference is fed the same), and only then runs a background LR on
 * bx_lrsc_dut and the SC under test back to back, with no load in
 * between. Two checks: rd against 0, then the whole register-sized
 * slot against the reference slot.
 *
 * a4 (x14) is the background LRs' rd and then carries the DUT slot's
 * read-back, a5 (x15) the reference slot's, across the first check
 * (check leaves a3-a7 alone); s3 holds bx_lrsc_dut's address. None of
 * them is ever a candidate. */
.macro BX_C_SC sc, lr, w, nm, rd, rs1, rs2, o
    .if (\o) == 0
    BX_C_SC_ \sc, \lr, \w, \nm, \rd, \rs1, \rs2, \sc, 0, 0
    .elseif (\o) == 1
    BX_C_SC_ \sc, \lr, \w, \nm, \rd, \rs1, \rs2, \sc\().rl, 0, 1
    .elseif (\o) == 2
    BX_C_SC_ \sc, \lr, \w, \nm, \rd, \rs1, \rs2, \sc\().aq, 1, 0
    .else
    BX_C_SC_ \sc, \lr, \w, \nm, \rd, \rs1, \rs2, \sc\().aqrl, 1, 1
    .endif
.endm

.macro BX_C_SC_ sc, lr, w, nm, rd, rs1, rs2, dut, aq, rl
    BX_NAME .Lbxs_n\@, "\nm bitx rd=x\rd rs1=x\rs1 rs2=x\rs2 aq=\aq rl=\rl"
    BX_NAME .Lbxs_m\@, "\nm bitx rd=x\rd rs1=x\rs1 rs2=x\rs2 aq=\aq rl=\rl mem"
    BX_ENTER .Lbxs_n\@
    TRAP_ARM .Lbxs_trap\@          /* covers every LR/SC below */
    .option push
    .option norelax
    la      t3, bx_lrsc_ref
    la      s3, bx_lrsc_dut
    .option pop
    BX_PV   t4, 2
    REG_S   t4, 0(t3)
    REG_S   t4, 0(s3)
    BX_PV   t4, 1
    STW     \w, t4, 0(t3)
    STW     \w, t4, 0(s3)
    .if \rs1 == \rs2
    mv      t4, s3
    .else
    BX_PV   t4, 0
    .endif
    \lr     a4, (t3)
    \sc     t2, t4, (t3)
    REG_L   a5, 0(t3)
    BX_PV   x\rd, 2
    BX_PV   x\rs2, 0
    mv      x\rs1, s3
    \lr     a4, (s3)
    \dut    x\rd, x\rs2, (x\rs1)
    mv      t6, x\rd
    REG_L   a4, 0(s3)
    TRAP_DISARM_R s3
    mv      t5, zero
    BX_REPORT_AT .Lbxs_n\@
    mv      t5, a5
    mv      t6, a4
    BX_REPORT_AT .Lbxs_m\@
    BX_TRAP_FAILS .Lbxs_trap\@, .Lbxs_n\@, .Lbxs_m\@
.endm

tests_a_lrsc:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    jal     ra, test_lrsc_vals
    jal     ra, test_lrsc_fail
    jal     ra, test_lrsc_regs
    jal     ra, test_lrsc_order

    jal     ra, bitx_a_lrsc

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* lrsc_fill: lrsc_buf word i = LRSC_FILL + i, lrsc_far word i =
 * LRSC_FAR_FILL + i. Clobbers t0/t1 only. */
lrsc_fill:
    la      t0, lrsc_buf
    LIX     t1, LRSC_FILL
    sw      t1, 0(t0)
    addi    t1, t1, 1
    sw      t1, 4(t0)
    addi    t1, t1, 1
    sw      t1, 8(t0)
    addi    t1, t1, 1
    sw      t1, 12(t0)
    addi    t1, t1, 1
    sw      t1, 16(t0)
    addi    t1, t1, 1
    sw      t1, 20(t0)
    la      t0, lrsc_far
    LIX     t1, LRSC_FAR_FILL
    sw      t1, 0(t0)
    addi    t1, t1, 1
    sw      t1, 4(t0)
    addi    t1, t1, 1
    sw      t1, 8(t0)
    addi    t1, t1, 1
    sw      t1, 12(t0)
    addi    t1, t1, 1
    sw      t1, 16(t0)
    addi    t1, t1, 1
    sw      t1, 20(t0)
    ret

/* =======================================================================
 *  Values and write width
 * ======================================================================= */
test_lrsc_vals:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    /* ----- LR.W / SC.W ----- */
    T_LRSC_VAL lr.w, sc.w, 4, 0, 0x12345678, 0x9abcdef0, 0x12345678, 0x9abcdef0, str_lrsc_w_basic_lr, str_lrsc_w_basic_sc, str_lrsc_w_basic_mem
    T_LRSC_VAL lr.w, sc.w, 4, 4, 0x80000000, 0x00000001, 0xffffffff80000000, 0x00000001, str_lrsc_w_sext_lr, str_lrsc_w_sext_sc, str_lrsc_w_sext_mem
    T_LRSC_VAL lr.w, sc.w, 4, 0, 0xffffffff, 0x00000000, 0xffffffffffffffff, 0x00000000, str_lrsc_w_zero_lr, str_lrsc_w_zero_sc, str_lrsc_w_zero_mem
    .if XLEN == 64
    /* rs2's upper half is garbage and must not be stored */
    T_LRSC_VAL lr.w, sc.w, 4, 4, 0x00000005, 0xdeadbeef12345678, 0x00000005, 0x12345678, str_lrsc_w_upper_lr, str_lrsc_w_upper_sc, str_lrsc_w_upper_mem
    .endif

    T_LR_NEIGH lr.w, 4, 0, str_lr_w_neigh_0
    T_LR_NEIGH lr.w, 4, 4, str_lr_w_neigh_4
    T_SC_NEIGH lr.w, sc.w, 4, 0, str_sc_w_neigh_0
    T_SC_NEIGH lr.w, sc.w, 4, 4, str_sc_w_neigh_4

    /* ----- LR.D / SC.D ----- */
    .if XLEN == 64
    T_LRSC_VAL lr.d, sc.d, 8, 0, 0x0123456789abcdef, 0xfedcba9876543210, 0x0123456789abcdef, 0xfedcba9876543210, str_lrsc_d_basic_lr, str_lrsc_d_basic_sc, str_lrsc_d_basic_mem
    /* bit 31 set, bit 63 clear: no sign extension from bit 31 */
    T_LRSC_VAL lr.d, sc.d, 8, 0, 0x00000000ffffffff, 0x8000000000000000, 0x00000000ffffffff, 0x8000000000000000, str_lrsc_d_bit31_lr, str_lrsc_d_bit31_sc, str_lrsc_d_bit31_mem

    T_LR_NEIGH lr.d, 8, 0, str_lr_d_neigh
    T_SC_NEIGH lr.d, sc.d, 8, 0, str_sc_d_neigh
    .endif

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  Reservation rules and failure (through LR.W / SC.W)
 * ======================================================================= */
test_lrsc_fail:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    /* --- one LR, two SCs: the first succeeds and consumes the
     *     reservation, so the second must fail and store nothing --- */
    TEST_BEGIN str_sc_twice_first
    jal     ra, lrsc_fill
    la      t3, lrsc_buf + 8
    LIX     t4, 0x11111111
    LIX     t5, 0x22222222
    TRAP_ARM .Llrsc_trap_twice
    lr.w    t2, (t3)
    sc.w    s1, t4, (t3)
    sc.w    s2, t5, (t3)
    TRAP_DISARM
    LWUX    s4, 0(t3)
    snez    s2, s2
    CHKI    str_sc_twice_first, 0, s1
    TEST_BEGIN str_sc_twice_second
    CHKI    str_sc_twice_second, 1, s2
    TEST_BEGIN str_sc_twice_mem
    CHKI    str_sc_twice_mem, 0x11111111, s4
    TRAP_FAILS .Llrsc_trap_twice, str_sc_twice_first, str_sc_twice_second, str_sc_twice_mem

    /* --- SC to an address outside the reservation fails and stores
     *     nothing there; a failed SC also invalidates the reservation,
     *     so an SC to the reserved address right after fails too --- */
    TEST_BEGIN str_sc_far_fails
    jal     ra, lrsc_fill
    la      t3, lrsc_buf + 8
    la      t4, lrsc_far + 8
    LIX     t5, 0x33333333
    TRAP_ARM .Llrsc_trap_far
    lr.w    t2, (t3)
    sc.w    s1, t5, (t4)
    sc.w    s2, t5, (t3)
    TRAP_DISARM
    LWUX    s4, 0(t4)
    LWUX    s5, 0(t3)
    snez    s1, s1
    snez    s2, s2
    CHKI    str_sc_far_fails, 1, s1
    TEST_BEGIN str_sc_far_mem
    CHKI    str_sc_far_mem, LRSC_FAR_FILL + 2, s4
    TEST_BEGIN str_sc_after_fail
    CHKI    str_sc_after_fail, 1, s2
    TEST_BEGIN str_sc_after_fail_mem
    CHKI    str_sc_after_fail_mem, LRSC_FILL + 2, s5
    TRAP_FAILS .Llrsc_trap_far, str_sc_far_fails, str_sc_far_mem, str_sc_after_fail, str_sc_after_fail_mem

    /* --- a later LR elsewhere replaces the reservation: SC to the
     *     first address fails --- */
    TEST_BEGIN str_sc_old_resv
    jal     ra, lrsc_fill
    la      t3, lrsc_buf + 8
    la      t4, lrsc_far + 8
    LIX     t5, 0x44444444
    TRAP_ARM .Llrsc_trap_old
    lr.w    t2, (t3)
    lr.w    t6, (t4)
    sc.w    s1, t5, (t3)
    TRAP_DISARM
    LWUX    s4, 0(t3)
    snez    s1, s1
    CHKI    str_sc_old_resv, 1, s1
    TEST_BEGIN str_sc_old_resv_mem
    CHKI    str_sc_old_resv_mem, LRSC_FILL + 2, s4
    TRAP_FAILS .Llrsc_trap_old, str_sc_old_resv, str_sc_old_resv_mem

    /* --- ... and SC to the second address succeeds --- */
    TEST_BEGIN str_sc_new_resv
    jal     ra, lrsc_fill
    la      t3, lrsc_buf + 8
    la      t4, lrsc_far + 8
    LIX     t5, 0x55555555
    TRAP_ARM .Llrsc_trap_new
    lr.w    t2, (t3)
    lr.w    t6, (t4)
    sc.w    s1, t5, (t4)
    TRAP_DISARM
    LWUX    s4, 0(t4)
    CHKI    str_sc_new_resv, 0, s1
    TEST_BEGIN str_sc_new_resv_mem
    CHKI    str_sc_new_resv_mem, 0x55555555, s4
    TRAP_FAILS .Llrsc_trap_new, str_sc_new_resv, str_sc_new_resv_mem

    /* --- rd=x0: a successful SC still stores; the next one (no
     *     reservation left) stores nothing and reports failure --- */
    TEST_BEGIN str_sc_rd_x0_mem
    jal     ra, lrsc_fill
    la      t3, lrsc_buf + 8
    LIX     t4, 0x66666666
    LIX     t5, 0x77777777
    TRAP_ARM .Llrsc_trap_x0
    lr.w    t2, (t3)
    sc.w    zero, t4, (t3)
    sc.w    zero, t5, (t3)
    TRAP_DISARM
    mv      s1, zero
    LWUX    s4, 0(t3)
    CHKI    str_sc_rd_x0_mem, 0x66666666, s4
    TEST_BEGIN str_sc_rd_x0_zero
    CHKI    str_sc_rd_x0_zero, 0, s1
    TRAP_FAILS .Llrsc_trap_x0, str_sc_rd_x0_mem, str_sc_rd_x0_zero

    /* --- the standard retry loop, an atomic increment (SC rd==rs2),
     *     three times. A SC that never succeeds hangs here -- with this
     *     test's name already printed. --- */
    TEST_BEGIN str_lrsc_loop
    jal     ra, lrsc_fill
    la      t3, lrsc_buf + 8
    LIX     t0, 100
    sw      t0, 0(t3)
    li      t4, 1
    li      s4, 3
    TRAP_ARM .Llrsc_trap_loop
2:
1:  lr.w    t0, (t3)
    add     t1, t0, t4
    sc.w    t1, t1, (t3)
    bnez    t1, 1b
    addi    s4, s4, -1
    bnez    s4, 2b
    TRAP_DISARM
    LWUX    s1, 0(t3)
    CHKI    str_lrsc_loop, 103, s1
    TRAP_FAILS .Llrsc_trap_loop, str_lrsc_loop

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  Register fields and aliasing (through LR.W / SC.W unless noted)
 * ======================================================================= */
test_lrsc_regs:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    T_LR_RD ra,  str_lr_rd_ra
    T_LR_RD t0,  str_lr_rd_t0
    T_LR_RD s0,  str_lr_rd_s0
    T_LR_RD a0,  str_lr_rd_a0
    T_LR_RD s10, str_lr_rd_s10
    T_LR_RD t6,  str_lr_rd_t6

    T_LR_RS1 ra,  str_lr_rs1_ra
    T_LR_RS1 t0,  str_lr_rs1_t0
    T_LR_RS1 s0,  str_lr_rs1_s0
    T_LR_RS1 a0,  str_lr_rs1_a0
    T_LR_RS1 s10, str_lr_rs1_s10
    T_LR_RS1 t6,  str_lr_rs1_t6

    T_SC_RD ra,  str_sc_rd_ra
    T_SC_RD t0,  str_sc_rd_t0
    T_SC_RD s0,  str_sc_rd_s0
    T_SC_RD a0,  str_sc_rd_a0
    T_SC_RD s10, str_sc_rd_s10
    T_SC_RD t6,  str_sc_rd_t6

    T_SC_RS1 ra,  str_sc_rs1_ra
    T_SC_RS1 t0,  str_sc_rs1_t0
    T_SC_RS1 s0,  str_sc_rs1_s0
    T_SC_RS1 a0,  str_sc_rs1_a0
    T_SC_RS1 s10, str_sc_rs1_s10
    T_SC_RS1 t6,  str_sc_rs1_t6

    T_SC_RS2 ra,  str_sc_rs2_ra
    T_SC_RS2 t0,  str_sc_rs2_t0
    T_SC_RS2 s0,  str_sc_rs2_s0
    T_SC_RS2 a0,  str_sc_rs2_a0
    T_SC_RS2 s10, str_sc_rs2_s10
    T_SC_RS2 t6,  str_sc_rs2_t6

    /* --- LR rd==rs1: the address is read before rd is overwritten,
     *     and the reservation is on that address (the SC succeeds) --- */
    TEST_BEGIN str_lr_alias_rd_rs1
    jal     ra, lrsc_fill
    la      t3, lrsc_buf + 8
    mv      s3, t3
    LIX     t4, 0x5678
    sw      t4, 0(t3)
    TRAP_ARM .Llrsc_trap_lr_rd_rs1
    lr.w    t3, (t3)
    sc.w    s2, t4, (s3)
    TRAP_DISARM
    mv      s1, t3
    CHKI    str_lr_alias_rd_rs1, 0x5678, s1
    TEST_BEGIN str_lr_alias_rd_rs1_sc
    CHKI    str_lr_alias_rd_rs1_sc, 0, s2
    TRAP_FAILS .Llrsc_trap_lr_rd_rs1, str_lr_alias_rd_rs1, str_lr_alias_rd_rs1_sc

    /* --- SC rd==rs2: the value is read before rd gets the result --- */
    TEST_BEGIN str_sc_alias_rd_rs2_rd
    jal     ra, lrsc_fill
    la      t3, lrsc_buf + 8
    LIX     t4, 0x0badcafe
    TRAP_ARM .Llrsc_trap_sc_rd_rs2
    lr.w    t2, (t3)
    sc.w    t4, t4, (t3)
    TRAP_DISARM
    mv      s1, t4
    LWUX    s2, 0(t3)
    CHKI    str_sc_alias_rd_rs2_rd, 0, s1
    TEST_BEGIN str_sc_alias_rd_rs2_mem
    CHKI    str_sc_alias_rd_rs2_mem, 0x0badcafe, s2
    TRAP_FAILS .Llrsc_trap_sc_rd_rs2, str_sc_alias_rd_rs2_rd, str_sc_alias_rd_rs2_mem

    /* --- SC rd==rs1: the address is read before rd gets the result --- */
    TEST_BEGIN str_sc_alias_rd_rs1_rd
    jal     ra, lrsc_fill
    la      t3, lrsc_buf + 8
    mv      s3, t3
    LIX     t4, 0x600df00d
    TRAP_ARM .Llrsc_trap_sc_rd_rs1
    lr.w    t2, (t3)
    sc.w    t3, t4, (t3)
    TRAP_DISARM
    mv      s1, t3
    LWUX    s2, 0(s3)
    CHKI    str_sc_alias_rd_rs1_rd, 0, s1
    TEST_BEGIN str_sc_alias_rd_rs1_mem
    CHKI    str_sc_alias_rd_rs1_mem, 0x600df00d, s2
    TRAP_FAILS .Llrsc_trap_sc_rd_rs1, str_sc_alias_rd_rs1_rd, str_sc_alias_rd_rs1_mem

    /* --- SC rs1==rs2 through the XLEN-wide pair: stores its own
     *     address --- */
    TEST_BEGIN str_sc_alias_rs1_rs2_rd
    jal     ra, lrsc_fill
    la      t3, lrsc_buf + 8
    mv      s3, t3
    TRAP_ARM .Llrsc_trap_rs1_rs2
    .if XLEN == 64
    lr.d    t2, (t3)
    sc.d    t2, t3, (t3)
    .else
    lr.w    t2, (t3)
    sc.w    t2, t3, (t3)
    .endif
    TRAP_DISARM
    mv      s1, t2
    REG_L   s2, 0(s3)
    CHKI    str_sc_alias_rs1_rs2_rd, 0, s1
    TEST_BEGIN str_sc_alias_rs1_rs2_mem
    CHKR    str_sc_alias_rs1_rs2_mem, s3, s2
    TRAP_FAILS .Llrsc_trap_rs1_rs2, str_sc_alias_rs1_rs2_rd, str_sc_alias_rs1_rs2_mem

    /* --- SC rd==rs1==rs2 --- */
    TEST_BEGIN str_sc_alias_all_same_rd
    jal     ra, lrsc_fill
    la      t3, lrsc_buf + 8
    mv      s3, t3
    TRAP_ARM .Llrsc_trap_all_same
    .if XLEN == 64
    lr.d    t2, (t3)
    sc.d    t3, t3, (t3)
    .else
    lr.w    t2, (t3)
    sc.w    t3, t3, (t3)
    .endif
    TRAP_DISARM
    mv      s1, t3
    REG_L   s2, 0(s3)
    CHKI    str_sc_alias_all_same_rd, 0, s1
    TEST_BEGIN str_sc_alias_all_same_mem
    CHKR    str_sc_alias_all_same_mem, s3, s2
    TRAP_FAILS .Llrsc_trap_all_same, str_sc_alias_all_same_rd, str_sc_alias_all_same_mem

    /* --- rs1=sp: an address register the compressed ISA treats
     *     specially; LR/SC must use it like any other --- */
    TEST_BEGIN str_lrsc_sp_lr
    addi    sp, sp, -16
    LIX     t4, 0x777
    sw      t4, 0(sp)
    LIX     t5, 0x888
    TRAP_ARM .Llrsc_trap_sp
    lr.w    t2, (sp)
    sc.w    s2, t5, (sp)
    TRAP_DISARM
    mv      s1, t2
    LWUX    s4, 0(sp)
    addi    sp, sp, 16
    CHKI    str_lrsc_sp_lr, 0x777, s1
    TEST_BEGIN str_lrsc_sp_sc
    CHKI    str_lrsc_sp_sc, 0, s2
    TEST_BEGIN str_lrsc_sp_mem
    CHKI    str_lrsc_sp_mem, 0x888, s4
    j       .Llrsc_sp_done
.Llrsc_trap_sp:                     /* trapped with sp still lowered */
    addi    sp, sp, 16
    TRAP_REPORT str_lrsc_sp_lr
    TRAP_REPORT str_lrsc_sp_sc
    TRAP_REPORT str_lrsc_sp_mem
.Llrsc_sp_done:

    /* --- sources unmodified --- */
    TEST_BEGIN str_lrsc_rs1_preserved
    jal     ra, lrsc_fill
    la      t3, lrsc_buf + 8
    LIXT    t4, 0x0fedcba987654321
    mv      s1, t3
    mv      s2, t4
    TRAP_ARM .Llrsc_trap_preserved
    lr.w    t2, (t3)
    sc.w    t5, t4, (t3)
    TRAP_DISARM
    mv      s4, t3
    mv      s5, t4
    CHKR    str_lrsc_rs1_preserved, s1, s4
    TEST_BEGIN str_sc_rs2_preserved
    CHKR    str_sc_rs2_preserved, s2, s5
    TRAP_FAILS .Llrsc_trap_preserved, str_lrsc_rs1_preserved, str_sc_rs2_preserved

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  aq/rl ordering bits: each form of one paired with the plain other
 * ======================================================================= */
test_lrsc_order:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    T_LRSC_VAL lr.w.aq,   sc.w, 4, 0, 0x80000001, 0x7ffffffe, 0xffffffff80000001, 0x7ffffffe, str_lr_w_aq_lr, str_lr_w_aq_sc, str_lr_w_aq_mem
    T_LRSC_VAL lr.w.rl,   sc.w, 4, 0, 0x80000001, 0x7ffffffe, 0xffffffff80000001, 0x7ffffffe, str_lr_w_rl_lr, str_lr_w_rl_sc, str_lr_w_rl_mem
    T_LRSC_VAL lr.w.aqrl, sc.w, 4, 0, 0x80000001, 0x7ffffffe, 0xffffffff80000001, 0x7ffffffe, str_lr_w_aqrl_lr, str_lr_w_aqrl_sc, str_lr_w_aqrl_mem
    T_LRSC_VAL lr.w, sc.w.aq,   4, 0, 0x80000001, 0x7ffffffe, 0xffffffff80000001, 0x7ffffffe, str_sc_w_aq_lr, str_sc_w_aq_sc, str_sc_w_aq_mem
    T_LRSC_VAL lr.w, sc.w.rl,   4, 0, 0x80000001, 0x7ffffffe, 0xffffffff80000001, 0x7ffffffe, str_sc_w_rl_lr, str_sc_w_rl_sc, str_sc_w_rl_mem
    T_LRSC_VAL lr.w, sc.w.aqrl, 4, 0, 0x80000001, 0x7ffffffe, 0xffffffff80000001, 0x7ffffffe, str_sc_w_aqrl_lr, str_sc_w_aqrl_sc, str_sc_w_aqrl_mem

    .if XLEN == 64
    T_LRSC_VAL lr.d.aq,   sc.d, 8, 0, 0x8000000000000001, 0x7ffffffffffffffe, 0x8000000000000001, 0x7ffffffffffffffe, str_lr_d_aq_lr, str_lr_d_aq_sc, str_lr_d_aq_mem
    T_LRSC_VAL lr.d.rl,   sc.d, 8, 0, 0x8000000000000001, 0x7ffffffffffffffe, 0x8000000000000001, 0x7ffffffffffffffe, str_lr_d_rl_lr, str_lr_d_rl_sc, str_lr_d_rl_mem
    T_LRSC_VAL lr.d.aqrl, sc.d, 8, 0, 0x8000000000000001, 0x7ffffffffffffffe, 0x8000000000000001, 0x7ffffffffffffffe, str_lr_d_aqrl_lr, str_lr_d_aqrl_sc, str_lr_d_aqrl_mem
    T_LRSC_VAL lr.d, sc.d.aq,   8, 0, 0x8000000000000001, 0x7ffffffffffffffe, 0x8000000000000001, 0x7ffffffffffffffe, str_sc_d_aq_lr, str_sc_d_aq_sc, str_sc_d_aq_mem
    T_LRSC_VAL lr.d, sc.d.rl,   8, 0, 0x8000000000000001, 0x7ffffffffffffffe, 0x8000000000000001, 0x7ffffffffffffffe, str_sc_d_rl_lr, str_sc_d_rl_sc, str_sc_d_rl_mem
    T_LRSC_VAL lr.d, sc.d.aqrl, 8, 0, 0x8000000000000001, 0x7ffffffffffffffe, 0x8000000000000001, 0x7ffffffffffffffe, str_sc_d_aqrl_lr, str_sc_d_aqrl_sc, str_sc_d_aqrl_mem
    .endif

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* Bit independence across fields -- see the file header, BX_C_LR,
 * BX_C_SC and bitx.inc. The aq/rl field is the 2-bit "immediate"
 * (0x1 = rl, 0x2 = aq), background 0; LR's register fields are rd
 * (background t2) and rs1 (t3). Pool: va = SC's rs2, vb = the old
 * memory value, with bit 31 set so LR.W's sign extension is exercised;
 * on RV64 the SC.W rs2 also carries garbage above bit 31. */
bitx_a_lrsc:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    BX_POOL 0xdeadbeef12345678, 0x3c3c3c3cc3b4a596
    BX_E_RRI5  BX_C_LR, "lr.w, sc.w, 4, LR.W", 7, 28, "0x1,0x2", 0
    BX_E_RRRI5 BX_C_SC, "sc.w, lr.w, 4, SC.W", "0x1,0x2", 0

    .if XLEN == 64
    BX_POOL 0x0fedcba987654321, 0x8123456789abcdef
    BX_E_RRI5  BX_C_LR, "lr.d, sc.d, 8, LR.D", 7, 28, "0x1,0x2", 0
    BX_E_RRRI5 BX_C_SC, "sc.d, lr.d, 8, SC.D", "0x1,0x2", 0
    .endif

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  Strings
 * ======================================================================= */
    .section .rodata
str_lrsc_w_basic_lr:  .asciz "LR.W/SC.W pair: LR rd = value"
str_lrsc_w_basic_sc:  .asciz "LR.W/SC.W pair: SC rd = 0 (success)"
str_lrsc_w_basic_mem: .asciz "LR.W/SC.W pair: SC stored rs2"
str_lrsc_w_sext_lr:   .asciz "LR.W sign-extends bit 31 (high word of doubleword)"
str_lrsc_w_sext_sc:   .asciz "SC.W high word of doubleword: rd = 0"
str_lrsc_w_sext_mem:  .asciz "SC.W high word of doubleword: memory"
str_lrsc_w_zero_lr:   .asciz "LR.W all-ones word"
str_lrsc_w_zero_sc:   .asciz "SC.W storing zero: rd = 0"
str_lrsc_w_zero_mem:  .asciz "SC.W storing zero: memory"
    .if XLEN == 64
str_lrsc_w_upper_lr:  .asciz "LR.W/SC.W, rs2 upper half garbage: LR rd"
str_lrsc_w_upper_sc:  .asciz "SC.W rs2 upper half garbage: rd = 0"
str_lrsc_w_upper_mem: .asciz "SC.W stores only rs2[31:0]"
    .endif
str_lr_w_neigh_0:     .asciz "LR.W low word: target and neighbours unchanged"
str_lr_w_neigh_4:     .asciz "LR.W high word: target and neighbours unchanged"
str_sc_w_neigh_0:     .asciz "SC.W low word: neighbouring words untouched"
str_sc_w_neigh_4:     .asciz "SC.W high word: neighbouring words untouched"
    .if XLEN == 64
str_lrsc_d_basic_lr:  .asciz "LR.D/SC.D pair: LR rd = value"
str_lrsc_d_basic_sc:  .asciz "LR.D/SC.D pair: SC rd = 0 (success)"
str_lrsc_d_basic_mem: .asciz "LR.D/SC.D pair: SC stored rs2"
str_lrsc_d_bit31_lr:  .asciz "LR.D does not sign-extend from bit 31"
str_lrsc_d_bit31_sc:  .asciz "SC.D bit 63 set: rd = 0"
str_lrsc_d_bit31_mem: .asciz "SC.D bit 63 set: memory"
str_lr_d_neigh:       .asciz "LR.D: target and neighbours unchanged"
str_sc_d_neigh:       .asciz "SC.D: neighbouring words untouched"
    .endif

str_sc_twice_first:     .asciz "LR.W then two SC.W: first succeeds"
str_sc_twice_second:    .asciz "LR.W then two SC.W: second fails (reservation consumed)"
str_sc_twice_mem:       .asciz "LR.W then two SC.W: only the first stored"
str_sc_far_fails:       .asciz "SC.W outside the reservation fails"
str_sc_far_mem:         .asciz "SC.W outside the reservation stores nothing"
str_sc_after_fail:      .asciz "SC.W after a failed SC.W fails (reservation invalidated)"
str_sc_after_fail_mem:  .asciz "SC.W after a failed SC.W stores nothing"
str_sc_old_resv:        .asciz "SC.W to an earlier LR's address fails after a later LR"
str_sc_old_resv_mem:    .asciz "SC.W to an earlier LR's address stores nothing"
str_sc_new_resv:        .asciz "SC.W to the most recent LR's address succeeds"
str_sc_new_resv_mem:    .asciz "SC.W to the most recent LR's address stores"
str_sc_rd_x0_mem:       .asciz "SC.W rd=x0: stores on success, not once reservation is gone"
str_sc_rd_x0_zero:      .asciz "SC.W rd=x0: x0 still reads 0"
str_lrsc_loop:          .asciz "LR.W/SC.W retry loop: atomic increment x3"

str_lr_rd_ra:   .asciz "LR.W rd=ra(x1)"
str_lr_rd_t0:   .asciz "LR.W rd=t0(x5)"
str_lr_rd_s0:   .asciz "LR.W rd=s0(x8)"
str_lr_rd_a0:   .asciz "LR.W rd=a0(x10)"
str_lr_rd_s10:  .asciz "LR.W rd=s10(x26)"
str_lr_rd_t6:   .asciz "LR.W rd=t6(x31)"
str_lr_rs1_ra:  .asciz "LR.W rs1=ra(x1)"
str_lr_rs1_t0:  .asciz "LR.W rs1=t0(x5)"
str_lr_rs1_s0:  .asciz "LR.W rs1=s0(x8)"
str_lr_rs1_a0:  .asciz "LR.W rs1=a0(x10)"
str_lr_rs1_s10: .asciz "LR.W rs1=s10(x26)"
str_lr_rs1_t6:  .asciz "LR.W rs1=t6(x31)"
str_sc_rd_ra:   .asciz "SC.W rd=ra(x1)"
str_sc_rd_t0:   .asciz "SC.W rd=t0(x5)"
str_sc_rd_s0:   .asciz "SC.W rd=s0(x8)"
str_sc_rd_a0:   .asciz "SC.W rd=a0(x10)"
str_sc_rd_s10:  .asciz "SC.W rd=s10(x26)"
str_sc_rd_t6:   .asciz "SC.W rd=t6(x31)"
str_sc_rs1_ra:  .asciz "SC.W rs1=ra(x1)"
str_sc_rs1_t0:  .asciz "SC.W rs1=t0(x5)"
str_sc_rs1_s0:  .asciz "SC.W rs1=s0(x8)"
str_sc_rs1_a0:  .asciz "SC.W rs1=a0(x10)"
str_sc_rs1_s10: .asciz "SC.W rs1=s10(x26)"
str_sc_rs1_t6:  .asciz "SC.W rs1=t6(x31)"
str_sc_rs2_ra:  .asciz "SC.W rs2=ra(x1)"
str_sc_rs2_t0:  .asciz "SC.W rs2=t0(x5)"
str_sc_rs2_s0:  .asciz "SC.W rs2=s0(x8)"
str_sc_rs2_a0:  .asciz "SC.W rs2=a0(x10)"
str_sc_rs2_s10: .asciz "SC.W rs2=s10(x26)"
str_sc_rs2_t6:  .asciz "SC.W rs2=t6(x31)"

str_lr_alias_rd_rs1:      .asciz "LR.W rd==rs1: rd = value"
str_lr_alias_rd_rs1_sc:   .asciz "LR.W rd==rs1: reservation on the address (SC succeeds)"
str_sc_alias_rd_rs2_rd:   .asciz "SC.W rd==rs2: rd = 0"
str_sc_alias_rd_rs2_mem:  .asciz "SC.W rd==rs2: stored the old rs2"
str_sc_alias_rd_rs1_rd:   .asciz "SC.W rd==rs1: rd = 0"
str_sc_alias_rd_rs1_mem:  .asciz "SC.W rd==rs1: stored at the old rs1"
    .if XLEN == 64
str_sc_alias_rs1_rs2_rd:   .asciz "SC.D rs1==rs2: rd = 0"
str_sc_alias_rs1_rs2_mem:  .asciz "SC.D rs1==rs2: stores its own address"
str_sc_alias_all_same_rd:  .asciz "SC.D rd==rs1==rs2: rd = 0"
str_sc_alias_all_same_mem: .asciz "SC.D rd==rs1==rs2: stores its own address"
    .else
str_sc_alias_rs1_rs2_rd:   .asciz "SC.W rs1==rs2: rd = 0"
str_sc_alias_rs1_rs2_mem:  .asciz "SC.W rs1==rs2: stores its own address"
str_sc_alias_all_same_rd:  .asciz "SC.W rd==rs1==rs2: rd = 0"
str_sc_alias_all_same_mem: .asciz "SC.W rd==rs1==rs2: stores its own address"
    .endif
str_lrsc_sp_lr:           .asciz "LR.W rs1=sp(x2): rd = value"
str_lrsc_sp_sc:           .asciz "SC.W rs1=sp(x2): rd = 0"
str_lrsc_sp_mem:          .asciz "SC.W rs1=sp(x2): memory"
str_lrsc_rs1_preserved:   .asciz "LR.W/SC.W rs1 unmodified"
str_sc_rs2_preserved:     .asciz "SC.W rs2 unmodified"

str_lr_w_aq_lr:     .asciz "LR.W.AQ ordering bits set: rd = value"
str_lr_w_aq_sc:     .asciz "LR.W.AQ ordering bits set: SC rd = 0"
str_lr_w_aq_mem:    .asciz "LR.W.AQ ordering bits set: memory"
str_lr_w_rl_lr:     .asciz "LR.W.RL ordering bits set: rd = value"
str_lr_w_rl_sc:     .asciz "LR.W.RL ordering bits set: SC rd = 0"
str_lr_w_rl_mem:    .asciz "LR.W.RL ordering bits set: memory"
str_lr_w_aqrl_lr:   .asciz "LR.W.AQRL ordering bits set: rd = value"
str_lr_w_aqrl_sc:   .asciz "LR.W.AQRL ordering bits set: SC rd = 0"
str_lr_w_aqrl_mem:  .asciz "LR.W.AQRL ordering bits set: memory"
str_sc_w_aq_lr:     .asciz "SC.W.AQ ordering bits set: LR rd = value"
str_sc_w_aq_sc:     .asciz "SC.W.AQ ordering bits set: rd = 0"
str_sc_w_aq_mem:    .asciz "SC.W.AQ ordering bits set: memory"
str_sc_w_rl_lr:     .asciz "SC.W.RL ordering bits set: LR rd = value"
str_sc_w_rl_sc:     .asciz "SC.W.RL ordering bits set: rd = 0"
str_sc_w_rl_mem:    .asciz "SC.W.RL ordering bits set: memory"
str_sc_w_aqrl_lr:   .asciz "SC.W.AQRL ordering bits set: LR rd = value"
str_sc_w_aqrl_sc:   .asciz "SC.W.AQRL ordering bits set: rd = 0"
str_sc_w_aqrl_mem:  .asciz "SC.W.AQRL ordering bits set: memory"
    .if XLEN == 64
str_lr_d_aq_lr:     .asciz "LR.D.AQ ordering bits set: rd = value"
str_lr_d_aq_sc:     .asciz "LR.D.AQ ordering bits set: SC rd = 0"
str_lr_d_aq_mem:    .asciz "LR.D.AQ ordering bits set: memory"
str_lr_d_rl_lr:     .asciz "LR.D.RL ordering bits set: rd = value"
str_lr_d_rl_sc:     .asciz "LR.D.RL ordering bits set: SC rd = 0"
str_lr_d_rl_mem:    .asciz "LR.D.RL ordering bits set: memory"
str_lr_d_aqrl_lr:   .asciz "LR.D.AQRL ordering bits set: rd = value"
str_lr_d_aqrl_sc:   .asciz "LR.D.AQRL ordering bits set: SC rd = 0"
str_lr_d_aqrl_mem:  .asciz "LR.D.AQRL ordering bits set: memory"
str_sc_d_aq_lr:     .asciz "SC.D.AQ ordering bits set: LR rd = value"
str_sc_d_aq_sc:     .asciz "SC.D.AQ ordering bits set: rd = 0"
str_sc_d_aq_mem:    .asciz "SC.D.AQ ordering bits set: memory"
str_sc_d_rl_lr:     .asciz "SC.D.RL ordering bits set: LR rd = value"
str_sc_d_rl_sc:     .asciz "SC.D.RL ordering bits set: rd = 0"
str_sc_d_rl_mem:    .asciz "SC.D.RL ordering bits set: memory"
str_sc_d_aqrl_lr:   .asciz "SC.D.AQRL ordering bits set: LR rd = value"
str_sc_d_aqrl_sc:   .asciz "SC.D.AQRL ordering bits set: rd = 0"
str_sc_d_aqrl_mem:  .asciz "SC.D.AQRL ordering bits set: memory"
    .endif

/* =======================================================================
 *  Scratch memory
 * ======================================================================= */
    .section .bss
    .balign 8
lrsc_buf:    .skip 24
    .skip   4096 - 24               /* lrsc_far = lrsc_buf + 4096 */
lrsc_far:    .skip 24
bx_lrsc_ref: .skip 8
bx_lrsc_dut: .skip 8
