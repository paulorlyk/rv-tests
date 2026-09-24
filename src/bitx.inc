/* =====================================================================
 * bitx.inc  --  shared machinery for the bit-independence-across-fields
 *               tests ("bitx" for short), .include'd by every category
 *               file that has them. Macros and .equ constants only: it
 *               defines no symbols of its own, so each including file
 *               still exposes exactly one entry point. The one piece of
 *               shared *state* -- the runtime-built counting sled the
 *               control-flow tests land in -- lives in bitx.S.
 *
 * WHAT IS BEING TESTED
 *
 * The per-field sweeps in each file vary one field of the encoding
 * (rd, rs1, rs2, the immediate) while holding the others fixed. That
 * catches a fault confined to one field, but not a decoder fault where
 * one bit misbehaves only when some *other* bit is set as well -- a
 * bit of rs1 leaking into the logic that selects rd, an immediate bit
 * coupled to a funct bit, and so on. C.ADDI4SPN (c/quadrant0.S) was
 * the first instruction to get the defence: a register x immediate
 * cross-product plus every within-field pair of immediate bits. This
 * file generalises it to every instruction, one bit *pair* at a time:
 *
 *   for every pair of bits (p, q) among ALL the instruction's variable
 *   fields -- both bits in the same field, or in two different fields
 *   -- there is one case in which exactly p and q are set in those
 *   fields, and every field not involved holds a fixed "background".
 *
 * That is C(N,2) cases per instruction for N variable bits: 105 for an
 * R-type (3 x 5 register bits), 231 for an I-type (5+5+12), 136 for an
 * AMO (3 x 5 register bits + aq/rl), and so on.
 * Every instruction is enumerated separately rather than once per
 * encoding format, because a coupling can just as well involve that
 * instruction's own opcode/funct3/funct7 bits.
 *
 * REGISTER FIELDS
 *
 * A 5-bit register field has its bits set by the register *number*:
 * the single-bit candidates are x1, x2, x4, x8, x16 and the two-bit ones
 * are x3, x5, x6, x9, x10, x12, x17, x18, x20, x24. That list takes in
 * sp (x2), gp (x3) and tp (x4). They are deliberately not skipped --
 * their encodings are as likely to be miswired as any other -- so every
 * case saves all three first (BX_ENTER) and puts them back before
 * anything else touches memory or the harness (BX_LEAVE). A 3-bit
 * compressed field (rd'/rs1'/rs2', x8+r') uses x9, x10, x12 and x11,
 * x13, x14, with background x8 (r' = 0, i.e. no bits set).
 *
 * The background for a 5-bit field can't be "no bits set" (x0 would
 * discard the result, or feed a zero operand that hides a misdecode),
 * so it's the register the existing T_*_VAL macros already use for that
 * field: rd = t2 (x7), rs1 = t3 (x28), rs2 = t4 (x29). An immediate's
 * background is 0 unless the encoding forbids it, in which case the
 * including file says what it uses instead.
 *
 * RESERVED REGISTERS -- never a candidate, never a background other
 * than as listed above (bug class 1 in CLAUDE.md: a fixed helper must
 * be disjoint from every swept list; none of these has fewer than
 * three bits set, and every candidate has at most two):
 *
 *   t2 x7 / t3 x28 / t4 x29   backgrounds, and the reference encoding
 *   t5 x30   expected value       t6 x31   actual value
 *   s3 x19   scratch / jump target
 *   s5 x21   sled counter         s6 x22   sled return address
 *   s7 x23   value-pool pointer (BX_POOL)
 *   s9 x25 / s10 x26 / s11 x27   tp / gp / sp saved by BX_ENTER
 *
 * check() preserves s0-s11, so the pool pointer survives from case to
 * case.
 *
 * EXPECTED VALUES
 *
 * Where no immediate is involved, the expected value comes from the
 * *same* instruction run through the background encoding (rd=t2, rs1=t3,
 * rs2=t4). That exact encoding is already checked against literal
 * values by the file's own T_*_VAL tests, so it is a trustworthy
 * reference, and it lets one case macro cover MULH, DIVU etc. without
 * re-deriving 128-bit products. Where an immediate IS involved, the
 * reference must not contain the same immediate bits (a coupling
 * between two immediate bits would corrupt both runs identically), so
 * the expected value is either an assemble-time constant or the
 * register-register equivalent with the immediate loaded from the
 * constant pool (e.g. ADDI checked against ADD).
 *
 * Constants are loaded with BX_LDC / the BX_POOL pointer -- plain
 * pc-relative ld under .option norelax -- rather than li, both because
 * li would materialise the constant with LUI/ADDI (whose immediates
 * could share the bits under test) and because nothing here may become
 * gp-relative while gp is being swept as an operand.
 *
 * Case names are generated, e.g. "ADD bitx rd=x3 rs1=x28 rs2=x29" --
 * the string lives next to its case (BX_REPORT), so there is no separate
 * string table to keep consistent.
 *
 * BOTH WIDTHS. Everything here is XLEN-generic (xlen.inc): pool slots,
 * constants and the store read-back are register-sized, and BX_LDC
 * truncates assemble-time constants to XLEN bits -- correct for the
 * truncation-safe ops (add, sub, logic, left shifts); anything else
 * must be written in terms of XLEN (see BX_C_CI in c/quadrant1.S).
 * The counting sled, register candidates and backgrounds are the same
 * on RV32; shift-amount lists shrink to 5 bits there.
 * ===================================================================== */

    .equ BX_SENTINEL, 0x5a5aa5a5c3c33c3c   /* pre-loaded into rd so a
                                             * write that goes astray
                                             * can't pass by leaving an
                                             * equal stale value */

