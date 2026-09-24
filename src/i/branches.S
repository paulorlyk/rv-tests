/* =====================================================================
 * i/branches.S  --  RV64I base-ISA branches: BEQ, BNE, BLT, BGE,
 *                       BLTU, BGEU
 *
 * Part of the RV64I base-ISA suite; see i/tests.S for how this
 * plugs into the rest (main_tests.S -> i/tests.S -> here), and
 * common.S for the boot/UART/reporting harness everything sits on
 * ("check", "uart_puts" are used from there; nothing else).
 *
 * The six branches share one B-type encoding and differ only in the
 * comparison in funct3. So the coverage here is organised around what
 * actually distinguishes them from each other, rather than repeating
 * an identical offset sweep six times:
 *
 *   - **The comparison truth table.** Every instruction is run against
 *     the same set of operand pairs, with the expected taken/not-taken
 *     outcome for each spelled out explicitly. Running all six through
 *     identical inputs means a decoder that swaps two of them (BLT for
 *     BGE, say, or BLTU for BLT) produces a visible mismatch rather
 *     than something that could quietly pass.
 *   - **Signed vs unsigned is the headline case.** BLT/BGE compare as
 *     signed; BLTU/BGEU compare the same bits as unsigned. The pairs
 *     below deliberately include operands where those two readings
 *     disagree -- e.g. rs1=-1, rs2=1: signed, -1 < 1 so BLT is taken;
 *     unsigned, 0xffff...f > 1 so BLTU is *not*. Same bits, opposite
 *     results. INT64_MIN vs INT64_MAX is the other such pair. These
 *     are the cases that catch a signed/unsigned mixup, which is
 *     exactly the bug class that has bitten this project's own test
 *     code more than once (see the README's note on lw/lwu).
 *   - **Equal operands** are covered for all six, since that's the
 *     boundary where the strict/non-strict distinction shows up
 *     (BLT not taken vs BGE taken on x == x).
 *
 * The 12-bit branch offset is a B-type field scrambled across
 * non-adjacent bits (imm[12|10:5] and imm[4:1|11]), identical in all
 * six instructions -- so it's swept once, through BEQ, rather than six
 * times over. Same scoping rationale as i/jal.S: every bit of the
 * low 12 is covered in both directions; the range extends to ~+-4KB
 * and the construction cost of the top bits isn't worth the binary
 * size. Offsets are built from .rept-generated 4-byte nop fillers and
 * every one was verified by disassembly (target - branch computed
 * directly), not trusted from the .rept count -- see the README's note
 * on assembler relaxation for why that matters at boundaries.
 *
 * Bit independence across fields (bitx_i_branches, at the end):
 * every bit pair among rs1, rs2 and the 12-bit offset set together,
 * C(22,2) = 231 cases per instruction less the 10 noted at BX_C_BR, for
 * all six -- the full +-4 KiB offset range, landing in the counting sled
 * built at run time by bitx.S. See bitx.inc.
 * ===================================================================== */

    .include "xlen.inc"
    .include "harness.inc"

    .option norvc            /* mandatory, not stylistic: BEQ/BNE against
                               * x0 with an x8-x15 register have compressed
                               * forms (C.BEQZ/C.BNEZ) the assembler would
                               * otherwise substitute, silently testing the
                               * RVC instruction instead of this one. */

    .include "bitx.inc"

    .global tests_i_branches

    .section .text

/* BX_C_BR insn, teq, nm, rs1, rs2, v -- one bit-independence case
 * (bitx.inc, bitx.S) for a branch with raw offset field v (bits 12:1,
 * bit 12 the sign). rs1/rs2 get the pool values va/vb, chosen per
 * instruction so the branch is taken; when rs1 == rs2 both read vb and
 * the outcome is teq instead (taken on equal operands, or not). The
 * branch is assembled into .rodata, planted in the counting sled and
 * run, and must land on exactly the right slot -- or, when not taken,
 * fall through.
 *
 * Offset +2 alone (bit 1 crossed with a register bit, 10 cases) is
 * skipped for the same reason as JAL's (i/jal.S): it lands in the
 * branch's own upper half. */