/* ---- counting sled layout (the sled itself is built by bitx.S) ------
 *
 *   bx_region + BX_SITE_F   4-byte site; forward transfers start here
 *               BX_SLED     BX_SLOTS x "c.addi s5, 1"
 *               BX_EXIT     jalr x0, 0(s6)
 *               BX_SITE_B   4-byte site; backward transfers start here
 *               BX_NT       addi s5, x0, -1 ; jalr x0, 0(s6)
 *
 * Landing anywhere at or after the sled start executes one increment
 * per remaining 2-byte slot, so s5 = (BX_EXIT - landing) / 2 identifies
 * the exact landing address. A backward site that falls through (not
 * taken) reaches BX_NT and returns s5 = -1. BX_SLOTS is sized for JAL's
 * full +-1 MiB reach in both directions. */
    .equ BX_SLOTS,  0x80000
    .equ BX_SITE_F, 0
    .equ BX_SLED,   4
    .equ BX_EXIT,   BX_SLED + 2 * BX_SLOTS
    .equ BX_SITE_B, BX_EXIT + 4
    .equ BX_NT,     BX_SITE_B + 4
    .equ BX_REGION_SIZE, BX_NT + 8

/* =======================================================================
 *  Per-case plumbing
 * ======================================================================= */

/* BX_ENTER also announces the case (test_begin) before anything is
 * swept: by default 94f, the name string the case's first BX_REPORT
 * defines, so the case macros don't have to pass their name twice; a
 * case that names its strings up front (BX_NAME, for BX_TRAP_FAILS)
 * passes that label instead. The call clobbers a0 and ra, which no
 * case holds across its BX_ENTER. */
.macro BX_ENTER name=94f
    .option push
    .option norvc
    .option norelax
    la      a0, \name
    call    test_begin
    .option pop
    mv      s11, sp
    mv      s10, gp
    mv      s9, tp
.endm

.macro BX_LEAVE
    mv      sp, s11
    mv      gp, s10
    mv      tp, s9
.endm

/* BX_LDC reg, value -- load a register-sized constant from a private
 * pool slot. On RV32 the value is truncated to its low 32 bits, which is
 * exactly right for the expected values computed here as long as each
 * expression is one whose low 32 bits don't depend on the high ones
 * (add, sub, logic ops, left shifts); right shifts and compares must be
 * written in terms of XLEN (see c/quadrant1.S's BX_C_CI). */
.macro BX_LDC reg, val
    .pushsection .rodata
    .balign 8
99: REG_DATA \val
    .popsection
    .option push
    .option norelax
    REG_L   \reg, 99b
    .option pop
.endm

/* BX_POOL va, vb -- point s7 at { va, vb, BX_SENTINEL } (register-sized,
 * so truncated to 32 bits on RV32); case macros read them with
 * BX_PV reg, 0 / 1 / 2. */