.macro BX_C_BR insn, teq, nm, rs1, rs2, v
    .if ((\v) - (((\v) & 0x1000) << 1)) > 2
    BX_C_BR_ \insn, \teq, \nm, \rs1, \rs2, \v, ((\v) - (((\v) & 0x1000) << 1)), (BX_EXIT - ((\v) - (((\v) & 0x1000) << 1)) - 2 * BX_MARGIN)
    .elseif ((\v) - (((\v) & 0x1000) << 1)) < 0
    BX_C_BR_ \insn, \teq, \nm, \rs1, \rs2, \v, ((\v) - (((\v) & 0x1000) << 1)), BX_SITE_B
    .endif
.endm

.macro BX_C_BR_ insn, teq, nm, rs1, rs2, v, d, site
    BX_ENTER
    .pushsection .rodata
    .balign 4
    .option push
    .option norelax
96: \insn   x\rs1, x\rs2, 96b + (\d)
    .option pop
    .popsection
    BX_PLANT \site, 4
    BX_PV   x\rs1, 0
    BX_PV   x\rs2, 1
    BX_GO   \site
    .if \rs1 == \rs2
    BX_COUNT \site, \d, 4, \teq
    .else
    BX_COUNT \site, \d, 4, 1
    .endif
    BX_REPORT "\nm bitx rs1=x\rs1 rs2=x\rs2 off=\v"
.endm

/* T_BR insn, v1, v2, taken, name
 *   rs1 = v1, rs2 = v2, then branch. If the branch is taken it skips
 *   the marker store, leaving s4 == 0; if not taken it falls through
 *   and sets s4 == 1. So the expected marker is simply (1 - taken),
 *   which lets one macro express both outcomes -- no separate
 *   "taken" and "not taken" variants that could drift apart. */
.macro T_BR insn, v1, v2, taken, name
    TEST_BEGIN \name
    LIX     s4, 0
    LIX     t1, \v1
    LIX     t2, \v2
    \insn   t1, t2, 1f
    LIX     s4, 1                   /* only reached if NOT taken */
1:
    la      a0, \name
    LIX     a1, (1 - \taken)
    mv      a2, s4
    call    check
.endm

/* T_BR_RS1 / T_BR_RS2 -- sweep each register field independently,
 * using BEQ with equal values so the branch is taken. The other
 * operand is fixed at a register deliberately outside the swept list.
 * The swept register is consumed by the branch before a0-a2 are
 * reused, so it may itself be a0/a1/a2. */
.macro T_BR_RS1 reg, name
    TEST_BEGIN \name
    LIX     s4, 0
    LIXT    s3, 0x5a5a5a5a5a5a5a5a
    LIXT    \reg, 0x5a5a5a5a5a5a5a5a
    beq     \reg, s3, 1f
    LIX     s4, 999                 /* poison: only hit if branch failed */
1:
    la      a0, \name
    LIX     a1, 0
    mv      a2, s4
    call    check
.endm

.macro T_BR_RS2 reg, name
    TEST_BEGIN \name
    LIX     s4, 0
    LIXT    s3, 0x5a5a5a5a5a5a5a5a
    LIXT    \reg, 0x5a5a5a5a5a5a5a5a
    beq     s3, \reg, 1f
    LIX     s4, 999
1:
    la      a0, \name
    LIX     a1, 0
    mv      a2, s4
    call    check
.endm

/* T_BR_FWD / T_BR_BWD dist, name -- offset sweep, through BEQ.
 * Forward: beq(4) + poison li(4) + N nop fillers(4N), dist = 8 + 4N.
 * Backward: jump ahead past the filler run first (not under test),
 * then branch back over it. dist = 8 + 4N. */
.macro T_BR_FWD dist, name
    TEST_BEGIN \name
    LIX     s4, 0
    LIX     t1, 7
    LIX     t2, 7
    beq     t1, t2, 1f
    LIX     s4, 999                 /* poison: only hit if branch landed wrong */
    .rept (\dist - 8) / 4
    nop
    .endr
1:
    la      a0, \name
    LIX     a1, 0
    mv      a2, s4
    call    check
.endm

.macro T_BR_BWD dist, name
    TEST_BEGIN \name
    LIX     s4, 0
    LIX     t1, 7
    LIX     t2, 7
    jal     zero, 5f
4:
    LIX     s4, 1                   /* success marker: the true target */
    jal     zero, 6f
5:
    .rept (\dist - 8) / 4
    nop
    .endr
    beq     t1, t2, 4b
    LIX     s4, 99                  /* poison: only hit if branch landed wrong */
6:
    la      a0, \name
    LIX     a1, 1
    mv      a2, s4
    call    check
.endm

tests_i_branches:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    /* ===== comparison truth table: every instruction, same inputs =====
     * Expected outcomes computed from the RISC-V definitions:
     * BEQ/BNE compare bitwise; BLT/BGE signed; BLTU/BGEU unsigned. */

    /* --- equal operands (0 vs 0): the strict/non-strict boundary --- */
    T_BR beq,  0, 0, 1, str_br_eq_beq
    T_BR bne,  0, 0, 0, str_br_eq_bne
    T_BR blt,  0, 0, 0, str_br_eq_blt
    T_BR bge,  0, 0, 1, str_br_eq_bge
    T_BR bltu, 0, 0, 0, str_br_eq_bltu
    T_BR bgeu, 0, 0, 1, str_br_eq_bgeu

    /* --- 1 vs 2: both readings agree (less than) --- */
    T_BR beq,  1, 2, 0, str_br_1_2_beq
    T_BR bne,  1, 2, 1, str_br_1_2_bne
    T_BR blt,  1, 2, 1, str_br_1_2_blt
    T_BR bge,  1, 2, 0, str_br_1_2_bge
    T_BR bltu, 1, 2, 1, str_br_1_2_bltu
    T_BR bgeu, 1, 2, 0, str_br_1_2_bgeu

    /* --- 2 vs 1: both readings agree (greater than) --- */
    T_BR beq,  2, 1, 0, str_br_2_1_beq
    T_BR bne,  2, 1, 1, str_br_2_1_bne
    T_BR blt,  2, 1, 0, str_br_2_1_blt
    T_BR bge,  2, 1, 1, str_br_2_1_bge
    T_BR bltu, 2, 1, 0, str_br_2_1_bltu
    T_BR bgeu, 2, 1, 1, str_br_2_1_bgeu

    /* --- -1 vs 1: THE signed/unsigned divergence. Signed: -1 < 1, so
     *     BLT taken / BGE not. Unsigned: 0xffff...f > 1, so BLTU *not*
     *     taken / BGEU taken. Identical bits, opposite results. --- */
    T_BR beq,  -1, 1, 0, str_br_m1_1_beq
    T_BR bne,  -1, 1, 1, str_br_m1_1_bne
    T_BR blt,  -1, 1, 1, str_br_m1_1_blt
    T_BR bge,  -1, 1, 0, str_br_m1_1_bge
    T_BR bltu, -1, 1, 0, str_br_m1_1_bltu
    T_BR bgeu, -1, 1, 1, str_br_m1_1_bgeu

    /* --- 1 vs -1: the same divergence, operands reversed --- */
    T_BR beq,  1, -1, 0, str_br_1_m1_beq
    T_BR bne,  1, -1, 1, str_br_1_m1_bne
    T_BR blt,  1, -1, 0, str_br_1_m1_blt
    T_BR bge,  1, -1, 1, str_br_1_m1_bge
    T_BR bltu, 1, -1, 1, str_br_1_m1_bltu
    T_BR bgeu, 1, -1, 0, str_br_1_m1_bgeu

    /* --- -1 vs 0: signed -1 < 0 (BLT taken), unsigned 0xffff...f > 0
     *     (BLTU not taken). Divergence against zero specifically. --- */
    T_BR blt,  -1, 0, 1, str_br_m1_0_blt
    T_BR bge,  -1, 0, 0, str_br_m1_0_bge
    T_BR bltu, -1, 0, 0, str_br_m1_0_bltu
    T_BR bgeu, -1, 0, 1, str_br_m1_0_bgeu

    /* --- -1 vs -2: both negative; signed and unsigned agree here
     *     (-1 > -2 signed, 0xff..ff > 0xff..fe unsigned) --- */
    T_BR blt,  -1, -2, 0, str_br_m1_m2_blt
    T_BR bge,  -1, -2, 1, str_br_m1_m2_bge
    T_BR bltu, -1, -2, 0, str_br_m1_m2_bltu
    T_BR bgeu, -1, -2, 1, str_br_m1_m2_bgeu

    /* --- INT64_MIN vs INT64_MAX (INT32_* on RV32): the extreme
     *     divergence. Signed,
     *     MIN < MAX (BLT taken). Unsigned, 0x8000... > 0x7fff...
     *     (BLTU not taken). --- */
    T_BR blt,  INTX_MIN, INTX_MAX, 1, str_br_minmax_blt
    T_BR bge,  INTX_MIN, INTX_MAX, 0, str_br_minmax_bge
    T_BR bltu, INTX_MIN, INTX_MAX, 0, str_br_minmax_bltu
    T_BR bgeu, INTX_MIN, INTX_MAX, 1, str_br_minmax_bgeu

    /* --- INT64_MAX vs INT64_MIN: same, reversed --- */
    T_BR blt,  INTX_MAX, INTX_MIN, 0, str_br_maxmin_blt
    T_BR bge,  INTX_MAX, INTX_MIN, 1, str_br_maxmin_bge
    T_BR bltu, INTX_MAX, INTX_MIN, 1, str_br_maxmin_bltu
    T_BR bgeu, INTX_MAX, INTX_MIN, 0, str_br_maxmin_bgeu

    TEST_BEGIN str_br_alias_beq
    /* ===== rs1 == rs2 aliasing: the same register on both sides. =====
     * Not a hazard (branches write no register), but the comparison
     * must still be self-consistent: x == x, so BEQ/BGE/BGEU are
     * always taken and BNE/BLT/BLTU never are, whatever x holds. */
    LIX     s4, 0
    LIXT    t1, 0xdeadbeefcafebabe
    beq     t1, t1, 1f
    LIX     s4, 999