.macro BX_POOL va, vb
    .pushsection .rodata
    .balign 8
98: REG_DATA \va
    REG_DATA \vb
    REG_DATA BX_SENTINEL
    .popsection
    .option push
    .option norelax
    la      s7, 98b
    .option pop
.endm

.macro BX_PV reg, idx
    REG_L   \reg, ((\idx) * REG_BYTES)(s7)
.endm

/* BX_REPORT text -- restore sp/gp/tp, then check(text, t5, t6). With
 * thousands of generated cases the image outgrows JAL's +-1 MiB reach,
 * so check is reached with "call" (AUIPC + JALR) rather than jal. */
.macro BX_REPORT text
    BX_LEAVE
    .pushsection .rodata
94: .asciz  "\text"
    .popsection
    la      a0, 94b
    mv      a1, t5
    mv      a2, t6
    call    check
.endm

/* BX_NAME label, text -- define a case's name string at label (in
 * .rodata) ahead of use; BX_REPORT_AT label is BX_REPORT for such a
 * name. Cases whose instruction under test may trap name their
 * strings this way, because their resume path (BX_TRAP_FAILS) has to
 * report every one of them, and a numeric 94 label can only reach the
 * nearest. */
.macro BX_NAME label, text
    .pushsection .rodata
\label: .asciz "\text"
    .popsection
.endm

.macro BX_REPORT_AT label
    BX_LEAVE
    la      a0, \label
    mv      a1, t5
    mv      a2, t6
    call    check
.endm

/* BX_TRAP_FAILS resume, label... -- TRAP_FAILS (harness.inc) for a
 * bitx case: the resume path first puts sp/gp/tp back (BX_LEAVE: the
 * trap may have come while they were swept; the handler restores
 * nothing but its own scratch registers), then reports each name with
 * check_trap. The case arms with TRAP_ARM resume after BX_ENTER,
 * before any register is swept, and disarms with TRAP_DISARM_R once
 * the instruction under test has run. */
.macro BX_TRAP_FAILS resume, names:vararg
    .option push
    .option norvc
    j       .Lbx_trap_fails_done\@
\resume:
    BX_LEAVE
    .irp    n, \names
    TRAP_REPORT \n
    .endr
.Lbx_trap_fails_done\@:
    .option pop
.endm

/* =======================================================================
 *  Pair enumerators
 *
 *  Each walks every bit pair of its fields and invokes
 *      \case \pass, <field values...>
 *  where \pass is whatever fixed arguments the case macro needs first
 *  (typically "insn, NAME"). A register field is given as three lists:
 *  its single-bit candidates, its two-bit candidates and its
 *  background. An immediate field is given as the list of its
 *  single-bit values (in ascending order) and its background; pairs
 *  are passed as the expression (a|b), so the case macro receives the
 *  raw unsigned field value and does its own sign extension.
 * ======================================================================= */

/* One immediate field alone: C(n,2) cases. */
.macro BX_E_I case, pass, ione
    .irp ia, \ione
    .irp ib, \ione
    .if (\ib) > (\ia)
    \case \pass, (\ia|\ib)
    .endif
    .endr
    .endr
.endm

/* One register field alone: its two-bit candidates. */
.macro BX_E_R case, pass, two
    .irp r, \two
    \case \pass, \r
    .endr
.endm

/* Two register fields. */
.macro BX_E_RR case, pass, one1, two1, bg1, one2, two2, bg2
    .irp r, \two1
    \case \pass, \r, \bg2
    .endr
    .irp r, \two2
    \case \pass, \bg1, \r
    .endr
    .irp ra_, \one1
    .irp rb_, \one2
    \case \pass, \ra_, \rb_
    .endr
    .endr
.endm

/* A register field and an immediate field. */
.macro BX_E_RI case, pass, one1, two1, bg1, ione, ibg
    .irp r, \two1
    \case \pass, \r, \ibg
    .endr
    BX_E_I \case, "\pass, \bg1", "\ione"
    .irp r, \one1
    .irp ib, \ione
    \case \pass, \r, \ib
    .endr
    .endr
.endm