1:
    la      a0, str_br_alias_beq
    LIX     a1, 0
    mv      a2, s4
    call    check

    TEST_BEGIN str_br_alias_bne
    LIX     s4, 0
    LIXT    t1, 0xdeadbeefcafebabe
    bne     t1, t1, 1f
    LIX     s4, 1
1:
    la      a0, str_br_alias_bne
    LIX     a1, 1
    mv      a2, s4
    call    check

    TEST_BEGIN str_br_alias_blt
    LIX     s4, 0
    LIXT    t1, 0xdeadbeefcafebabe
    blt     t1, t1, 1f
    LIX     s4, 1
1:
    la      a0, str_br_alias_blt
    LIX     a1, 1
    mv      a2, s4
    call    check

    TEST_BEGIN str_br_alias_bge
    LIX     s4, 0
    LIXT    t1, 0xdeadbeefcafebabe
    bge     t1, t1, 1f
    LIX     s4, 999
1:
    la      a0, str_br_alias_bge
    LIX     a1, 0
    mv      a2, s4
    call    check

    TEST_BEGIN str_br_alias_bltu
    LIX     s4, 0
    LIXT    t1, 0xdeadbeefcafebabe
    bltu    t1, t1, 1f
    LIX     s4, 1
1:
    la      a0, str_br_alias_bltu
    LIX     a1, 1
    mv      a2, s4
    call    check

    TEST_BEGIN str_br_alias_bgeu
    LIX     s4, 0
    LIXT    t1, 0xdeadbeefcafebabe
    bgeu    t1, t1, 1f
    LIX     s4, 999
1:
    la      a0, str_br_alias_bgeu
    LIX     a1, 0
    mv      a2, s4
    call    check

    TEST_BEGIN str_br_x0_beq_taken
    /* ===== x0 as an operand: comparing against the hardwired zero
     * register, the "branch if (non)zero" idiom. ===== */
    LIX     s4, 0
    LIX     t1, 0
    beq     t1, zero, 1f
    LIX     s4, 999
1:
    la      a0, str_br_x0_beq_taken
    LIX     a1, 0
    mv      a2, s4
    call    check

    TEST_BEGIN str_br_x0_beq_nottaken
    LIX     s4, 0
    LIX     t1, 5
    beq     t1, zero, 1f
    LIX     s4, 1
1:
    la      a0, str_br_x0_beq_nottaken
    LIX     a1, 1
    mv      a2, s4
    call    check

    TEST_BEGIN str_br_x0_blt
    LIX     s4, 0
    LIX     t1, -1
    blt     t1, zero, 1f            /* signed: -1 < 0, taken */
    LIX     s4, 999
1:
    la      a0, str_br_x0_blt
    LIX     a1, 0
    mv      a2, s4
    call    check

    TEST_BEGIN str_br_x0_bltu
    LIX     s4, 0
    LIX     t1, -1
    bltu    t1, zero, 1f            /* unsigned: 0xff..ff > 0, NOT taken */
    LIX     s4, 1