/* Three register fields. */
.macro BX_E_RRR case, pass, one1, two1, bg1, one2, two2, bg2, one3, two3, bg3
    .irp r, \two1
    \case \pass, \r, \bg2, \bg3
    .endr
    .irp r, \two2
    \case \pass, \bg1, \r, \bg3
    .endr
    .irp r, \two3
    \case \pass, \bg1, \bg2, \r
    .endr
    .irp ra_, \one1
    .irp rb_, \one2
    \case \pass, \ra_, \rb_, \bg3
    .endr
    .endr
    .irp ra_, \one1
    .irp rb_, \one3
    \case \pass, \ra_, \bg2, \rb_
    .endr
    .endr
    .irp ra_, \one2
    .irp rb_, \one3
    \case \pass, \bg1, \ra_, \rb_
    .endr
    .endr
.endm

/* Two register fields and an immediate field. */
.macro BX_E_RRI case, pass, one1, two1, bg1, one2, two2, bg2, ione, ibg
    .irp r, \two1
    \case \pass, \r, \bg2, \ibg
    .endr
    .irp r, \two2
    \case \pass, \bg1, \r, \ibg
    .endr
    BX_E_I \case, "\pass, \bg1, \bg2", "\ione"
    .irp ra_, \one1
    .irp rb_, \one2
    \case \pass, \ra_, \rb_, \ibg
    .endr
    .endr
    .irp ra_, \one1
    .irp ib, \ione
    \case \pass, \ra_, \bg2, \ib
    .endr
    .endr
    .irp ra_, \one2
    .irp ib, \ione
    \case \pass, \bg1, \ra_, \ib
    .endr
    .endr
.endm

/* Three register fields and an immediate field (the AMOs: rd, rs1, rs2
 * and the 2-bit aq/rl ordering field). */
.macro BX_E_RRRI case, pass, one1, two1, bg1, one2, two2, bg2, one3, two3, bg3, ione, ibg
    .irp r, \two1
    \case \pass, \r, \bg2, \bg3, \ibg
    .endr
    .irp r, \two2
    \case \pass, \bg1, \r, \bg3, \ibg
    .endr
    .irp r, \two3
    \case \pass, \bg1, \bg2, \r, \ibg
    .endr
    .irp ra_, \one1
    .irp rb_, \one2
    \case \pass, \ra_, \rb_, \bg3, \ibg
    .endr
    .endr
    .irp ra_, \one1
    .irp rb_, \one3
    \case \pass, \ra_, \bg2, \rb_, \ibg
    .endr
    .endr
    .irp ra_, \one2
    .irp rb_, \one3
    \case \pass, \bg1, \ra_, \rb_, \ibg
    .endr
    .endr
    BX_E_I \case, "\pass, \bg1, \bg2, \bg3", "\ione"
    .irp ra_, \one1
    .irp ib, \ione
    \case \pass, \ra_, \bg2, \bg3, \ib
    .endr
    .endr
    .irp ra_, \one2
    .irp ib, \ione
    \case \pass, \bg1, \ra_, \bg3, \ib
    .endr
    .endr
    .irp ra_, \one3
    .irp ib, \ione
    \case \pass, \bg1, \bg2, \ra_, \ib
    .endr
    .endr
.endm

/* Shorthands that fill in the register candidate lists (see the file
 * header): "5" = a full 5-bit field, "3" = a compressed x8-x15 field
 * with background x8. The files are fed straight to "as" (no C
 * preprocessor), so the lists are spelled out here rather than
 * #defined. */
.macro BX_E_R5 case, pass
    BX_E_R \case, "\pass", "3,5,6,9,10,12,17,18,20,24"
.endm

.macro BX_E_RR5 case, pass, bg1, bg2
    BX_E_RR \case, "\pass", "1,2,4,8,16", "3,5,6,9,10,12,17,18,20,24", \bg1, "1,2,4,8,16", "3,5,6,9,10,12,17,18,20,24", \bg2
.endm

.macro BX_E_RR3 case, pass
    BX_E_RR \case, "\pass", "9,10,12", "11,13,14", 8, "9,10,12", "11,13,14", 8
.endm

.macro BX_E_RI5 case, pass, bg1, ione, ibg
    BX_E_RI \case, "\pass", "1,2,4,8,16", "3,5,6,9,10,12,17,18,20,24", \bg1, "\ione", \ibg
.endm

.macro BX_E_RI3 case, pass, ione, ibg
    BX_E_RI \case, "\pass", "9,10,12", "11,13,14", 8, "\ione", \ibg
.endm

.macro BX_E_RRR5 case, pass
    BX_E_RRR \case, "\pass", "1,2,4,8,16", "3,5,6,9,10,12,17,18,20,24", 7, "1,2,4,8,16", "3,5,6,9,10,12,17,18,20,24", 28, "1,2,4,8,16", "3,5,6,9,10,12,17,18,20,24", 29
.endm

.macro BX_E_RRRI5 case, pass, ione, ibg
    BX_E_RRRI \case, "\pass", "1,2,4,8,16", "3,5,6,9,10,12,17,18,20,24", 7, "1,2,4,8,16", "3,5,6,9,10,12,17,18,20,24", 28, "1,2,4,8,16", "3,5,6,9,10,12,17,18,20,24", 29, "\ione", \ibg
.endm

.macro BX_E_RRI5 case, pass, bg1, bg2, ione, ibg
    BX_E_RRI \case, "\pass", "1,2,4,8,16", "3,5,6,9,10,12,17,18,20,24", \bg1, "1,2,4,8,16", "3,5,6,9,10,12,17,18,20,24", \bg2, "\ione", \ibg
.endm

.macro BX_E_RRI3 case, pass, ione, ibg
    BX_E_RRI \case, "\pass", "9,10,12", "11,13,14", 8, "9,10,12", "11,13,14", 8, "\ione", \ibg
.endm

/* =======================================================================
 *  Shared case macro: R-type (rd, rs1, rs2), for OP and the M extension
 *
 *  Operands come from the BX_POOL values: rs1 = va, rs2 = vb, and rd is
 *  pre-loaded with BX_SENTINEL. Loads go rd, rs1, rs2 in that order, so
 *  when fields alias the later load wins -- rs1 == rs2 means both read
 *  vb -- and the reference (background encoding t2/t3/t4) is fed the
 *  same effective operands.
 * ======================================================================= */
.macro BX_C_RRR insn, nm, rd, rs1, rs2
    BX_ENTER
    .if \rs1 == \rs2
    BX_PV   t3, 1
    .else
    BX_PV   t3, 0
    .endif
    BX_PV   t4, 1
    \insn   t2, t3, t4
    mv      t5, t2
    BX_PV   x\rd, 2
    BX_PV   x\rs1, 0
    BX_PV   x\rs2, 1
    \insn   x\rd, x\rs1, x\rs2
    mv      t6, x\rd
    BX_REPORT "\nm bitx rd=x\rd rs1=x\rs1 rs2=x\rs2"
.endm

/* =======================================================================
 *  Control-transfer plumbing (the sled itself: bitx.S)
 *
 *  A control-transfer case emits the instruction under test into
 *  .rodata at local label 96 (so the assembler encodes it, with its
 *  offset taken relative to 96b), then:
 *    BX_PLANT site, size   copy it to bx_region + site, s3 = that address
 *    BX_GO site            s5 = 0, call the site, t6 = s5 afterwards,
 *                          and put the sled back if the site was in it
 *    BX_COUNT site, d, size, taken
 *                          t5 = the s5 a correct transfer must leave
 *
 *  Where the site goes:
 *   - forward (d > 0): *inside* the sled, at BX_FWD(d) = BX_EXIT - d -
 *     2 * BX_MARGIN, so a correct transfer always counts exactly
 *     BX_MARGIN slots. (A fixed site at the sled's start would make a
 *     short hop execute the whole 1 MiB sled -- about half a million
 *     instructions per case.) Falling through instead counts
 *     (d + 2 * BX_MARGIN - size) / 2, which differs whenever d != size.
 *   - backward (d < 0): BX_SITE_B, just past BX_EXIT; falling through
 *     reaches BX_NT and leaves -1.
 *   - absolute targets (JALR, C.JR, C.JALR): BX_SITE_F, aimed at
 *     BX_TARGET, BX_MARGIN slots before BX_EXIT.
 *  A 2-byte site at BX_SITE_F or BX_SITE_B gets its second halfword
 *  refilled too (a slot, resp. a c.nop, so a fall-through behaves as
 *  described); inside the sled the next halfword is already a slot.
 *  The caller must have called bx_sled_init.
 * ======================================================================= */
    .equ BX_MARGIN, 8
    .equ BX_TARGET, BX_EXIT - 2 * BX_MARGIN