1:
    la      a0, str_br_x0_bltu
    LIX     a1, 1
    mv      a2, s4
    call    check

    /* ===== register sweeps (BEQ, equal values) ===== */
    T_BR_RS1 ra,  str_br_rs1_ra
    T_BR_RS1 t0,  str_br_rs1_t0
    T_BR_RS1 s0,  str_br_rs1_s0
    T_BR_RS1 a0,  str_br_rs1_a0
    T_BR_RS1 s10, str_br_rs1_s10
    T_BR_RS1 t6,  str_br_rs1_t6

    T_BR_RS2 ra,  str_br_rs2_ra
    T_BR_RS2 t0,  str_br_rs2_t0
    T_BR_RS2 s0,  str_br_rs2_s0
    T_BR_RS2 a0,  str_br_rs2_a0
    T_BR_RS2 s10, str_br_rs2_s10
    T_BR_RS2 t6,  str_br_rs2_t6

    /* ===== offset sweep (through BEQ; all six share the identical
     * B-type offset encoding, so sweeping it once is sufficient) ===== */
    T_BR_FWD 8,    str_br_fwd8
    T_BR_FWD 16,   str_br_fwd16
    T_BR_FWD 32,   str_br_fwd32
    T_BR_FWD 64,   str_br_fwd64
    T_BR_FWD 128,  str_br_fwd128
    T_BR_FWD 256,  str_br_fwd256
    T_BR_FWD 512,  str_br_fwd512
    T_BR_FWD 1024, str_br_fwd1024
    T_BR_FWD 2048, str_br_fwd2048
    T_BR_FWD 4092, str_br_fwdmax

    T_BR_BWD 8,    str_br_bwd8
    T_BR_BWD 16,   str_br_bwd16
    T_BR_BWD 32,   str_br_bwd32
    T_BR_BWD 64,   str_br_bwd64
    T_BR_BWD 128,  str_br_bwd128
    T_BR_BWD 256,  str_br_bwd256
    T_BR_BWD 512,  str_br_bwd512
    T_BR_BWD 1024, str_br_bwd1024
    T_BR_BWD 2048, str_br_bwd2048
    T_BR_BWD 4092, str_br_bwdmax

    TEST_BEGIN str_br_loop
    /* ===== a real loop driven by a backward branch, exercised on
     * every iteration but the last ===== */
    LIX     s0, 0
2:
    addi    s0, s0, 1
    LIX     t0, 5
    bne     s0, t0, 2b
    la      a0, str_br_loop
    LIX     a1, 5
    mv      a2, s0
    call    check

    jal     ra, bitx_i_branches

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

bitx_i_branches:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    call    bx_sled_init
    /* operands chosen so each branch is taken; the signed/unsigned
     * pairs use -5 vs 3, which order differently under the two
     * readings. Offset background +8 for the register-only pairs. */
    BX_POOL 0x0123456789abcdef, 0x0123456789abcdef
    BX_E_RRI5 BX_C_BR, "beq, 1, BEQ", 28, 29, "0x2,0x4,0x8,0x10,0x20,0x40,0x80,0x100,0x200,0x400,0x800,0x1000", 8
    BX_POOL 0x0123456789abcdef, 0x0123456789abcdee
    BX_E_RRI5 BX_C_BR, "bne, 0, BNE", 28, 29, "0x2,0x4,0x8,0x10,0x20,0x40,0x80,0x100,0x200,0x400,0x800,0x1000", 8
    BX_POOL -5, 3
    BX_E_RRI5 BX_C_BR, "blt, 0, BLT", 28, 29, "0x2,0x4,0x8,0x10,0x20,0x40,0x80,0x100,0x200,0x400,0x800,0x1000", 8
    BX_E_RRI5 BX_C_BR, "bgeu, 1, BGEU", 28, 29, "0x2,0x4,0x8,0x10,0x20,0x40,0x80,0x100,0x200,0x400,0x800,0x1000", 8
    BX_POOL 3, -5
    BX_E_RRI5 BX_C_BR, "bge, 1, BGE", 28, 29, "0x2,0x4,0x8,0x10,0x20,0x40,0x80,0x100,0x200,0x400,0x800,0x1000", 8
    BX_E_RRI5 BX_C_BR, "bltu, 0, BLTU", 28, 29, "0x2,0x4,0x8,0x10,0x20,0x40,0x80,0x100,0x200,0x400,0x800,0x1000", 8

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

    .section .rodata
str_br_eq_beq:  .asciz "BEQ 0,0 taken"
str_br_eq_bne:  .asciz "BNE 0,0 not taken"
str_br_eq_blt:  .asciz "BLT 0,0 not taken (strict)"
str_br_eq_bge:  .asciz "BGE 0,0 taken (non-strict)"
str_br_eq_bltu: .asciz "BLTU 0,0 not taken (strict)"
str_br_eq_bgeu: .asciz "BGEU 0,0 taken (non-strict)"
str_br_1_2_beq:  .asciz "BEQ 1,2 not taken"
str_br_1_2_bne:  .asciz "BNE 1,2 taken"
str_br_1_2_blt:  .asciz "BLT 1,2 taken"
str_br_1_2_bge:  .asciz "BGE 1,2 not taken"
str_br_1_2_bltu: .asciz "BLTU 1,2 taken"
str_br_1_2_bgeu: .asciz "BGEU 1,2 not taken"
str_br_2_1_beq:  .asciz "BEQ 2,1 not taken"
str_br_2_1_bne:  .asciz "BNE 2,1 taken"
str_br_2_1_blt:  .asciz "BLT 2,1 not taken"
str_br_2_1_bge:  .asciz "BGE 2,1 taken"
str_br_2_1_bltu: .asciz "BLTU 2,1 not taken"
str_br_2_1_bgeu: .asciz "BGEU 2,1 taken"
str_br_m1_1_beq:  .asciz "BEQ -1,1 not taken"
str_br_m1_1_bne:  .asciz "BNE -1,1 taken"
str_br_m1_1_blt:  .asciz "BLT -1,1 taken (signed: -1 < 1)"
str_br_m1_1_bge:  .asciz "BGE -1,1 not taken (signed)"
str_br_m1_1_bltu: .asciz "BLTU -1,1 NOT taken (unsigned: 0xff..ff > 1)"
str_br_m1_1_bgeu: .asciz "BGEU -1,1 taken (unsigned)"
str_br_1_m1_beq:  .asciz "BEQ 1,-1 not taken"
str_br_1_m1_bne:  .asciz "BNE 1,-1 taken"
str_br_1_m1_blt:  .asciz "BLT 1,-1 not taken (signed)"
str_br_1_m1_bge:  .asciz "BGE 1,-1 taken (signed)"
str_br_1_m1_bltu: .asciz "BLTU 1,-1 taken (unsigned: 1 < 0xff..ff)"
str_br_1_m1_bgeu: .asciz "BGEU 1,-1 not taken (unsigned)"
str_br_m1_0_blt:  .asciz "BLT -1,0 taken (signed)"
str_br_m1_0_bge:  .asciz "BGE -1,0 not taken (signed)"
str_br_m1_0_bltu: .asciz "BLTU -1,0 NOT taken (unsigned)"
str_br_m1_0_bgeu: .asciz "BGEU -1,0 taken (unsigned)"
str_br_m1_m2_blt:  .asciz "BLT -1,-2 not taken"
str_br_m1_m2_bge:  .asciz "BGE -1,-2 taken"
str_br_m1_m2_bltu: .asciz "BLTU -1,-2 not taken"
str_br_m1_m2_bgeu: .asciz "BGEU -1,-2 taken"
    .if XLEN == 64
str_br_minmax_blt:  .asciz "BLT INT64_MIN,INT64_MAX taken (signed)"
str_br_minmax_bge:  .asciz "BGE INT64_MIN,INT64_MAX not taken (signed)"
str_br_minmax_bltu: .asciz "BLTU INT64_MIN,INT64_MAX NOT taken (unsigned)"
str_br_minmax_bgeu: .asciz "BGEU INT64_MIN,INT64_MAX taken (unsigned)"
str_br_maxmin_blt:  .asciz "BLT INT64_MAX,INT64_MIN not taken (signed)"
str_br_maxmin_bge:  .asciz "BGE INT64_MAX,INT64_MIN taken (signed)"
str_br_maxmin_bltu: .asciz "BLTU INT64_MAX,INT64_MIN taken (unsigned)"
str_br_maxmin_bgeu: .asciz "BGEU INT64_MAX,INT64_MIN not taken (unsigned)"
    .else