.macro BX_PLANT site, size
    .option push
    .option norelax
    la      t3, 96b
    la      s3, bx_region + (\site)
    .option pop
    lhu     t4, 0(t3)
    sh      t4, 0(s3)
    .if \size == 4
    lhu     t4, 2(t3)
    sh      t4, 2(s3)
    .elseif (\site) == BX_SITE_F
    lhu     t4, bx_tpl_slot
    sh      t4, 2(s3)
    .elseif (\site) == BX_SITE_B
    lhu     t4, bx_tpl_cnop
    sh      t4, 2(s3)
    .endif
    SYNC_I  t4
.endm

.macro BX_GO site
    li      s5, 0
    jalr    s6, 0(s3)
    mv      t6, s5
    .if ((\site) != BX_SITE_F) && ((\site) != BX_SITE_B)
    lhu     t4, bx_tpl_slot
    sh      t4, 0(s3)
    sh      t4, 2(s3)
    SYNC_I  t4
    .endif
.endm

/* d = the transfer's byte offset (taken), size = the site instruction's
 * length. */
.macro BX_COUNT site, d, size, taken
    .if \taken
    BX_LDC  t5, ((BX_EXIT - (\site) - (\d)) / 2)
    .elseif (\site) == BX_SITE_B
    BX_LDC  t5, -1
    .else
    BX_LDC  t5, ((BX_EXIT - (\site) - (\size)) / 2)
    .endif
.endm

/* =======================================================================
 *  Load/store helpers
 * ======================================================================= */

/* BX_PATTERN n -- n bytes of the read-only load pattern: byte i is
 * (i & 0xff) ^ ((i >> 8) * 0x3b & 0xff). Flipping any one of address
 * bits 0-11 changes the byte (0x3b is odd, so the high-nibble term is
 * injective), half the bytes have bit 7 set (so sign extension
 * matters), and no two aligned words or doublewords are equal -- a
 * misdecoded offset or base bit can't read back an equal value. */
.macro BX_PATTERN n
    .set    bx_i, 0
    .rept   \n
    .byte   ((bx_i & 0xff) ^ (((bx_i >> 8) * 0x3b) & 0xff))
    .set    bx_i, bx_i + 1
    .endr
.endm

/* BX_ST_PREP sym, k -- before a store to sym + k: set the
 * register-sized, naturally aligned word holding it to BX_SENTINEL. */
.macro BX_ST_PREP sym, k
    .option push
    .option norelax
    la      t3, \sym + ((\k) - ((\k) & (REG_BYTES - 1)))
    .option pop
    BX_PV   t4, 2
    REG_S   t4, 0(t3)
.endm

/* BX_ST_CHECK sym, k, w, alias, bsym, bk -- after a w-byte store to the
 * w-aligned address sym + k: t6 = the whole register-sized word holding
 * it, t5 = BX_SENTINEL with those w bytes replaced by the stored value --
 * the pool's va, or, when alias is nonzero (the data register was also
 * the base), the base address bsym + bk. So a store that is too wide,
 * lands on the wrong bytes or doesn't happen at all is caught. */
.macro BX_ST_CHECK sym, k, w, alias, bsym, bk
    .option push
    .option norelax
    la      t3, \sym + ((\k) - ((\k) & (REG_BYTES - 1)))
    REG_L   t6, 0(t3)
    .if \alias
    la      t5, \bsym + (\bk)
    .else
    BX_PV   t5, 0
    .endif
    .option pop
    .if \w < REG_BYTES
    slli    t5, t5, XLEN - 8 * \w
    srli    t5, t5, XLEN - 8 * \w - 8 * (((\k) & (REG_BYTES - 1)) - ((\k) & (\w - 1)))
    BX_LDC  t4, (BX_SENTINEL & ~(((1 << (8 * \w)) - 1) << (8 * (((\k) & (REG_BYTES - 1)) - ((\k) & (\w - 1))))))
    or      t5, t5, t4
    .endif
.endm