str_br_minmax_blt:  .asciz "BLT INT32_MIN,INT32_MAX taken (signed)"
str_br_minmax_bge:  .asciz "BGE INT32_MIN,INT32_MAX not taken (signed)"
str_br_minmax_bltu: .asciz "BLTU INT32_MIN,INT32_MAX NOT taken (unsigned)"
str_br_minmax_bgeu: .asciz "BGEU INT32_MIN,INT32_MAX taken (unsigned)"
str_br_maxmin_blt:  .asciz "BLT INT32_MAX,INT32_MIN not taken (signed)"
str_br_maxmin_bge:  .asciz "BGE INT32_MAX,INT32_MIN taken (signed)"
str_br_maxmin_bltu: .asciz "BLTU INT32_MAX,INT32_MIN taken (unsigned)"
str_br_maxmin_bgeu: .asciz "BGEU INT32_MAX,INT32_MIN not taken (unsigned)"
    .endif
str_br_alias_beq:  .asciz "BEQ rs1==rs2 always taken"
str_br_alias_bne:  .asciz "BNE rs1==rs2 never taken"
str_br_alias_blt:  .asciz "BLT rs1==rs2 never taken"
str_br_alias_bge:  .asciz "BGE rs1==rs2 always taken"
str_br_alias_bltu: .asciz "BLTU rs1==rs2 never taken"
str_br_alias_bgeu: .asciz "BGEU rs1==rs2 always taken"
str_br_x0_beq_taken:    .asciz "BEQ rs2=x0 taken (value is zero)"
str_br_x0_beq_nottaken: .asciz "BEQ rs2=x0 not taken (value nonzero)"
str_br_x0_blt:  .asciz "BLT rs2=x0 taken (signed -1 < 0)"
str_br_x0_bltu: .asciz "BLTU rs2=x0 NOT taken (unsigned 0xff..ff > 0)"
str_br_rs1_ra:  .asciz "BEQ rs1=ra(x1)"
str_br_rs1_t0:  .asciz "BEQ rs1=t0(x5)"
str_br_rs1_s0:  .asciz "BEQ rs1=s0(x8)"
str_br_rs1_a0:  .asciz "BEQ rs1=a0(x10)"
str_br_rs1_s10: .asciz "BEQ rs1=s10(x26)"
str_br_rs1_t6:  .asciz "BEQ rs1=t6(x31)"
str_br_rs2_ra:  .asciz "BEQ rs2=ra(x1)"
str_br_rs2_t0:  .asciz "BEQ rs2=t0(x5)"
str_br_rs2_s0:  .asciz "BEQ rs2=s0(x8)"
str_br_rs2_a0:  .asciz "BEQ rs2=a0(x10)"
str_br_rs2_s10: .asciz "BEQ rs2=s10(x26)"
str_br_rs2_t6:  .asciz "BEQ rs2=t6(x31)"
str_br_fwd8:    .asciz "BEQ forward +8 (bit3)"
str_br_fwd16:   .asciz "BEQ forward +16 (bit4)"
str_br_fwd32:   .asciz "BEQ forward +32 (bit5)"
str_br_fwd64:   .asciz "BEQ forward +64 (bit6)"
str_br_fwd128:  .asciz "BEQ forward +128 (bit7)"
str_br_fwd256:  .asciz "BEQ forward +256 (bit8)"
str_br_fwd512:  .asciz "BEQ forward +512 (bit9)"
str_br_fwd1024: .asciz "BEQ forward +1024 (bit10)"
str_br_fwd2048: .asciz "BEQ forward +2048 (bit11)"
str_br_fwdmax:  .asciz "BEQ forward +4092 (near max)"
str_br_bwd8:    .asciz "BEQ backward -8 (bit3)"
str_br_bwd16:   .asciz "BEQ backward -16 (bit4)"
str_br_bwd32:   .asciz "BEQ backward -32 (bit5)"
str_br_bwd64:   .asciz "BEQ backward -64 (bit6)"
str_br_bwd128:  .asciz "BEQ backward -128 (bit7)"
str_br_bwd256:  .asciz "BEQ backward -256 (bit8)"
str_br_bwd512:  .asciz "BEQ backward -512 (bit9)"
str_br_bwd1024: .asciz "BEQ backward -1024 (bit10)"
str_br_bwd2048: .asciz "BEQ backward -2048 (bit11)"
str_br_bwdmax:  .asciz "BEQ backward -4092 (near max)"
str_br_loop:    .asciz "BNE as a loop's backward edge, 5 iterations"
