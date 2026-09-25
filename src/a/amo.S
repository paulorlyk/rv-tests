/* =====================================================================
 * a/amo.S  --  RV64A atomic memory operations:
 *               AMOSWAP.W, AMOADD.W, AMOXOR.W, AMOAND.W, AMOOR.W,
 *               AMOMIN.W, AMOMAX.W, AMOMINU.W, AMOMAXU.W,
 *               and the same nine as .D
 *
 * Part of the A suite; see a/tests.S for how this plugs into the rest
 * (main_tests.S -> a/tests.S -> here), and common.S for the
 * boot/UART/reporting harness everything sits on ("check", "uart_puts"
 * are used from there; nothing else).
 *
 * Every AMO has the same shape: rd <- mem[rs1] (the OLD value), then
 * mem[rs1] <- op(old, rs2), all as one atomic step. The address is rs1
 * itself (no offset field). The 32-bit .W forms read and write one word
 * and sign-extend the old word into rd; the .D forms are RV64-only. So
 * each case has TWO results, and every value test checks both: the
 * value returned in rd, and the word/doubleword left in memory.
 *
 * All 18 share one R-type AMO encoding (funct5 selects the operation,
 * funct3 the width, plus the aq/rl ordering bits), so the same
 * organising idea as i/op_alu.S and m/mul.S: rd/rs1/rs2 and their
 * aliasing combinations are swept once, through AMOADD.W (it exists on
 * both widths), and the per-instruction depth goes into the values.
 *
 * Per-instruction highlights:
 *   - rd gets the OLD memory value, never the new one. Each
 *     instruction's first case (and most others) has an old value and a
 *     result that differ, so "returns the new value" and "rd and memory
 *     swapped" both fail.
 *   - .W sign-extension: old words with bit 31 set must come back as
 *     0xffffffff........ in rd (on RV64; trivially true on RV32).
 *   - .W writes exactly one word: the words just below and just above
 *     the target are checked after every instruction, at both word
 *     offsets of a doubleword, so a store that is too wide, lands on the
 *     wrong half, or lets AMOADD.W's carry spill into the next word
 *     fails. The .D forms get the same check.
 *   - AMOMIN/AMOMAX/AMOMINU/AMOMAXU all run against the *same* operand
 *     pairs, chosen where the signed and unsigned readings diverge
 *     ((1, -1), (INT_MIN, INT_MAX) in both orders), so a decoder that
 *     swaps signed/unsigned or min/max fails visibly. Both orders
 *     matter: the result must come from memory in one and from rs2 in
 *     the other.
 *   - The .W compares use 32-bit values: on RV64 rs2's upper half is
 *     garbage in one case per instruction and must be ignored, and
 *     0x80000000 loaded by li (upper half zero) must still compare as
 *     negative. The .D compares use all 64 bits: (2^32, 1) and
 *     (0xffffffff, 0) give the opposite answer under a 32-bit compare.
 *   - rd=x0: memory is still updated (an AMO with rd=x0 is how a
 *     plain atomic store/add is written). rs2=x0: AMOSWAP stores 0,
 *     AMOOR returns the old value and leaves memory alone (the atomic
 *     load idiom).
 *   - Aliasing: rd==rs2 (AMOSWAP swaps a register with memory: the old
 *     rs2 must be read before rd is written), rd==rs1 (the address must
 *     be read before rd is written), rs1==rs2 (the address itself is
 *     the operand), and rd==rs1==rs2. Sources are checked unmodified.
 *     rs1=sp gets its own case.
 *   - The aq/rl ordering bits must not change the result: every
 *     instruction is also run as .aq, .rl and .aqrl. (Ordering itself
 *     is unobservable on a single hart and isn't tested.)
 *
 * TRAPS: every AMO under test runs armed (TRAP_ARM / TRAP_FAILS,
 * harness.inc): on a hart without A (mcause 2), or if a misdecoded
 * address faults, each check of that test is a check_trap FAIL with
 * the mcause, never an UNEXPECTED TRAP hang.
 *
 * Not tested: misaligned addresses (an AMO must be naturally aligned
 * and traps otherwise). LR/SC are in a/lrsc.S.
 *
 * Bit independence across fields (bitx_a_amo, at the end): every bit
 * pair among rd/rs1/rs2 and the aq/rl bits, C(17,2) = 136 cases per
 * instruction, each checking both rd and memory -- see bitx.inc and
 * BX_C_AMO below.
 *
 * RV32 image (xlen.inc): the .D forms are RV64-only and left out, as
 * are the rs2-upper-half cases; everything else runs on both widths
 * with the same 32-bit values (on RV32 a .W is the full register).
 * ===================================================================== */

    .include "xlen.inc"
    .include "harness.inc"

    .option norvc            /* no compressed AMOs exist, but the helper
                               * li/mv/add sequences must never be
                               * silently re-encoded either */

    .include "bitx.inc"

    .global tests_a_amo

    .section .text

/* amo_buf: six words, each filled with AMO_FILL + its index by
 * amo_fill before every case. The target is amo_buf + 8 (+ 4 for the
 * upper word of that doubleword), so a word below and a word above
 * always hold a known value. */
    .equ    AMO_FILL, 0x5a5aa5a0

/* =======================================================================
 *  Shared macros
 * ======================================================================= */

/* T_AMO_VAL insn, w, off, mem, v, erd, emem, nrd, nmem -- fixed
 * rd=t2 / rs1=t3 / rs2=t4, the w-byte target at amo_buf + 8 + off set to
 * mem, rs2 = v. Checks rd against erd (for .W: the old word
 * sign-extended) and the target, read back zero-extended, against emem.
 * This t2/t3/t4 encoding is also the bitx reference (BX_C_AMO). */
.macro T_AMO_VAL insn, w, off, mem, v, erd, emem, nrd, nmem
    TEST_BEGIN \nrd
    jal     ra, amo_fill
    la      t3, amo_buf + 8 + \off
    LIX     t4, \mem
    .if \w == 4
    sw      t4, 0(t3)
    .else
    sd      t4, 0(t3)
    .endif
    LIX     t4, \v
    TRAP_ARM .Lav_trap\@
    \insn   t2, t4, (t3)
    TRAP_DISARM
    mv      s1, t2                  /* check clobbers t0-t6 */
    .if \w == 4
    LWUX    s2, 0(t3)
    .else
    ld      s2, 0(t3)
    .endif
    la      a0, \nrd
    LIX     a1, \erd
    mv      a2, s1
    call    check
    TEST_BEGIN \nmem
    la      a0, \nmem
    LIX     a1, \emem
    mv      a2, s2
    call    check
    TRAP_FAILS .Lav_trap\@, \nrd, \nmem
.endm

/* T_AMO_NEIGH insn, w, off, v, name -- run insn on the fill word(s) at
 * amo_buf + 8 + off with rs2 = v, then check that the word just below
 * and the word just above the w-byte target still hold their fill
 * values (one check: (below ^ fill) | (above ^ fill) must be 0). v is
 * chosen per operation so that the same operation done 64 bits wide
 * would change the upper word. It is truncated with LIXT on RV32 --
 * safe, since the expected value (0) doesn't depend on it. */
.macro T_AMO_NEIGH insn, w, off, v, name
    TEST_BEGIN \name
    jal     ra, amo_fill
    la      t3, amo_buf + 8 + \off
    LIXT    t4, \v
    TRAP_ARM .Lan_trap\@
    \insn   t2, t4, (t3)
    TRAP_DISARM
    lw      t0, -4(t3)
    LIX     t1, AMO_FILL + (8 + \off - 4) / 4
    xor     t0, t0, t1
    lw      t5, \w(t3)
    LIX     t1, AMO_FILL + (8 + \off + \w) / 4
    xor     t5, t5, t1
    or      t2, t0, t5
    la      a0, \name
    LIX     a1, 0
    mv      a2, t2
    call    check
    TRAP_FAILS .Lan_trap\@, \name
.endm

/* T_AMO_RD/RS1/RS2 reg, name -- sweep one register field at a time
 * (through AMOADD.W: memory 0x100, rs2 0x23), the other two fixed at
 * t2/t3/t4, none of which is in the swept lists. RD checks rd (old
 * value 0x100, captured to t2 before a0-a2 are reused); RS1/RS2 check
 * memory (0x123), which only comes out right if the right address and
 * the right addend were used. */
.macro T_AMO_RD rdreg, name
    TEST_BEGIN \name
    jal     ra, amo_fill
    la      t3, amo_buf + 8
    LIX     t4, 0x100
    sw      t4, 0(t3)
    LIX     t4, 0x23
    TRAP_ARM .Lar_trap\@
    amoadd.w \rdreg, t4, (t3)
    mv      t2, \rdreg
    TRAP_DISARM
    la      a0, \name
    LIX     a1, 0x100
    mv      a2, t2
    call    check
    TRAP_FAILS .Lar_trap\@, \name
.endm

.macro T_AMO_RS1 rs1reg, name
    TEST_BEGIN \name
    jal     ra, amo_fill
    la      \rs1reg, amo_buf + 8
    LIX     t4, 0x100
    sw      t4, 0(\rs1reg)
    LIX     t4, 0x23
    TRAP_ARM .Las1_trap\@
    amoadd.w t2, t4, (\rs1reg)
    TRAP_DISARM
    la      t3, amo_buf + 8
    LWUX    t2, 0(t3)
    la      a0, \name
    LIX     a1, 0x123
    mv      a2, t2
    call    check
    TRAP_FAILS .Las1_trap\@, \name
.endm

.macro T_AMO_RS2 rs2reg, name
    TEST_BEGIN \name
    jal     ra, amo_fill
    la      t3, amo_buf + 8
    LIX     t4, 0x100
    sw      t4, 0(t3)
    LIX     \rs2reg, 0x23
    TRAP_ARM .Las2_trap\@
    amoadd.w t2, \rs2reg, (t3)
    TRAP_DISARM
    LWUX    t2, 0(t3)
    la      a0, \name
    LIX     a1, 0x123
    mv      a2, t2
    call    check
    TRAP_FAILS .Las2_trap\@, \name
.endm

/* BX_C_AMO insn, w, nm, rd, rs1, rs2, o -- one bit-independence case
 * (bitx.inc): rd/rs1/rs2 as given, o = the raw aq/rl field (bit 1 = aq,
 * bit 0 = rl), which only selects the mnemonic suffix.
 *
 * Two register-sized slots, bx_amo_ref and bx_amo_dut, are set to the
 * sentinel with the pool's vb as the w-byte old value at offset 0 (so
 * on RV64 a .W also has the sentinel's upper word above it, which must
 * survive). The reference is the same instruction through the
 * background encoding (rd=t2, rs1=t3, rs2=t4, no ordering bits) on
 * bx_amo_ref -- the encoding the T_AMO_VAL tables pin down against
 * literals. The case under test runs on bx_amo_dut with rd pre-loaded
 * with the sentinel, then rs2 = va, then rs1 = the address: rs1 is
 * loaded last so it always holds a valid address, and when rs2 aliases
 * rs1 the operand is that address -- the reference is fed the same
 * (bx_amo_dut's address) as its rs2. Two checks per case: rd, then the
 * whole register-sized slot.
 *
 * Besides the reserved registers listed in bitx.inc, a4 (x14) and a5
 * (x15) carry the two slots' read-backs across the first check (check
 * leaves a3-a7 alone); both have three or more bits set, so neither is
 * ever a candidate. s3 holds bx_amo_dut's address, and is reused to
 * disarm.
 *
 * Trapping: one TRAP_ARM, before anything is swept, covers both the
 * reference and the case (the arm is one-shot, so it's still armed
 * for the case if the reference ran); after a trap, BX_TRAP_FAILS
 * restores sp/gp/tp and reports both names as check_trap FAILs. */
.macro BX_C_AMO insn, w, nm, rd, rs1, rs2, o
    .if (\o) == 0
    BX_C_AMO_ \insn, \w, \nm, \rd, \rs1, \rs2, \insn, 0, 0
    .elseif (\o) == 1
    BX_C_AMO_ \insn, \w, \nm, \rd, \rs1, \rs2, \insn\().rl, 0, 1
    .elseif (\o) == 2
    BX_C_AMO_ \insn, \w, \nm, \rd, \rs1, \rs2, \insn\().aq, 1, 0
    .else
    BX_C_AMO_ \insn, \w, \nm, \rd, \rs1, \rs2, \insn\().aqrl, 1, 1
    .endif
.endm

.macro BX_C_AMO_ insn, w, nm, rd, rs1, rs2, dut, aq, rl
    BX_NAME .Lbxa_n\@, "\nm bitx rd=x\rd rs1=x\rs1 rs2=x\rs2 aq=\aq rl=\rl"
    BX_NAME .Lbxa_m\@, "\nm bitx rd=x\rd rs1=x\rs1 rs2=x\rs2 aq=\aq rl=\rl mem"
    BX_ENTER .Lbxa_n\@
    TRAP_ARM .Lbxa_trap\@          /* covers the reference and the case */
    .option push
    .option norelax
    la      t3, bx_amo_ref
    la      s3, bx_amo_dut
    .option pop
    BX_PV   t4, 2
    REG_S   t4, 0(t3)
    REG_S   t4, 0(s3)
    BX_PV   t4, 1
    .if \w == 4
    sw      t4, 0(t3)
    sw      t4, 0(s3)
    .else
    sd      t4, 0(t3)
    sd      t4, 0(s3)
    .endif
    .if \rs1 == \rs2
    mv      t4, s3
    .else
    BX_PV   t4, 0
    .endif
    \insn   t2, t4, (t3)
    mv      t5, t2
    REG_L   a5, 0(t3)
    BX_PV   x\rd, 2
    BX_PV   x\rs2, 0
    mv      x\rs1, s3
    \dut    x\rd, x\rs2, (x\rs1)
    mv      t6, x\rd
    REG_L   a4, 0(s3)
    TRAP_DISARM_R s3
    BX_REPORT_AT .Lbxa_n\@
    mv      t5, a5
    mv      t6, a4
    BX_REPORT_AT .Lbxa_m\@
    BX_TRAP_FAILS .Lbxa_trap\@, .Lbxa_n\@, .Lbxa_m\@
.endm

tests_a_amo:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    jal     ra, test_amo_regs
    jal     ra, test_amo_w
    .if XLEN == 64
    jal     ra, test_amo_d
    .endif
    jal     ra, test_amo_neigh

    jal     ra, bitx_a_amo

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* amo_fill: amo_buf word i = AMO_FILL + i. Clobbers t0/t1 only. */
amo_fill:
    la      t0, amo_buf
    LIX     t1, AMO_FILL
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
 *  Register fields and aliasing (through AMOADD.W unless noted)
 * ======================================================================= */
test_amo_regs:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    T_AMO_RD ra,  str_amo_rd_ra
    T_AMO_RD t0,  str_amo_rd_t0
    T_AMO_RD s0,  str_amo_rd_s0
    T_AMO_RD a0,  str_amo_rd_a0
    T_AMO_RD s10, str_amo_rd_s10
    T_AMO_RD t6,  str_amo_rd_t6

    T_AMO_RS1 ra,  str_amo_rs1_ra
    T_AMO_RS1 t0,  str_amo_rs1_t0
    T_AMO_RS1 s0,  str_amo_rs1_s0
    T_AMO_RS1 a0,  str_amo_rs1_a0
    T_AMO_RS1 s10, str_amo_rs1_s10
    T_AMO_RS1 t6,  str_amo_rs1_t6

    T_AMO_RS2 ra,  str_amo_rs2_ra
    T_AMO_RS2 t0,  str_amo_rs2_t0
    T_AMO_RS2 s0,  str_amo_rs2_s0
    T_AMO_RS2 a0,  str_amo_rs2_a0
    T_AMO_RS2 s10, str_amo_rs2_s10
    T_AMO_RS2 t6,  str_amo_rs2_t6

    TEST_BEGIN str_amo_rs1_sp_rd
    /* rs1=sp: an address register the compressed ISA treats specially;
     * the AMO must use it like any other */
    addi    sp, sp, -16
    LIX     t4, 0x100
    sw      t4, 0(sp)
    LIX     t4, 0x23
    TRAP_ARM .Lamo_trap_sp
    amoadd.w t2, t4, (sp)
    TRAP_DISARM
    mv      s1, t2
    LWUX    s2, 0(sp)
    addi    sp, sp, 16
    la      a0, str_amo_rs1_sp_rd
    LIX     a1, 0x100
    mv      a2, s1
    call    check
    TEST_BEGIN str_amo_rs1_sp_mem
    la      a0, str_amo_rs1_sp_mem
    LIX     a1, 0x123
    mv      a2, s2
    call    check
    j       .Lamo_sp_done
.Lamo_trap_sp:                      /* trapped with sp still lowered */
    addi    sp, sp, 16
    TRAP_REPORT str_amo_rs1_sp_rd
    TRAP_REPORT str_amo_rs1_sp_mem
.Lamo_sp_done:

    /* rd=x0: result discarded, memory still updated */
    TEST_BEGIN str_amo_rd_x0
    jal     ra, amo_fill
    la      t3, amo_buf + 8
    LIX     t4, 0x100
    sw      t4, 0(t3)
    LIX     t4, 0x23
    TRAP_ARM .Lamo_trap_rd_x0
    amoadd.w x0, t4, (t3)
    TRAP_DISARM
    LWUX    t2, 0(t3)
    la      a0, str_amo_rd_x0
    LIX     a1, 0x123
    mv      a2, t2
    call    check
    TRAP_FAILS .Lamo_trap_rd_x0, str_amo_rd_x0

    /* rs2=x0 through AMOSWAP: stores 0 */
    TEST_BEGIN str_amoswap_rs2_x0_rd
    jal     ra, amo_fill
    la      t3, amo_buf + 8
    LIX     t4, 0x12345678
    sw      t4, 0(t3)
    TRAP_ARM .Lamo_trap_swap_x0
    amoswap.w t2, x0, (t3)
    TRAP_DISARM
    mv      s1, t2
    LWUX    s2, 0(t3)
    la      a0, str_amoswap_rs2_x0_rd
    LIX     a1, 0x12345678
    mv      a2, s1
    call    check
    TEST_BEGIN str_amoswap_rs2_x0_mem
    la      a0, str_amoswap_rs2_x0_mem
    LIX     a1, 0
    mv      a2, s2
    call    check
    TRAP_FAILS .Lamo_trap_swap_x0, str_amoswap_rs2_x0_rd, str_amoswap_rs2_x0_mem

    /* rs2=x0 through AMOOR: the atomic-load idiom, memory unchanged */
    TEST_BEGIN str_amoor_rs2_x0_rd
    jal     ra, amo_fill
    la      t3, amo_buf + 8
    LIX     t4, 0x87654321
    sw      t4, 0(t3)
    TRAP_ARM .Lamo_trap_or_x0
    amoor.w t2, x0, (t3)
    TRAP_DISARM
    mv      s1, t2
    LWUX    s2, 0(t3)
    la      a0, str_amoor_rs2_x0_rd
    LIX     a1, 0xffffffff87654321
    mv      a2, s1
    call    check
    TEST_BEGIN str_amoor_rs2_x0_mem
    la      a0, str_amoor_rs2_x0_mem
    LIX     a1, 0x87654321
    mv      a2, s2
    call    check
    TRAP_FAILS .Lamo_trap_or_x0, str_amoor_rs2_x0_rd, str_amoor_rs2_x0_mem

    TEST_BEGIN str_amoswap_rd_rs2_rd
    /* rd==rs2 through AMOSWAP: swaps the register with memory -- the
     * old rs2 must be read before rd is written */
    jal     ra, amo_fill
    la      t3, amo_buf + 8
    LIX     t4, 0x11223344
    sw      t4, 0(t3)
    LIX     t2, 0x55667788
    TRAP_ARM .Lamo_trap_swap_rd_rs2
    amoswap.w t2, t2, (t3)
    TRAP_DISARM
    mv      s1, t2
    LWUX    s2, 0(t3)
    la      a0, str_amoswap_rd_rs2_rd
    LIX     a1, 0x11223344
    mv      a2, s1
    call    check
    TEST_BEGIN str_amoswap_rd_rs2_mem
    la      a0, str_amoswap_rd_rs2_mem
    LIX     a1, 0x55667788
    mv      a2, s2
    call    check
    TRAP_FAILS .Lamo_trap_swap_rd_rs2, str_amoswap_rd_rs2_rd, str_amoswap_rd_rs2_mem

    /* rd==rs2 */
    TEST_BEGIN str_amo_alias_rd_rs2_rd
    jal     ra, amo_fill
    la      t3, amo_buf + 8
    LIX     t4, 0x100
    sw      t4, 0(t3)
    LIX     t2, 0x23
    TRAP_ARM .Lamo_trap_rd_rs2
    amoadd.w t2, t2, (t3)
    TRAP_DISARM
    mv      s1, t2
    LWUX    s2, 0(t3)
    la      a0, str_amo_alias_rd_rs2_rd
    LIX     a1, 0x100
    mv      a2, s1
    call    check
    TEST_BEGIN str_amo_alias_rd_rs2_mem
    la      a0, str_amo_alias_rd_rs2_mem
    LIX     a1, 0x123
    mv      a2, s2
    call    check
    TRAP_FAILS .Lamo_trap_rd_rs2, str_amo_alias_rd_rs2_rd, str_amo_alias_rd_rs2_mem

    /* rd==rs1: the address must be taken before rd is overwritten */
    TEST_BEGIN str_amo_alias_rd_rs1_rd
    jal     ra, amo_fill
    la      t3, amo_buf + 8
    LIX     t4, 0x100
    sw      t4, 0(t3)
    LIX     t4, 0x23
    TRAP_ARM .Lamo_trap_rd_rs1
    amoadd.w t3, t4, (t3)
    TRAP_DISARM
    mv      s1, t3
    la      t3, amo_buf + 8
    LWUX    s2, 0(t3)
    la      a0, str_amo_alias_rd_rs1_rd
    LIX     a1, 0x100
    mv      a2, s1
    call    check
    TEST_BEGIN str_amo_alias_rd_rs1_mem
    la      a0, str_amo_alias_rd_rs1_mem
    LIX     a1, 0x123
    mv      a2, s2
    call    check
    TRAP_FAILS .Lamo_trap_rd_rs1, str_amo_alias_rd_rs1_rd, str_amo_alias_rd_rs1_mem

    /* rs1==rs2 through the XLEN-wide AMOSWAP: stores its own address */
    TEST_BEGIN str_amo_alias_rs1_rs2_rd
    jal     ra, amo_fill
    la      t3, amo_buf + 8
    mv      s3, t3
    .if XLEN == 64
    LIX     t4, 0x0123456789abcdef
    sd      t4, 0(t3)
    TRAP_ARM .Lamo_trap_rs1_rs2
    amoswap.d t2, t3, (t3)
    TRAP_DISARM
    .else
    LIX     t4, 0x89abcdef
    sw      t4, 0(t3)
    TRAP_ARM .Lamo_trap_rs1_rs2
    amoswap.w t2, t3, (t3)
    TRAP_DISARM
    .endif
    mv      s1, t2
    REG_L   s2, 0(s3)
    la      a0, str_amo_alias_rs1_rs2_rd
    .if XLEN == 64
    LIX     a1, 0x0123456789abcdef
    .else
    LIX     a1, 0x89abcdef
    .endif
    mv      a2, s1
    call    check
    TEST_BEGIN str_amo_alias_rs1_rs2_mem
    la      a0, str_amo_alias_rs1_rs2_mem
    mv      a1, s3
    mv      a2, s2
    call    check
    TRAP_FAILS .Lamo_trap_rs1_rs2, str_amo_alias_rs1_rs2_rd, str_amo_alias_rs1_rs2_mem

    /* rs1==rs2 through AMOADD.W: adds the address's low word */
    TEST_BEGIN str_amo_alias_rs1_rs2_add_rd
    jal     ra, amo_fill
    la      t3, amo_buf + 8
    mv      s3, t3
    LIX     t4, 0x100
    sw      t4, 0(t3)
    TRAP_ARM .Lamo_trap_rs1_rs2_add
    amoadd.w t2, t3, (t3)
    TRAP_DISARM
    mv      s1, t2
    LWUX    s2, 0(s3)
    la      a0, str_amo_alias_rs1_rs2_add_rd
    LIX     a1, 0x100
    mv      a2, s1
    call    check
    TEST_BEGIN str_amo_alias_rs1_rs2_add_mem
    la      a0, str_amo_alias_rs1_rs2_add_mem
    addi    a1, s3, 0x100
    .if XLEN == 64
    slli    a1, a1, 32              /* the word read back is zero-extended */
    srli    a1, a1, 32
    .endif
    mv      a2, s2
    call    check
    TRAP_FAILS .Lamo_trap_rs1_rs2_add, str_amo_alias_rs1_rs2_add_rd, str_amo_alias_rs1_rs2_add_mem

    /* rd==rs1==rs2 through the XLEN-wide AMOSWAP */
    TEST_BEGIN str_amo_alias_all_same_rd
    jal     ra, amo_fill
    la      t3, amo_buf + 8
    mv      s3, t3
    .if XLEN == 64
    LIX     t4, 0xfedcba9876543210
    sd      t4, 0(t3)
    TRAP_ARM .Lamo_trap_all_same
    amoswap.d t3, t3, (t3)
    TRAP_DISARM
    .else
    LIX     t4, 0xfedcba98
    sw      t4, 0(t3)
    TRAP_ARM .Lamo_trap_all_same
    amoswap.w t3, t3, (t3)
    TRAP_DISARM
    .endif
    mv      s1, t3
    REG_L   s2, 0(s3)
    la      a0, str_amo_alias_all_same_rd
    .if XLEN == 64
    LIX     a1, 0xfedcba9876543210
    .else
    LIX     a1, 0xfedcba98
    .endif
    mv      a2, s1
    call    check
    TEST_BEGIN str_amo_alias_all_same_mem
    la      a0, str_amo_alias_all_same_mem
    mv      a1, s3
    mv      a2, s2
    call    check
    TRAP_FAILS .Lamo_trap_all_same, str_amo_alias_all_same_rd, str_amo_alias_all_same_mem

    /* sources unmodified */
    TEST_BEGIN str_amo_rs1_preserved
    jal     ra, amo_fill
    la      t3, amo_buf + 8
    LIX     t4, 0x100
    sw      t4, 0(t3)
    LIXT    t4, 0x0fedcba987654321
    mv      s1, t3
    mv      s2, t4
    TRAP_ARM .Lamo_trap_preserved
    amoadd.w t2, t4, (t3)
    TRAP_DISARM
    mv      s4, t3
    mv      s5, t4
    la      a0, str_amo_rs1_preserved
    mv      a1, s1
    mv      a2, s4
    call    check
    TEST_BEGIN str_amo_rs2_preserved
    la      a0, str_amo_rs2_preserved
    mv      a1, s2
    mv      a2, s5
    call    check
    TRAP_FAILS .Lamo_trap_preserved, str_amo_rs1_preserved, str_amo_rs2_preserved

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  .W values (both widths)
 * ======================================================================= */
test_amo_w:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    /* ----- AMOSWAP.W ----- */
    T_AMO_VAL amoswap.w, 4, 0, 0x12345678, 0x9abcdef0, 0x12345678, 0x9abcdef0, str_amoswap_w_basic_rd, str_amoswap_w_basic_mem
    T_AMO_VAL amoswap.w, 4, 4, 0x80000000, 0x00000001, 0xffffffff80000000, 0x00000001, str_amoswap_w_sext_rd, str_amoswap_w_sext_mem
    T_AMO_VAL amoswap.w, 4, 0, 0xffffffff, 0x00000000, 0xffffffffffffffff, 0x00000000, str_amoswap_w_zero_rd, str_amoswap_w_zero_mem

    /* ----- AMOADD.W ----- */
    T_AMO_VAL amoadd.w, 4, 0, 0x00000005, 0x00000007, 0x00000005, 0x0000000c, str_amoadd_w_basic_rd, str_amoadd_w_basic_mem
    T_AMO_VAL amoadd.w, 4, 4, 0x7fffffff, 0x00000001, 0x7fffffff, 0x80000000, str_amoadd_w_ovf_rd, str_amoadd_w_ovf_mem
    T_AMO_VAL amoadd.w, 4, 0, 0xffffffff, 0x00000001, 0xffffffffffffffff, 0x00000000, str_amoadd_w_carry_rd, str_amoadd_w_carry_mem
    T_AMO_VAL amoadd.w, 4, 4, 0x80000000, 0x80000000, 0xffffffff80000000, 0x00000000, str_amoadd_w_minmin_rd, str_amoadd_w_minmin_mem
    T_AMO_VAL amoadd.w, 4, 0, 0x00000001, 0xffffffffffffffff, 0x00000001, 0x00000000, str_amoadd_w_neg_rd, str_amoadd_w_neg_mem

    /* ----- AMOXOR.W ----- */
    T_AMO_VAL amoxor.w, 4, 0, 0xff00ff00, 0x0ff00ff0, 0xffffffffff00ff00, 0xf0f0f0f0, str_amoxor_w_basic_rd, str_amoxor_w_basic_mem
    T_AMO_VAL amoxor.w, 4, 4, 0x5a5a5a5a, 0x5a5a5a5a, 0x5a5a5a5a, 0x00000000, str_amoxor_w_self_rd, str_amoxor_w_self_mem
    T_AMO_VAL amoxor.w, 4, 0, 0x80000000, 0xffffffffffffffff, 0xffffffff80000000, 0x7fffffff, str_amoxor_w_flip_rd, str_amoxor_w_flip_mem

    /* ----- AMOAND.W ----- */
    T_AMO_VAL amoand.w, 4, 0, 0xff00ff00, 0x0ff00ff0, 0xffffffffff00ff00, 0x0f000f00, str_amoand_w_basic_rd, str_amoand_w_basic_mem
    T_AMO_VAL amoand.w, 4, 4, 0x12345678, 0x00000000, 0x12345678, 0x00000000, str_amoand_w_zero_rd, str_amoand_w_zero_mem
    T_AMO_VAL amoand.w, 4, 0, 0x80000001, 0xffffffffffffffff, 0xffffffff80000001, 0x80000001, str_amoand_w_ones_rd, str_amoand_w_ones_mem

    /* ----- AMOOR.W ----- */
    T_AMO_VAL amoor.w, 4, 0, 0xff00ff00, 0x0ff00ff0, 0xffffffffff00ff00, 0xfff0fff0, str_amoor_w_basic_rd, str_amoor_w_basic_mem
    T_AMO_VAL amoor.w, 4, 4, 0x00000000, 0x80000000, 0x00000000, 0x80000000, str_amoor_w_bit31_rd, str_amoor_w_bit31_mem
    T_AMO_VAL amoor.w, 4, 0, 0x12345678, 0x00000000, 0x12345678, 0x12345678, str_amoor_w_zero_rd, str_amoor_w_zero_mem

    /* ----- AMOMIN.W / AMOMAX.W / AMOMINU.W / AMOMAXU.W: the same
     * pairs through all four ----- */
    T_AMO_VAL amomin.w, 4, 0, 0x00000001, 0xffffffffffffffff, 0x00000001, 0xffffffff, str_amomin_w_p1m1_rd, str_amomin_w_p1m1_mem
    T_AMO_VAL amomax.w, 4, 0, 0x00000001, 0xffffffffffffffff, 0x00000001, 0x00000001, str_amomax_w_p1m1_rd, str_amomax_w_p1m1_mem
    T_AMO_VAL amominu.w, 4, 0, 0x00000001, 0xffffffffffffffff, 0x00000001, 0x00000001, str_amominu_w_p1m1_rd, str_amominu_w_p1m1_mem
    T_AMO_VAL amomaxu.w, 4, 0, 0x00000001, 0xffffffffffffffff, 0x00000001, 0xffffffff, str_amomaxu_w_p1m1_rd, str_amomaxu_w_p1m1_mem

    T_AMO_VAL amomin.w, 4, 4, 0x80000000, 0x7fffffff, 0xffffffff80000000, 0x80000000, str_amomin_w_minmax_rd, str_amomin_w_minmax_mem
    T_AMO_VAL amomax.w, 4, 4, 0x80000000, 0x7fffffff, 0xffffffff80000000, 0x7fffffff, str_amomax_w_minmax_rd, str_amomax_w_minmax_mem
    T_AMO_VAL amominu.w, 4, 4, 0x80000000, 0x7fffffff, 0xffffffff80000000, 0x7fffffff, str_amominu_w_minmax_rd, str_amominu_w_minmax_mem
    T_AMO_VAL amomaxu.w, 4, 4, 0x80000000, 0x7fffffff, 0xffffffff80000000, 0x80000000, str_amomaxu_w_minmax_rd, str_amomaxu_w_minmax_mem

    T_AMO_VAL amomin.w, 4, 0, 0x7fffffff, 0x80000000, 0x7fffffff, 0x80000000, str_amomin_w_maxmin_rd, str_amomin_w_maxmin_mem
    T_AMO_VAL amomax.w, 4, 0, 0x7fffffff, 0x80000000, 0x7fffffff, 0x7fffffff, str_amomax_w_maxmin_rd, str_amomax_w_maxmin_mem
    T_AMO_VAL amominu.w, 4, 0, 0x7fffffff, 0x80000000, 0x7fffffff, 0x7fffffff, str_amominu_w_maxmin_rd, str_amominu_w_maxmin_mem
    T_AMO_VAL amomaxu.w, 4, 0, 0x7fffffff, 0x80000000, 0x7fffffff, 0x80000000, str_amomaxu_w_maxmin_rd, str_amomaxu_w_maxmin_mem

    T_AMO_VAL amomin.w, 4, 4, 0xfffffffe, 0xffffffffffffffff, 0xfffffffffffffffe, 0xfffffffe, str_amomin_w_m2m1_rd, str_amomin_w_m2m1_mem
    T_AMO_VAL amomax.w, 4, 4, 0xfffffffe, 0xffffffffffffffff, 0xfffffffffffffffe, 0xffffffff, str_amomax_w_m2m1_rd, str_amomax_w_m2m1_mem
    T_AMO_VAL amominu.w, 4, 4, 0xfffffffe, 0xffffffffffffffff, 0xfffffffffffffffe, 0xfffffffe, str_amominu_w_m2m1_rd, str_amominu_w_m2m1_mem
    T_AMO_VAL amomaxu.w, 4, 4, 0xfffffffe, 0xffffffffffffffff, 0xfffffffffffffffe, 0xffffffff, str_amomaxu_w_m2m1_rd, str_amomaxu_w_m2m1_mem

    T_AMO_VAL amomin.w, 4, 0, 0x00000003, 0x00000007, 0x00000003, 0x00000003, str_amomin_w_p3p7_rd, str_amomin_w_p3p7_mem
    T_AMO_VAL amomax.w, 4, 0, 0x00000003, 0x00000007, 0x00000003, 0x00000007, str_amomax_w_p3p7_rd, str_amomax_w_p3p7_mem
    T_AMO_VAL amominu.w, 4, 0, 0x00000003, 0x00000007, 0x00000003, 0x00000003, str_amominu_w_p3p7_rd, str_amominu_w_p3p7_mem
    T_AMO_VAL amomaxu.w, 4, 0, 0x00000003, 0x00000007, 0x00000003, 0x00000007, str_amomaxu_w_p3p7_rd, str_amomaxu_w_p3p7_mem

    T_AMO_VAL amomin.w, 4, 4, 0x00000005, 0x00000005, 0x00000005, 0x00000005, str_amomin_w_eq_rd, str_amomin_w_eq_mem
    T_AMO_VAL amomax.w, 4, 4, 0x00000005, 0x00000005, 0x00000005, 0x00000005, str_amomax_w_eq_rd, str_amomax_w_eq_mem
    T_AMO_VAL amominu.w, 4, 4, 0x00000005, 0x00000005, 0x00000005, 0x00000005, str_amominu_w_eq_rd, str_amominu_w_eq_mem
    T_AMO_VAL amomaxu.w, 4, 4, 0x00000005, 0x00000005, 0x00000005, 0x00000005, str_amomaxu_w_eq_rd, str_amomaxu_w_eq_mem

    /* ----- ordering bits: .aq/.rl/.aqrl must not change the result
     * (same operands as each instruction's first case) ----- */
    T_AMO_VAL amoswap.w.aq, 4, 0, 0x12345678, 0x9abcdef0, 0x12345678, 0x9abcdef0, str_amoswap_w_aq_rd, str_amoswap_w_aq_mem
    T_AMO_VAL amoswap.w.rl, 4, 0, 0x12345678, 0x9abcdef0, 0x12345678, 0x9abcdef0, str_amoswap_w_rl_rd, str_amoswap_w_rl_mem
    T_AMO_VAL amoswap.w.aqrl, 4, 0, 0x12345678, 0x9abcdef0, 0x12345678, 0x9abcdef0, str_amoswap_w_aqrl_rd, str_amoswap_w_aqrl_mem
    T_AMO_VAL amoadd.w.aq, 4, 0, 0x00000005, 0x00000007, 0x00000005, 0x0000000c, str_amoadd_w_aq_rd, str_amoadd_w_aq_mem
    T_AMO_VAL amoadd.w.rl, 4, 0, 0x00000005, 0x00000007, 0x00000005, 0x0000000c, str_amoadd_w_rl_rd, str_amoadd_w_rl_mem
    T_AMO_VAL amoadd.w.aqrl, 4, 0, 0x00000005, 0x00000007, 0x00000005, 0x0000000c, str_amoadd_w_aqrl_rd, str_amoadd_w_aqrl_mem
    T_AMO_VAL amoxor.w.aq, 4, 0, 0xff00ff00, 0x0ff00ff0, 0xffffffffff00ff00, 0xf0f0f0f0, str_amoxor_w_aq_rd, str_amoxor_w_aq_mem
    T_AMO_VAL amoxor.w.rl, 4, 0, 0xff00ff00, 0x0ff00ff0, 0xffffffffff00ff00, 0xf0f0f0f0, str_amoxor_w_rl_rd, str_amoxor_w_rl_mem
    T_AMO_VAL amoxor.w.aqrl, 4, 0, 0xff00ff00, 0x0ff00ff0, 0xffffffffff00ff00, 0xf0f0f0f0, str_amoxor_w_aqrl_rd, str_amoxor_w_aqrl_mem
    T_AMO_VAL amoand.w.aq, 4, 0, 0xff00ff00, 0x0ff00ff0, 0xffffffffff00ff00, 0x0f000f00, str_amoand_w_aq_rd, str_amoand_w_aq_mem
    T_AMO_VAL amoand.w.rl, 4, 0, 0xff00ff00, 0x0ff00ff0, 0xffffffffff00ff00, 0x0f000f00, str_amoand_w_rl_rd, str_amoand_w_rl_mem
    T_AMO_VAL amoand.w.aqrl, 4, 0, 0xff00ff00, 0x0ff00ff0, 0xffffffffff00ff00, 0x0f000f00, str_amoand_w_aqrl_rd, str_amoand_w_aqrl_mem
    T_AMO_VAL amoor.w.aq, 4, 0, 0xff00ff00, 0x0ff00ff0, 0xffffffffff00ff00, 0xfff0fff0, str_amoor_w_aq_rd, str_amoor_w_aq_mem
    T_AMO_VAL amoor.w.rl, 4, 0, 0xff00ff00, 0x0ff00ff0, 0xffffffffff00ff00, 0xfff0fff0, str_amoor_w_rl_rd, str_amoor_w_rl_mem
    T_AMO_VAL amoor.w.aqrl, 4, 0, 0xff00ff00, 0x0ff00ff0, 0xffffffffff00ff00, 0xfff0fff0, str_amoor_w_aqrl_rd, str_amoor_w_aqrl_mem
    T_AMO_VAL amomin.w.aq, 4, 0, 0x00000001, 0xffffffffffffffff, 0x00000001, 0xffffffff, str_amomin_w_aq_rd, str_amomin_w_aq_mem
    T_AMO_VAL amomin.w.rl, 4, 0, 0x00000001, 0xffffffffffffffff, 0x00000001, 0xffffffff, str_amomin_w_rl_rd, str_amomin_w_rl_mem
    T_AMO_VAL amomin.w.aqrl, 4, 0, 0x00000001, 0xffffffffffffffff, 0x00000001, 0xffffffff, str_amomin_w_aqrl_rd, str_amomin_w_aqrl_mem
    T_AMO_VAL amomax.w.aq, 4, 0, 0x00000001, 0xffffffffffffffff, 0x00000001, 0x00000001, str_amomax_w_aq_rd, str_amomax_w_aq_mem
    T_AMO_VAL amomax.w.rl, 4, 0, 0x00000001, 0xffffffffffffffff, 0x00000001, 0x00000001, str_amomax_w_rl_rd, str_amomax_w_rl_mem
    T_AMO_VAL amomax.w.aqrl, 4, 0, 0x00000001, 0xffffffffffffffff, 0x00000001, 0x00000001, str_amomax_w_aqrl_rd, str_amomax_w_aqrl_mem
    T_AMO_VAL amominu.w.aq, 4, 0, 0x00000001, 0xffffffffffffffff, 0x00000001, 0x00000001, str_amominu_w_aq_rd, str_amominu_w_aq_mem
    T_AMO_VAL amominu.w.rl, 4, 0, 0x00000001, 0xffffffffffffffff, 0x00000001, 0x00000001, str_amominu_w_rl_rd, str_amominu_w_rl_mem
    T_AMO_VAL amominu.w.aqrl, 4, 0, 0x00000001, 0xffffffffffffffff, 0x00000001, 0x00000001, str_amominu_w_aqrl_rd, str_amominu_w_aqrl_mem
    T_AMO_VAL amomaxu.w.aq, 4, 0, 0x00000001, 0xffffffffffffffff, 0x00000001, 0xffffffff, str_amomaxu_w_aq_rd, str_amomaxu_w_aq_mem
    T_AMO_VAL amomaxu.w.rl, 4, 0, 0x00000001, 0xffffffffffffffff, 0x00000001, 0xffffffff, str_amomaxu_w_rl_rd, str_amomaxu_w_rl_mem
    T_AMO_VAL amomaxu.w.aqrl, 4, 0, 0x00000001, 0xffffffffffffffff, 0x00000001, 0xffffffff, str_amomaxu_w_aqrl_rd, str_amomaxu_w_aqrl_mem

    /* ----- RV64: the .W forms use only rs2[31:0] ----- */
    .if XLEN == 64
    T_AMO_VAL amoswap.w, 4, 0, 0x11111111, 0xdeadbeef22222222, 0x11111111, 0x22222222, str_amoswap_w_garbage_rd, str_amoswap_w_garbage_mem
    T_AMO_VAL amoadd.w, 4, 0, 0x00000005, 0xdeadbeef00000007, 0x00000005, 0x0000000c, str_amoadd_w_garbage_rd, str_amoadd_w_garbage_mem
    T_AMO_VAL amoxor.w, 4, 0, 0x00000000, 0xffffffff00000000, 0x00000000, 0x00000000, str_amoxor_w_garbage_rd, str_amoxor_w_garbage_mem
    T_AMO_VAL amoand.w, 4, 0, 0xffffffff, 0x123456780000ffff, 0xffffffffffffffff, 0x0000ffff, str_amoand_w_garbage_rd, str_amoand_w_garbage_mem
    T_AMO_VAL amoor.w, 4, 0, 0x00000000, 0xffffffff00000001, 0x00000000, 0x00000001, str_amoor_w_garbage_rd, str_amoor_w_garbage_mem
    T_AMO_VAL amomin.w, 4, 0, 0x00000001, 0x00000001ffffffff, 0x00000001, 0xffffffff, str_amomin_w_garbage_rd, str_amomin_w_garbage_mem
    T_AMO_VAL amomax.w, 4, 0, 0xffffffff, 0xffffffff00000000, 0xffffffffffffffff, 0x00000000, str_amomax_w_garbage_rd, str_amomax_w_garbage_mem
    T_AMO_VAL amominu.w, 4, 0, 0x80000000, 0xffffffff00000001, 0xffffffff80000000, 0x00000001, str_amominu_w_garbage_rd, str_amominu_w_garbage_mem
    T_AMO_VAL amomaxu.w, 4, 0, 0x00000001, 0x0000000100000000, 0x00000001, 0x00000001, str_amomaxu_w_garbage_rd, str_amomaxu_w_garbage_mem
    .endif

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  .D values (RV64 only)
 * ======================================================================= */
    .if XLEN == 64
test_amo_d:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    /* ----- AMOSWAP.D ----- */
    T_AMO_VAL amoswap.d, 8, 0, 0x0123456789abcdef, 0xfedcba9876543210, 0x0123456789abcdef, 0xfedcba9876543210, str_amoswap_d_basic_rd, str_amoswap_d_basic_mem
    T_AMO_VAL amoswap.d, 8, 0, 0x8000000000000000, 0x00000000, 0x8000000000000000, 0x00000000, str_amoswap_d_zero_rd, str_amoswap_d_zero_mem

    /* ----- AMOADD.D ----- */
    T_AMO_VAL amoadd.d, 8, 0, 0xffffffff, 0x00000001, 0xffffffff, 0x0000000100000000, str_amoadd_d_carry32_rd, str_amoadd_d_carry32_mem
    T_AMO_VAL amoadd.d, 8, 0, 0x7fffffffffffffff, 0x00000001, 0x7fffffffffffffff, 0x8000000000000000, str_amoadd_d_ovf_rd, str_amoadd_d_ovf_mem
    T_AMO_VAL amoadd.d, 8, 0, 0xffffffffffffffff, 0x00000001, 0xffffffffffffffff, 0x00000000, str_amoadd_d_carry_rd, str_amoadd_d_carry_mem
    T_AMO_VAL amoadd.d, 8, 0, 0x8000000000000000, 0x8000000000000000, 0x8000000000000000, 0x00000000, str_amoadd_d_minmin_rd, str_amoadd_d_minmin_mem

    /* ----- AMOXOR.D ----- */
    T_AMO_VAL amoxor.d, 8, 0, 0xff00ff00ff00ff00, 0x0ff00ff00ff00ff0, 0xff00ff00ff00ff00, 0xf0f0f0f0f0f0f0f0, str_amoxor_d_basic_rd, str_amoxor_d_basic_mem
    T_AMO_VAL amoxor.d, 8, 0, 0x8000000000000000, 0xffffffffffffffff, 0x8000000000000000, 0x7fffffffffffffff, str_amoxor_d_flip_rd, str_amoxor_d_flip_mem

    /* ----- AMOAND.D ----- */
    T_AMO_VAL amoand.d, 8, 0, 0xff00ff00ff00ff00, 0x0ff00ff00ff00ff0, 0xff00ff00ff00ff00, 0x0f000f000f000f00, str_amoand_d_basic_rd, str_amoand_d_basic_mem
    T_AMO_VAL amoand.d, 8, 0, 0x123456789abcdef0, 0x00000000, 0x123456789abcdef0, 0x00000000, str_amoand_d_zero_rd, str_amoand_d_zero_mem

    /* ----- AMOOR.D ----- */
    T_AMO_VAL amoor.d, 8, 0, 0xff00ff00ff00ff00, 0x0ff00ff00ff00ff0, 0xff00ff00ff00ff00, 0xfff0fff0fff0fff0, str_amoor_d_basic_rd, str_amoor_d_basic_mem
    T_AMO_VAL amoor.d, 8, 0, 0x0000000100000000, 0x80000000, 0x0000000100000000, 0x0000000180000000, str_amoor_d_halves_rd, str_amoor_d_halves_mem

    /* ----- AMOMIN.D / AMOMAX.D / AMOMINU.D / AMOMAXU.D ----- */
    T_AMO_VAL amomin.d, 8, 0, 0x00000001, 0xffffffffffffffff, 0x00000001, 0xffffffffffffffff, str_amomin_d_p1m1_rd, str_amomin_d_p1m1_mem
    T_AMO_VAL amomax.d, 8, 0, 0x00000001, 0xffffffffffffffff, 0x00000001, 0x00000001, str_amomax_d_p1m1_rd, str_amomax_d_p1m1_mem
    T_AMO_VAL amominu.d, 8, 0, 0x00000001, 0xffffffffffffffff, 0x00000001, 0x00000001, str_amominu_d_p1m1_rd, str_amominu_d_p1m1_mem
    T_AMO_VAL amomaxu.d, 8, 0, 0x00000001, 0xffffffffffffffff, 0x00000001, 0xffffffffffffffff, str_amomaxu_d_p1m1_rd, str_amomaxu_d_p1m1_mem

    T_AMO_VAL amomin.d, 8, 0, 0x8000000000000000, 0x7fffffffffffffff, 0x8000000000000000, 0x8000000000000000, str_amomin_d_minmax_rd, str_amomin_d_minmax_mem
    T_AMO_VAL amomax.d, 8, 0, 0x8000000000000000, 0x7fffffffffffffff, 0x8000000000000000, 0x7fffffffffffffff, str_amomax_d_minmax_rd, str_amomax_d_minmax_mem
    T_AMO_VAL amominu.d, 8, 0, 0x8000000000000000, 0x7fffffffffffffff, 0x8000000000000000, 0x7fffffffffffffff, str_amominu_d_minmax_rd, str_amominu_d_minmax_mem
    T_AMO_VAL amomaxu.d, 8, 0, 0x8000000000000000, 0x7fffffffffffffff, 0x8000000000000000, 0x8000000000000000, str_amomaxu_d_minmax_rd, str_amomaxu_d_minmax_mem

    T_AMO_VAL amomin.d, 8, 0, 0x7fffffffffffffff, 0x8000000000000000, 0x7fffffffffffffff, 0x8000000000000000, str_amomin_d_maxmin_rd, str_amomin_d_maxmin_mem
    T_AMO_VAL amomax.d, 8, 0, 0x7fffffffffffffff, 0x8000000000000000, 0x7fffffffffffffff, 0x7fffffffffffffff, str_amomax_d_maxmin_rd, str_amomax_d_maxmin_mem
    T_AMO_VAL amominu.d, 8, 0, 0x7fffffffffffffff, 0x8000000000000000, 0x7fffffffffffffff, 0x7fffffffffffffff, str_amominu_d_maxmin_rd, str_amominu_d_maxmin_mem
    T_AMO_VAL amomaxu.d, 8, 0, 0x7fffffffffffffff, 0x8000000000000000, 0x7fffffffffffffff, 0x8000000000000000, str_amomaxu_d_maxmin_rd, str_amomaxu_d_maxmin_mem

    T_AMO_VAL amomin.d, 8, 0, 0xfffffffffffffffe, 0xffffffffffffffff, 0xfffffffffffffffe, 0xfffffffffffffffe, str_amomin_d_m2m1_rd, str_amomin_d_m2m1_mem
    T_AMO_VAL amomax.d, 8, 0, 0xfffffffffffffffe, 0xffffffffffffffff, 0xfffffffffffffffe, 0xffffffffffffffff, str_amomax_d_m2m1_rd, str_amomax_d_m2m1_mem
    T_AMO_VAL amominu.d, 8, 0, 0xfffffffffffffffe, 0xffffffffffffffff, 0xfffffffffffffffe, 0xfffffffffffffffe, str_amominu_d_m2m1_rd, str_amominu_d_m2m1_mem
    T_AMO_VAL amomaxu.d, 8, 0, 0xfffffffffffffffe, 0xffffffffffffffff, 0xfffffffffffffffe, 0xffffffffffffffff, str_amomaxu_d_m2m1_rd, str_amomaxu_d_m2m1_mem

    T_AMO_VAL amomin.d, 8, 0, 0x0000000100000000, 0x00000001, 0x0000000100000000, 0x00000001, str_amomin_d_hi_rd, str_amomin_d_hi_mem
    T_AMO_VAL amomax.d, 8, 0, 0x0000000100000000, 0x00000001, 0x0000000100000000, 0x0000000100000000, str_amomax_d_hi_rd, str_amomax_d_hi_mem
    T_AMO_VAL amominu.d, 8, 0, 0x0000000100000000, 0x00000001, 0x0000000100000000, 0x00000001, str_amominu_d_hi_rd, str_amominu_d_hi_mem
    T_AMO_VAL amomaxu.d, 8, 0, 0x0000000100000000, 0x00000001, 0x0000000100000000, 0x0000000100000000, str_amomaxu_d_hi_rd, str_amomaxu_d_hi_mem

    T_AMO_VAL amomin.d, 8, 0, 0xffffffff, 0x00000000, 0xffffffff, 0x00000000, str_amomin_d_lo_rd, str_amomin_d_lo_mem
    T_AMO_VAL amomax.d, 8, 0, 0xffffffff, 0x00000000, 0xffffffff, 0xffffffff, str_amomax_d_lo_rd, str_amomax_d_lo_mem
    T_AMO_VAL amominu.d, 8, 0, 0xffffffff, 0x00000000, 0xffffffff, 0x00000000, str_amominu_d_lo_rd, str_amominu_d_lo_mem
    T_AMO_VAL amomaxu.d, 8, 0, 0xffffffff, 0x00000000, 0xffffffff, 0xffffffff, str_amomaxu_d_lo_rd, str_amomaxu_d_lo_mem

    T_AMO_VAL amomin.d, 8, 0, 0x00000005, 0x00000005, 0x00000005, 0x00000005, str_amomin_d_eq_rd, str_amomin_d_eq_mem
    T_AMO_VAL amomax.d, 8, 0, 0x00000005, 0x00000005, 0x00000005, 0x00000005, str_amomax_d_eq_rd, str_amomax_d_eq_mem
    T_AMO_VAL amominu.d, 8, 0, 0x00000005, 0x00000005, 0x00000005, 0x00000005, str_amominu_d_eq_rd, str_amominu_d_eq_mem
    T_AMO_VAL amomaxu.d, 8, 0, 0x00000005, 0x00000005, 0x00000005, 0x00000005, str_amomaxu_d_eq_rd, str_amomaxu_d_eq_mem

    /* ----- ordering bits ----- */
    T_AMO_VAL amoswap.d.aq, 8, 0, 0x0123456789abcdef, 0xfedcba9876543210, 0x0123456789abcdef, 0xfedcba9876543210, str_amoswap_d_aq_rd, str_amoswap_d_aq_mem
    T_AMO_VAL amoswap.d.rl, 8, 0, 0x0123456789abcdef, 0xfedcba9876543210, 0x0123456789abcdef, 0xfedcba9876543210, str_amoswap_d_rl_rd, str_amoswap_d_rl_mem
    T_AMO_VAL amoswap.d.aqrl, 8, 0, 0x0123456789abcdef, 0xfedcba9876543210, 0x0123456789abcdef, 0xfedcba9876543210, str_amoswap_d_aqrl_rd, str_amoswap_d_aqrl_mem
    T_AMO_VAL amoadd.d.aq, 8, 0, 0xffffffff, 0x00000001, 0xffffffff, 0x0000000100000000, str_amoadd_d_aq_rd, str_amoadd_d_aq_mem
    T_AMO_VAL amoadd.d.rl, 8, 0, 0xffffffff, 0x00000001, 0xffffffff, 0x0000000100000000, str_amoadd_d_rl_rd, str_amoadd_d_rl_mem
    T_AMO_VAL amoadd.d.aqrl, 8, 0, 0xffffffff, 0x00000001, 0xffffffff, 0x0000000100000000, str_amoadd_d_aqrl_rd, str_amoadd_d_aqrl_mem
    T_AMO_VAL amoxor.d.aq, 8, 0, 0xff00ff00ff00ff00, 0x0ff00ff00ff00ff0, 0xff00ff00ff00ff00, 0xf0f0f0f0f0f0f0f0, str_amoxor_d_aq_rd, str_amoxor_d_aq_mem
    T_AMO_VAL amoxor.d.rl, 8, 0, 0xff00ff00ff00ff00, 0x0ff00ff00ff00ff0, 0xff00ff00ff00ff00, 0xf0f0f0f0f0f0f0f0, str_amoxor_d_rl_rd, str_amoxor_d_rl_mem
    T_AMO_VAL amoxor.d.aqrl, 8, 0, 0xff00ff00ff00ff00, 0x0ff00ff00ff00ff0, 0xff00ff00ff00ff00, 0xf0f0f0f0f0f0f0f0, str_amoxor_d_aqrl_rd, str_amoxor_d_aqrl_mem
    T_AMO_VAL amoand.d.aq, 8, 0, 0xff00ff00ff00ff00, 0x0ff00ff00ff00ff0, 0xff00ff00ff00ff00, 0x0f000f000f000f00, str_amoand_d_aq_rd, str_amoand_d_aq_mem
    T_AMO_VAL amoand.d.rl, 8, 0, 0xff00ff00ff00ff00, 0x0ff00ff00ff00ff0, 0xff00ff00ff00ff00, 0x0f000f000f000f00, str_amoand_d_rl_rd, str_amoand_d_rl_mem
    T_AMO_VAL amoand.d.aqrl, 8, 0, 0xff00ff00ff00ff00, 0x0ff00ff00ff00ff0, 0xff00ff00ff00ff00, 0x0f000f000f000f00, str_amoand_d_aqrl_rd, str_amoand_d_aqrl_mem
    T_AMO_VAL amoor.d.aq, 8, 0, 0xff00ff00ff00ff00, 0x0ff00ff00ff00ff0, 0xff00ff00ff00ff00, 0xfff0fff0fff0fff0, str_amoor_d_aq_rd, str_amoor_d_aq_mem
    T_AMO_VAL amoor.d.rl, 8, 0, 0xff00ff00ff00ff00, 0x0ff00ff00ff00ff0, 0xff00ff00ff00ff00, 0xfff0fff0fff0fff0, str_amoor_d_rl_rd, str_amoor_d_rl_mem
    T_AMO_VAL amoor.d.aqrl, 8, 0, 0xff00ff00ff00ff00, 0x0ff00ff00ff00ff0, 0xff00ff00ff00ff00, 0xfff0fff0fff0fff0, str_amoor_d_aqrl_rd, str_amoor_d_aqrl_mem
    T_AMO_VAL amomin.d.aq, 8, 0, 0x00000001, 0xffffffffffffffff, 0x00000001, 0xffffffffffffffff, str_amomin_d_aq_rd, str_amomin_d_aq_mem
    T_AMO_VAL amomin.d.rl, 8, 0, 0x00000001, 0xffffffffffffffff, 0x00000001, 0xffffffffffffffff, str_amomin_d_rl_rd, str_amomin_d_rl_mem
    T_AMO_VAL amomin.d.aqrl, 8, 0, 0x00000001, 0xffffffffffffffff, 0x00000001, 0xffffffffffffffff, str_amomin_d_aqrl_rd, str_amomin_d_aqrl_mem
    T_AMO_VAL amomax.d.aq, 8, 0, 0x00000001, 0xffffffffffffffff, 0x00000001, 0x00000001, str_amomax_d_aq_rd, str_amomax_d_aq_mem
    T_AMO_VAL amomax.d.rl, 8, 0, 0x00000001, 0xffffffffffffffff, 0x00000001, 0x00000001, str_amomax_d_rl_rd, str_amomax_d_rl_mem
    T_AMO_VAL amomax.d.aqrl, 8, 0, 0x00000001, 0xffffffffffffffff, 0x00000001, 0x00000001, str_amomax_d_aqrl_rd, str_amomax_d_aqrl_mem
    T_AMO_VAL amominu.d.aq, 8, 0, 0x00000001, 0xffffffffffffffff, 0x00000001, 0x00000001, str_amominu_d_aq_rd, str_amominu_d_aq_mem
    T_AMO_VAL amominu.d.rl, 8, 0, 0x00000001, 0xffffffffffffffff, 0x00000001, 0x00000001, str_amominu_d_rl_rd, str_amominu_d_rl_mem
    T_AMO_VAL amominu.d.aqrl, 8, 0, 0x00000001, 0xffffffffffffffff, 0x00000001, 0x00000001, str_amominu_d_aqrl_rd, str_amominu_d_aqrl_mem
    T_AMO_VAL amomaxu.d.aq, 8, 0, 0x00000001, 0xffffffffffffffff, 0x00000001, 0xffffffffffffffff, str_amomaxu_d_aq_rd, str_amomaxu_d_aq_mem
    T_AMO_VAL amomaxu.d.rl, 8, 0, 0x00000001, 0xffffffffffffffff, 0x00000001, 0xffffffffffffffff, str_amomaxu_d_rl_rd, str_amomaxu_d_rl_mem
    T_AMO_VAL amomaxu.d.aqrl, 8, 0, 0x00000001, 0xffffffffffffffff, 0x00000001, 0xffffffffffffffff, str_amomaxu_d_aqrl_rd, str_amomaxu_d_aqrl_mem

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret
    .endif

/* =======================================================================
 *  Neighbouring words untouched. rs2 per operation: the value that,
 *  with the operation done 64 bits wide on the doubleword instead,
 *  would change the other word -- all ones above bit 31 for the ops
 *  that keep 1s or pick the smaller signed value, zero above bit 31
 *  for AND and MINU, INT64_MAX-ish for MAX. The .W forms run at both
 *  word offsets of the doubleword.
 * ======================================================================= */
test_amo_neigh:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    .irp off, 0, 4
    T_AMO_NEIGH amoswap.w, 4, \off, 0xffffffff80000001, str_amoswap_w_neigh_\off
    T_AMO_NEIGH amoadd.w,  4, \off, 0xffffffffc0000001, str_amoadd_w_neigh_\off
    T_AMO_NEIGH amoxor.w,  4, \off, 0xffffffff80000001, str_amoxor_w_neigh_\off
    T_AMO_NEIGH amoand.w,  4, \off, 0x0000000080000001, str_amoand_w_neigh_\off
    T_AMO_NEIGH amoor.w,   4, \off, 0xffffffff80000001, str_amoor_w_neigh_\off
    T_AMO_NEIGH amomin.w,  4, \off, 0xffffffff80000001, str_amomin_w_neigh_\off
    T_AMO_NEIGH amomax.w,  4, \off, 0x7fffffff80000001, str_amomax_w_neigh_\off
    T_AMO_NEIGH amominu.w, 4, \off, 0x0000000080000001, str_amominu_w_neigh_\off
    T_AMO_NEIGH amomaxu.w, 4, \off, 0xffffffff80000001, str_amomaxu_w_neigh_\off
    .endr

    .if XLEN == 64
    T_AMO_NEIGH amoswap.d, 8, 0, 0xffffffff80000001, str_amoswap_d_neigh
    T_AMO_NEIGH amoadd.d,  8, 0, 0xffffffffc0000001, str_amoadd_d_neigh
    T_AMO_NEIGH amoxor.d,  8, 0, 0xffffffff80000001, str_amoxor_d_neigh
    T_AMO_NEIGH amoand.d,  8, 0, 0x0000000080000001, str_amoand_d_neigh
    T_AMO_NEIGH amoor.d,   8, 0, 0xffffffff80000001, str_amoor_d_neigh
    T_AMO_NEIGH amomin.d,  8, 0, 0xffffffff80000001, str_amomin_d_neigh
    T_AMO_NEIGH amomax.d,  8, 0, 0x7fffffff80000001, str_amomax_d_neigh
    T_AMO_NEIGH amominu.d, 8, 0, 0x0000000080000001, str_amominu_d_neigh
    T_AMO_NEIGH amomaxu.d, 8, 0, 0xffffffff80000001, str_amomaxu_d_neigh
    .endif

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* Bit independence across fields -- see the file header, BX_C_AMO and
 * bitx.inc. The aq/rl field is the 2-bit "immediate" (0x1 = rl,
 * 0x2 = aq), background 0. Pool: va = rs2, vb = the old memory value.
 * The old value has bit 31 set (so .W's sign extension is exercised)
 * and the two are ordered so that MIN/MAX/MINU/MAXU all pick
 * differently; on RV64 the .W rs2 also carries garbage above bit 31. */
bitx_a_amo:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    BX_POOL 0xdeadbeef12345678, 0x3c3c3c3cc3b4a596
    BX_E_RRRI5 BX_C_AMO, "amoswap.w, 4, AMOSWAP.W", "0x1,0x2", 0
    BX_E_RRRI5 BX_C_AMO, "amoadd.w, 4, AMOADD.W", "0x1,0x2", 0
    BX_E_RRRI5 BX_C_AMO, "amoxor.w, 4, AMOXOR.W", "0x1,0x2", 0
    BX_E_RRRI5 BX_C_AMO, "amoand.w, 4, AMOAND.W", "0x1,0x2", 0
    BX_E_RRRI5 BX_C_AMO, "amoor.w, 4, AMOOR.W", "0x1,0x2", 0
    BX_E_RRRI5 BX_C_AMO, "amomin.w, 4, AMOMIN.W", "0x1,0x2", 0
    BX_E_RRRI5 BX_C_AMO, "amomax.w, 4, AMOMAX.W", "0x1,0x2", 0
    BX_E_RRRI5 BX_C_AMO, "amominu.w, 4, AMOMINU.W", "0x1,0x2", 0
    BX_E_RRRI5 BX_C_AMO, "amomaxu.w, 4, AMOMAXU.W", "0x1,0x2", 0

    .if XLEN == 64
    BX_POOL 0x0fedcba987654321, 0x8123456789abcdef
    BX_E_RRRI5 BX_C_AMO, "amoswap.d, 8, AMOSWAP.D", "0x1,0x2", 0
    BX_E_RRRI5 BX_C_AMO, "amoadd.d, 8, AMOADD.D", "0x1,0x2", 0
    BX_E_RRRI5 BX_C_AMO, "amoxor.d, 8, AMOXOR.D", "0x1,0x2", 0
    BX_E_RRRI5 BX_C_AMO, "amoand.d, 8, AMOAND.D", "0x1,0x2", 0
    BX_E_RRRI5 BX_C_AMO, "amoor.d, 8, AMOOR.D", "0x1,0x2", 0
    BX_E_RRRI5 BX_C_AMO, "amomin.d, 8, AMOMIN.D", "0x1,0x2", 0
    BX_E_RRRI5 BX_C_AMO, "amomax.d, 8, AMOMAX.D", "0x1,0x2", 0
    BX_E_RRRI5 BX_C_AMO, "amominu.d, 8, AMOMINU.D", "0x1,0x2", 0
    BX_E_RRRI5 BX_C_AMO, "amomaxu.d, 8, AMOMAXU.D", "0x1,0x2", 0
    .endif

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  Strings
 * ======================================================================= */
    .section .rodata
str_amo_rd_ra:  .asciz "AMOADD.W rd=ra(x1) (AMO format)"
str_amo_rd_t0:  .asciz "AMOADD.W rd=t0(x5) (AMO format)"
str_amo_rd_s0:  .asciz "AMOADD.W rd=s0(x8) (AMO format)"
str_amo_rd_a0:  .asciz "AMOADD.W rd=a0(x10) (AMO format)"
str_amo_rd_s10: .asciz "AMOADD.W rd=s10(x26) (AMO format)"
str_amo_rd_t6:  .asciz "AMOADD.W rd=t6(x31) (AMO format)"
str_amo_rs1_ra:  .asciz "AMOADD.W rs1=ra(x1) (AMO format)"
str_amo_rs1_t0:  .asciz "AMOADD.W rs1=t0(x5) (AMO format)"
str_amo_rs1_s0:  .asciz "AMOADD.W rs1=s0(x8) (AMO format)"
str_amo_rs1_a0:  .asciz "AMOADD.W rs1=a0(x10) (AMO format)"
str_amo_rs1_s10: .asciz "AMOADD.W rs1=s10(x26) (AMO format)"
str_amo_rs1_t6:  .asciz "AMOADD.W rs1=t6(x31) (AMO format)"
str_amo_rs2_ra:  .asciz "AMOADD.W rs2=ra(x1) (AMO format)"
str_amo_rs2_t0:  .asciz "AMOADD.W rs2=t0(x5) (AMO format)"
str_amo_rs2_s0:  .asciz "AMOADD.W rs2=s0(x8) (AMO format)"
str_amo_rs2_a0:  .asciz "AMOADD.W rs2=a0(x10) (AMO format)"
str_amo_rs2_s10: .asciz "AMOADD.W rs2=s10(x26) (AMO format)"
str_amo_rs2_t6:  .asciz "AMOADD.W rs2=t6(x31) (AMO format)"
str_amo_rs1_sp_rd:  .asciz "AMOADD.W rs1=sp(x2) (AMO format): rd = old value"
str_amo_rs1_sp_mem: .asciz "AMOADD.W rs1=sp(x2) (AMO format): memory"
str_amo_rd_x0: .asciz "AMOADD.W rd=x0 still updates memory (AMO format)"
str_amoswap_rs2_x0_rd:  .asciz "AMOSWAP.W rs2=x0: rd = old value"
str_amoswap_rs2_x0_mem: .asciz "AMOSWAP.W rs2=x0: memory = 0"
str_amoor_rs2_x0_rd:    .asciz "AMOOR.W rs2=x0 (atomic load): rd = old value, sign-extended"
str_amoor_rs2_x0_mem:   .asciz "AMOOR.W rs2=x0 (atomic load): memory unchanged"
str_amoswap_rd_rs2_rd:  .asciz "AMOSWAP.W rd==rs2 swaps reg and memory: rd = old memory"
str_amoswap_rd_rs2_mem: .asciz "AMOSWAP.W rd==rs2 swaps reg and memory: memory = old rs2"
str_amo_alias_rd_rs2_rd:  .asciz "AMOADD.W rd==rs2 (AMO format): rd = old value"
str_amo_alias_rd_rs2_mem: .asciz "AMOADD.W rd==rs2 (AMO format): memory = old + old rs2"
str_amo_alias_rd_rs1_rd:  .asciz "AMOADD.W rd==rs1 (AMO format): rd = old value"
str_amo_alias_rd_rs1_mem: .asciz "AMOADD.W rd==rs1 (AMO format): memory at the old rs1"
    .if XLEN == 64
str_amo_alias_rs1_rs2_rd:  .asciz "AMOSWAP.D rs1==rs2: rd = old value"
str_amo_alias_rs1_rs2_mem: .asciz "AMOSWAP.D rs1==rs2: memory = its own address"
str_amo_alias_all_same_rd:  .asciz "AMOSWAP.D rd==rs1==rs2: rd = old value"
str_amo_alias_all_same_mem: .asciz "AMOSWAP.D rd==rs1==rs2: memory = its own address"
    .else
str_amo_alias_rs1_rs2_rd:  .asciz "AMOSWAP.W rs1==rs2: rd = old value"
str_amo_alias_rs1_rs2_mem: .asciz "AMOSWAP.W rs1==rs2: memory = its own address"
str_amo_alias_all_same_rd:  .asciz "AMOSWAP.W rd==rs1==rs2: rd = old value"
str_amo_alias_all_same_mem: .asciz "AMOSWAP.W rd==rs1==rs2: memory = its own address"
    .endif
str_amo_alias_rs1_rs2_add_rd:  .asciz "AMOADD.W rs1==rs2: rd = old value"
str_amo_alias_rs1_rs2_add_mem: .asciz "AMOADD.W rs1==rs2: memory = old + address"
str_amo_rs1_preserved: .asciz "AMOADD.W rs1 unmodified (AMO format)"
str_amo_rs2_preserved: .asciz "AMOADD.W rs2 unmodified (AMO format)"

str_amoswap_w_basic_rd:  .asciz "AMOSWAP.W basic swap: rd = old value"
str_amoswap_w_basic_mem: .asciz "AMOSWAP.W basic swap: memory"
str_amoswap_w_sext_rd:  .asciz "AMOSWAP.W old word 0x80000000 (rd sign-extends bit 31): rd = old value"
str_amoswap_w_sext_mem: .asciz "AMOSWAP.W old word 0x80000000 (rd sign-extends bit 31): memory"
str_amoswap_w_zero_rd:  .asciz "AMOSWAP.W stores 0, old word all ones: rd = old value"
str_amoswap_w_zero_mem: .asciz "AMOSWAP.W stores 0, old word all ones: memory"
str_amoadd_w_basic_rd:  .asciz "AMOADD.W 5+7: rd = old value"
str_amoadd_w_basic_mem: .asciz "AMOADD.W 5+7: memory"
str_amoadd_w_ovf_rd:  .asciz "AMOADD.W 0x7fffffff+1 wraps to 0x80000000: rd = old value"
str_amoadd_w_ovf_mem: .asciz "AMOADD.W 0x7fffffff+1 wraps to 0x80000000: memory"
str_amoadd_w_carry_rd:  .asciz "AMOADD.W 0xffffffff+1 = 0 (carry out of bit 31 dropped): rd = old value"
str_amoadd_w_carry_mem: .asciz "AMOADD.W 0xffffffff+1 = 0 (carry out of bit 31 dropped): memory"
str_amoadd_w_minmin_rd:  .asciz "AMOADD.W 0x80000000+0x80000000 = 0: rd = old value"
str_amoadd_w_minmin_mem: .asciz "AMOADD.W 0x80000000+0x80000000 = 0: memory"
str_amoadd_w_neg_rd:  .asciz "AMOADD.W 1+(-1) = 0: rd = old value"
str_amoadd_w_neg_mem: .asciz "AMOADD.W 1+(-1) = 0: memory"
str_amoxor_w_basic_rd:  .asciz "AMOXOR.W 0xff00ff00^0x0ff00ff0: rd = old value"
str_amoxor_w_basic_mem: .asciz "AMOXOR.W 0xff00ff00^0x0ff00ff0: memory"
str_amoxor_w_self_rd:  .asciz "AMOXOR.W x^x = 0: rd = old value"
str_amoxor_w_self_mem: .asciz "AMOXOR.W x^x = 0: memory"
str_amoxor_w_flip_rd:  .asciz "AMOXOR.W 0x80000000^0xffffffff = 0x7fffffff: rd = old value"
str_amoxor_w_flip_mem: .asciz "AMOXOR.W 0x80000000^0xffffffff = 0x7fffffff: memory"
str_amoand_w_basic_rd:  .asciz "AMOAND.W 0xff00ff00&0x0ff00ff0: rd = old value"
str_amoand_w_basic_mem: .asciz "AMOAND.W 0xff00ff00&0x0ff00ff0: memory"
str_amoand_w_zero_rd:  .asciz "AMOAND.W x&0 = 0: rd = old value"
str_amoand_w_zero_mem: .asciz "AMOAND.W x&0 = 0: memory"
str_amoand_w_ones_rd:  .asciz "AMOAND.W x&0xffffffff = x: rd = old value"
str_amoand_w_ones_mem: .asciz "AMOAND.W x&0xffffffff = x: memory"
str_amoor_w_basic_rd:  .asciz "AMOOR.W 0xff00ff00|0x0ff00ff0: rd = old value"
str_amoor_w_basic_mem: .asciz "AMOOR.W 0xff00ff00|0x0ff00ff0: memory"
str_amoor_w_bit31_rd:  .asciz "AMOOR.W 0|0x80000000: rd = old value"
str_amoor_w_bit31_mem: .asciz "AMOOR.W 0|0x80000000: memory"
str_amoor_w_zero_rd:  .asciz "AMOOR.W x|0 = x: rd = old value"
str_amoor_w_zero_mem: .asciz "AMOOR.W x|0 = x: memory"
str_amomin_w_p1m1_rd:  .asciz "AMOMIN.W (1, -1) DIVERGES: rd = old value"
str_amomin_w_p1m1_mem: .asciz "AMOMIN.W (1, -1) DIVERGES: memory"
str_amomax_w_p1m1_rd:  .asciz "AMOMAX.W (1, -1) DIVERGES: rd = old value"
str_amomax_w_p1m1_mem: .asciz "AMOMAX.W (1, -1) DIVERGES: memory"
str_amominu_w_p1m1_rd:  .asciz "AMOMINU.W (1, -1) DIVERGES: rd = old value"
str_amominu_w_p1m1_mem: .asciz "AMOMINU.W (1, -1) DIVERGES: memory"
str_amomaxu_w_p1m1_rd:  .asciz "AMOMAXU.W (1, -1) DIVERGES: rd = old value"
str_amomaxu_w_p1m1_mem: .asciz "AMOMAXU.W (1, -1) DIVERGES: memory"
str_amomin_w_minmax_rd:  .asciz "AMOMIN.W (0x80000000, 0x7fffffff) DIVERGES: rd = old value"
str_amomin_w_minmax_mem: .asciz "AMOMIN.W (0x80000000, 0x7fffffff) DIVERGES: memory"
str_amomax_w_minmax_rd:  .asciz "AMOMAX.W (0x80000000, 0x7fffffff) DIVERGES: rd = old value"
str_amomax_w_minmax_mem: .asciz "AMOMAX.W (0x80000000, 0x7fffffff) DIVERGES: memory"
str_amominu_w_minmax_rd:  .asciz "AMOMINU.W (0x80000000, 0x7fffffff) DIVERGES: rd = old value"
str_amominu_w_minmax_mem: .asciz "AMOMINU.W (0x80000000, 0x7fffffff) DIVERGES: memory"
str_amomaxu_w_minmax_rd:  .asciz "AMOMAXU.W (0x80000000, 0x7fffffff) DIVERGES: rd = old value"
str_amomaxu_w_minmax_mem: .asciz "AMOMAXU.W (0x80000000, 0x7fffffff) DIVERGES: memory"
str_amomin_w_maxmin_rd:  .asciz "AMOMIN.W (0x7fffffff, 0x80000000) DIVERGES: rd = old value"
str_amomin_w_maxmin_mem: .asciz "AMOMIN.W (0x7fffffff, 0x80000000) DIVERGES: memory"
str_amomax_w_maxmin_rd:  .asciz "AMOMAX.W (0x7fffffff, 0x80000000) DIVERGES: rd = old value"
str_amomax_w_maxmin_mem: .asciz "AMOMAX.W (0x7fffffff, 0x80000000) DIVERGES: memory"
str_amominu_w_maxmin_rd:  .asciz "AMOMINU.W (0x7fffffff, 0x80000000) DIVERGES: rd = old value"
str_amominu_w_maxmin_mem: .asciz "AMOMINU.W (0x7fffffff, 0x80000000) DIVERGES: memory"
str_amomaxu_w_maxmin_rd:  .asciz "AMOMAXU.W (0x7fffffff, 0x80000000) DIVERGES: rd = old value"
str_amomaxu_w_maxmin_mem: .asciz "AMOMAXU.W (0x7fffffff, 0x80000000) DIVERGES: memory"
str_amomin_w_m2m1_rd:  .asciz "AMOMIN.W (-2, -1): rd = old value"
str_amomin_w_m2m1_mem: .asciz "AMOMIN.W (-2, -1): memory"
str_amomax_w_m2m1_rd:  .asciz "AMOMAX.W (-2, -1): rd = old value"
str_amomax_w_m2m1_mem: .asciz "AMOMAX.W (-2, -1): memory"
str_amominu_w_m2m1_rd:  .asciz "AMOMINU.W (-2, -1): rd = old value"
str_amominu_w_m2m1_mem: .asciz "AMOMINU.W (-2, -1): memory"
str_amomaxu_w_m2m1_rd:  .asciz "AMOMAXU.W (-2, -1): rd = old value"
str_amomaxu_w_m2m1_mem: .asciz "AMOMAXU.W (-2, -1): memory"
str_amomin_w_p3p7_rd:  .asciz "AMOMIN.W (3, 7): rd = old value"
str_amomin_w_p3p7_mem: .asciz "AMOMIN.W (3, 7): memory"
str_amomax_w_p3p7_rd:  .asciz "AMOMAX.W (3, 7): rd = old value"
str_amomax_w_p3p7_mem: .asciz "AMOMAX.W (3, 7): memory"
str_amominu_w_p3p7_rd:  .asciz "AMOMINU.W (3, 7): rd = old value"
str_amominu_w_p3p7_mem: .asciz "AMOMINU.W (3, 7): memory"
str_amomaxu_w_p3p7_rd:  .asciz "AMOMAXU.W (3, 7): rd = old value"
str_amomaxu_w_p3p7_mem: .asciz "AMOMAXU.W (3, 7): memory"
str_amomin_w_eq_rd:  .asciz "AMOMIN.W (5, 5) equal: rd = old value"
str_amomin_w_eq_mem: .asciz "AMOMIN.W (5, 5) equal: memory"
str_amomax_w_eq_rd:  .asciz "AMOMAX.W (5, 5) equal: rd = old value"
str_amomax_w_eq_mem: .asciz "AMOMAX.W (5, 5) equal: memory"
str_amominu_w_eq_rd:  .asciz "AMOMINU.W (5, 5) equal: rd = old value"
str_amominu_w_eq_mem: .asciz "AMOMINU.W (5, 5) equal: memory"
str_amomaxu_w_eq_rd:  .asciz "AMOMAXU.W (5, 5) equal: rd = old value"
str_amomaxu_w_eq_mem: .asciz "AMOMAXU.W (5, 5) equal: memory"
str_amoswap_w_aq_rd:  .asciz "AMOSWAP.W.AQ ordering bits set: rd = old value"
str_amoswap_w_aq_mem: .asciz "AMOSWAP.W.AQ ordering bits set: memory"
str_amoswap_w_rl_rd:  .asciz "AMOSWAP.W.RL ordering bits set: rd = old value"
str_amoswap_w_rl_mem: .asciz "AMOSWAP.W.RL ordering bits set: memory"
str_amoswap_w_aqrl_rd:  .asciz "AMOSWAP.W.AQRL ordering bits set: rd = old value"
str_amoswap_w_aqrl_mem: .asciz "AMOSWAP.W.AQRL ordering bits set: memory"
str_amoadd_w_aq_rd:  .asciz "AMOADD.W.AQ ordering bits set: rd = old value"
str_amoadd_w_aq_mem: .asciz "AMOADD.W.AQ ordering bits set: memory"
str_amoadd_w_rl_rd:  .asciz "AMOADD.W.RL ordering bits set: rd = old value"
str_amoadd_w_rl_mem: .asciz "AMOADD.W.RL ordering bits set: memory"
str_amoadd_w_aqrl_rd:  .asciz "AMOADD.W.AQRL ordering bits set: rd = old value"
str_amoadd_w_aqrl_mem: .asciz "AMOADD.W.AQRL ordering bits set: memory"
str_amoxor_w_aq_rd:  .asciz "AMOXOR.W.AQ ordering bits set: rd = old value"
str_amoxor_w_aq_mem: .asciz "AMOXOR.W.AQ ordering bits set: memory"
str_amoxor_w_rl_rd:  .asciz "AMOXOR.W.RL ordering bits set: rd = old value"
str_amoxor_w_rl_mem: .asciz "AMOXOR.W.RL ordering bits set: memory"
str_amoxor_w_aqrl_rd:  .asciz "AMOXOR.W.AQRL ordering bits set: rd = old value"
str_amoxor_w_aqrl_mem: .asciz "AMOXOR.W.AQRL ordering bits set: memory"
str_amoand_w_aq_rd:  .asciz "AMOAND.W.AQ ordering bits set: rd = old value"
str_amoand_w_aq_mem: .asciz "AMOAND.W.AQ ordering bits set: memory"
str_amoand_w_rl_rd:  .asciz "AMOAND.W.RL ordering bits set: rd = old value"
str_amoand_w_rl_mem: .asciz "AMOAND.W.RL ordering bits set: memory"
str_amoand_w_aqrl_rd:  .asciz "AMOAND.W.AQRL ordering bits set: rd = old value"
str_amoand_w_aqrl_mem: .asciz "AMOAND.W.AQRL ordering bits set: memory"
str_amoor_w_aq_rd:  .asciz "AMOOR.W.AQ ordering bits set: rd = old value"
str_amoor_w_aq_mem: .asciz "AMOOR.W.AQ ordering bits set: memory"
str_amoor_w_rl_rd:  .asciz "AMOOR.W.RL ordering bits set: rd = old value"
str_amoor_w_rl_mem: .asciz "AMOOR.W.RL ordering bits set: memory"
str_amoor_w_aqrl_rd:  .asciz "AMOOR.W.AQRL ordering bits set: rd = old value"
str_amoor_w_aqrl_mem: .asciz "AMOOR.W.AQRL ordering bits set: memory"
str_amomin_w_aq_rd:  .asciz "AMOMIN.W.AQ ordering bits set: rd = old value"
str_amomin_w_aq_mem: .asciz "AMOMIN.W.AQ ordering bits set: memory"
str_amomin_w_rl_rd:  .asciz "AMOMIN.W.RL ordering bits set: rd = old value"
str_amomin_w_rl_mem: .asciz "AMOMIN.W.RL ordering bits set: memory"
str_amomin_w_aqrl_rd:  .asciz "AMOMIN.W.AQRL ordering bits set: rd = old value"
str_amomin_w_aqrl_mem: .asciz "AMOMIN.W.AQRL ordering bits set: memory"
str_amomax_w_aq_rd:  .asciz "AMOMAX.W.AQ ordering bits set: rd = old value"
str_amomax_w_aq_mem: .asciz "AMOMAX.W.AQ ordering bits set: memory"
str_amomax_w_rl_rd:  .asciz "AMOMAX.W.RL ordering bits set: rd = old value"
str_amomax_w_rl_mem: .asciz "AMOMAX.W.RL ordering bits set: memory"
str_amomax_w_aqrl_rd:  .asciz "AMOMAX.W.AQRL ordering bits set: rd = old value"
str_amomax_w_aqrl_mem: .asciz "AMOMAX.W.AQRL ordering bits set: memory"
str_amominu_w_aq_rd:  .asciz "AMOMINU.W.AQ ordering bits set: rd = old value"
str_amominu_w_aq_mem: .asciz "AMOMINU.W.AQ ordering bits set: memory"
str_amominu_w_rl_rd:  .asciz "AMOMINU.W.RL ordering bits set: rd = old value"
str_amominu_w_rl_mem: .asciz "AMOMINU.W.RL ordering bits set: memory"
str_amominu_w_aqrl_rd:  .asciz "AMOMINU.W.AQRL ordering bits set: rd = old value"
str_amominu_w_aqrl_mem: .asciz "AMOMINU.W.AQRL ordering bits set: memory"
str_amomaxu_w_aq_rd:  .asciz "AMOMAXU.W.AQ ordering bits set: rd = old value"
str_amomaxu_w_aq_mem: .asciz "AMOMAXU.W.AQ ordering bits set: memory"
str_amomaxu_w_rl_rd:  .asciz "AMOMAXU.W.RL ordering bits set: rd = old value"
str_amomaxu_w_rl_mem: .asciz "AMOMAXU.W.RL ordering bits set: memory"
str_amomaxu_w_aqrl_rd:  .asciz "AMOMAXU.W.AQRL ordering bits set: rd = old value"
str_amomaxu_w_aqrl_mem: .asciz "AMOMAXU.W.AQRL ordering bits set: memory"
    .if XLEN == 64
str_amoswap_w_garbage_rd:  .asciz "AMOSWAP.W ignores rs2[63:32]: rd = old value"
str_amoswap_w_garbage_mem: .asciz "AMOSWAP.W ignores rs2[63:32]: memory"
str_amoadd_w_garbage_rd:  .asciz "AMOADD.W ignores rs2[63:32]: rd = old value"
str_amoadd_w_garbage_mem: .asciz "AMOADD.W ignores rs2[63:32]: memory"
str_amoxor_w_garbage_rd:  .asciz "AMOXOR.W ignores rs2[63:32]: rd = old value"
str_amoxor_w_garbage_mem: .asciz "AMOXOR.W ignores rs2[63:32]: memory"
str_amoand_w_garbage_rd:  .asciz "AMOAND.W ignores rs2[63:32]: rd = old value"
str_amoand_w_garbage_mem: .asciz "AMOAND.W ignores rs2[63:32]: memory"
str_amoor_w_garbage_rd:  .asciz "AMOOR.W ignores rs2[63:32]: rd = old value"
str_amoor_w_garbage_mem: .asciz "AMOOR.W ignores rs2[63:32]: memory"
str_amomin_w_garbage_rd:  .asciz "AMOMIN.W ignores rs2[63:32]: rd = old value"
str_amomin_w_garbage_mem: .asciz "AMOMIN.W ignores rs2[63:32]: memory"
str_amomax_w_garbage_rd:  .asciz "AMOMAX.W ignores rs2[63:32]: rd = old value"
str_amomax_w_garbage_mem: .asciz "AMOMAX.W ignores rs2[63:32]: memory"
str_amominu_w_garbage_rd:  .asciz "AMOMINU.W ignores rs2[63:32]: rd = old value"
str_amominu_w_garbage_mem: .asciz "AMOMINU.W ignores rs2[63:32]: memory"
str_amomaxu_w_garbage_rd:  .asciz "AMOMAXU.W ignores rs2[63:32]: rd = old value"
str_amomaxu_w_garbage_mem: .asciz "AMOMAXU.W ignores rs2[63:32]: memory"
    .endif

    .if XLEN == 64
str_amoswap_d_basic_rd:  .asciz "AMOSWAP.D basic swap: rd = old value"
str_amoswap_d_basic_mem: .asciz "AMOSWAP.D basic swap: memory"
str_amoswap_d_zero_rd:  .asciz "AMOSWAP.D stores 0, old INT64_MIN: rd = old value"
str_amoswap_d_zero_mem: .asciz "AMOSWAP.D stores 0, old INT64_MIN: memory"
str_amoadd_d_carry32_rd:  .asciz "AMOADD.D 0xffffffff+1 carries into bit 32: rd = old value"
str_amoadd_d_carry32_mem: .asciz "AMOADD.D 0xffffffff+1 carries into bit 32: memory"
str_amoadd_d_ovf_rd:  .asciz "AMOADD.D INT64_MAX+1 wraps to INT64_MIN: rd = old value"
str_amoadd_d_ovf_mem: .asciz "AMOADD.D INT64_MAX+1 wraps to INT64_MIN: memory"
str_amoadd_d_carry_rd:  .asciz "AMOADD.D -1+1 = 0 (carry out of bit 63 dropped): rd = old value"
str_amoadd_d_carry_mem: .asciz "AMOADD.D -1+1 = 0 (carry out of bit 63 dropped): memory"
str_amoadd_d_minmin_rd:  .asciz "AMOADD.D INT64_MIN+INT64_MIN = 0: rd = old value"
str_amoadd_d_minmin_mem: .asciz "AMOADD.D INT64_MIN+INT64_MIN = 0: memory"
str_amoxor_d_basic_rd:  .asciz "AMOXOR.D two 64-bit patterns: rd = old value"
str_amoxor_d_basic_mem: .asciz "AMOXOR.D two 64-bit patterns: memory"
str_amoxor_d_flip_rd:  .asciz "AMOXOR.D INT64_MIN^-1 = INT64_MAX: rd = old value"
str_amoxor_d_flip_mem: .asciz "AMOXOR.D INT64_MIN^-1 = INT64_MAX: memory"
str_amoand_d_basic_rd:  .asciz "AMOAND.D two 64-bit patterns: rd = old value"
str_amoand_d_basic_mem: .asciz "AMOAND.D two 64-bit patterns: memory"
str_amoand_d_zero_rd:  .asciz "AMOAND.D x&0 = 0: rd = old value"
str_amoand_d_zero_mem: .asciz "AMOAND.D x&0 = 0: memory"
str_amoor_d_basic_rd:  .asciz "AMOOR.D two 64-bit patterns: rd = old value"
str_amoor_d_basic_mem: .asciz "AMOOR.D two 64-bit patterns: memory"
str_amoor_d_halves_rd:  .asciz "AMOOR.D bit 32 | bit 31: rd = old value"
str_amoor_d_halves_mem: .asciz "AMOOR.D bit 32 | bit 31: memory"
str_amomin_d_p1m1_rd:  .asciz "AMOMIN.D (1, -1) DIVERGES: rd = old value"
str_amomin_d_p1m1_mem: .asciz "AMOMIN.D (1, -1) DIVERGES: memory"
str_amomax_d_p1m1_rd:  .asciz "AMOMAX.D (1, -1) DIVERGES: rd = old value"
str_amomax_d_p1m1_mem: .asciz "AMOMAX.D (1, -1) DIVERGES: memory"
str_amominu_d_p1m1_rd:  .asciz "AMOMINU.D (1, -1) DIVERGES: rd = old value"
str_amominu_d_p1m1_mem: .asciz "AMOMINU.D (1, -1) DIVERGES: memory"
str_amomaxu_d_p1m1_rd:  .asciz "AMOMAXU.D (1, -1) DIVERGES: rd = old value"
str_amomaxu_d_p1m1_mem: .asciz "AMOMAXU.D (1, -1) DIVERGES: memory"
str_amomin_d_minmax_rd:  .asciz "AMOMIN.D (INT64_MIN, INT64_MAX) DIVERGES: rd = old value"
str_amomin_d_minmax_mem: .asciz "AMOMIN.D (INT64_MIN, INT64_MAX) DIVERGES: memory"
str_amomax_d_minmax_rd:  .asciz "AMOMAX.D (INT64_MIN, INT64_MAX) DIVERGES: rd = old value"
str_amomax_d_minmax_mem: .asciz "AMOMAX.D (INT64_MIN, INT64_MAX) DIVERGES: memory"
str_amominu_d_minmax_rd:  .asciz "AMOMINU.D (INT64_MIN, INT64_MAX) DIVERGES: rd = old value"
str_amominu_d_minmax_mem: .asciz "AMOMINU.D (INT64_MIN, INT64_MAX) DIVERGES: memory"
str_amomaxu_d_minmax_rd:  .asciz "AMOMAXU.D (INT64_MIN, INT64_MAX) DIVERGES: rd = old value"
str_amomaxu_d_minmax_mem: .asciz "AMOMAXU.D (INT64_MIN, INT64_MAX) DIVERGES: memory"
str_amomin_d_maxmin_rd:  .asciz "AMOMIN.D (INT64_MAX, INT64_MIN) DIVERGES: rd = old value"
str_amomin_d_maxmin_mem: .asciz "AMOMIN.D (INT64_MAX, INT64_MIN) DIVERGES: memory"
str_amomax_d_maxmin_rd:  .asciz "AMOMAX.D (INT64_MAX, INT64_MIN) DIVERGES: rd = old value"
str_amomax_d_maxmin_mem: .asciz "AMOMAX.D (INT64_MAX, INT64_MIN) DIVERGES: memory"
str_amominu_d_maxmin_rd:  .asciz "AMOMINU.D (INT64_MAX, INT64_MIN) DIVERGES: rd = old value"
str_amominu_d_maxmin_mem: .asciz "AMOMINU.D (INT64_MAX, INT64_MIN) DIVERGES: memory"
str_amomaxu_d_maxmin_rd:  .asciz "AMOMAXU.D (INT64_MAX, INT64_MIN) DIVERGES: rd = old value"
str_amomaxu_d_maxmin_mem: .asciz "AMOMAXU.D (INT64_MAX, INT64_MIN) DIVERGES: memory"
str_amomin_d_m2m1_rd:  .asciz "AMOMIN.D (-2, -1): rd = old value"
str_amomin_d_m2m1_mem: .asciz "AMOMIN.D (-2, -1): memory"
str_amomax_d_m2m1_rd:  .asciz "AMOMAX.D (-2, -1): rd = old value"
str_amomax_d_m2m1_mem: .asciz "AMOMAX.D (-2, -1): memory"
str_amominu_d_m2m1_rd:  .asciz "AMOMINU.D (-2, -1): rd = old value"
str_amominu_d_m2m1_mem: .asciz "AMOMINU.D (-2, -1): memory"
str_amomaxu_d_m2m1_rd:  .asciz "AMOMAXU.D (-2, -1): rd = old value"
str_amomaxu_d_m2m1_mem: .asciz "AMOMAXU.D (-2, -1): memory"
str_amomin_d_hi_rd:  .asciz "AMOMIN.D (2^32, 1): the upper word decides: rd = old value"
str_amomin_d_hi_mem: .asciz "AMOMIN.D (2^32, 1): the upper word decides: memory"
str_amomax_d_hi_rd:  .asciz "AMOMAX.D (2^32, 1): the upper word decides: rd = old value"
str_amomax_d_hi_mem: .asciz "AMOMAX.D (2^32, 1): the upper word decides: memory"
str_amominu_d_hi_rd:  .asciz "AMOMINU.D (2^32, 1): the upper word decides: rd = old value"
str_amominu_d_hi_mem: .asciz "AMOMINU.D (2^32, 1): the upper word decides: memory"
str_amomaxu_d_hi_rd:  .asciz "AMOMAXU.D (2^32, 1): the upper word decides: rd = old value"
str_amomaxu_d_hi_mem: .asciz "AMOMAXU.D (2^32, 1): the upper word decides: memory"
str_amomin_d_lo_rd:  .asciz "AMOMIN.D (0xffffffff, 0): positive as 64 bits: rd = old value"
str_amomin_d_lo_mem: .asciz "AMOMIN.D (0xffffffff, 0): positive as 64 bits: memory"
str_amomax_d_lo_rd:  .asciz "AMOMAX.D (0xffffffff, 0): positive as 64 bits: rd = old value"
str_amomax_d_lo_mem: .asciz "AMOMAX.D (0xffffffff, 0): positive as 64 bits: memory"
str_amominu_d_lo_rd:  .asciz "AMOMINU.D (0xffffffff, 0): positive as 64 bits: rd = old value"
str_amominu_d_lo_mem: .asciz "AMOMINU.D (0xffffffff, 0): positive as 64 bits: memory"
str_amomaxu_d_lo_rd:  .asciz "AMOMAXU.D (0xffffffff, 0): positive as 64 bits: rd = old value"
str_amomaxu_d_lo_mem: .asciz "AMOMAXU.D (0xffffffff, 0): positive as 64 bits: memory"
str_amomin_d_eq_rd:  .asciz "AMOMIN.D (5, 5) equal: rd = old value"
str_amomin_d_eq_mem: .asciz "AMOMIN.D (5, 5) equal: memory"
str_amomax_d_eq_rd:  .asciz "AMOMAX.D (5, 5) equal: rd = old value"
str_amomax_d_eq_mem: .asciz "AMOMAX.D (5, 5) equal: memory"
str_amominu_d_eq_rd:  .asciz "AMOMINU.D (5, 5) equal: rd = old value"
str_amominu_d_eq_mem: .asciz "AMOMINU.D (5, 5) equal: memory"
str_amomaxu_d_eq_rd:  .asciz "AMOMAXU.D (5, 5) equal: rd = old value"
str_amomaxu_d_eq_mem: .asciz "AMOMAXU.D (5, 5) equal: memory"
str_amoswap_d_aq_rd:  .asciz "AMOSWAP.D.AQ ordering bits set: rd = old value"
str_amoswap_d_aq_mem: .asciz "AMOSWAP.D.AQ ordering bits set: memory"
str_amoswap_d_rl_rd:  .asciz "AMOSWAP.D.RL ordering bits set: rd = old value"
str_amoswap_d_rl_mem: .asciz "AMOSWAP.D.RL ordering bits set: memory"
str_amoswap_d_aqrl_rd:  .asciz "AMOSWAP.D.AQRL ordering bits set: rd = old value"
str_amoswap_d_aqrl_mem: .asciz "AMOSWAP.D.AQRL ordering bits set: memory"
str_amoadd_d_aq_rd:  .asciz "AMOADD.D.AQ ordering bits set: rd = old value"
str_amoadd_d_aq_mem: .asciz "AMOADD.D.AQ ordering bits set: memory"
str_amoadd_d_rl_rd:  .asciz "AMOADD.D.RL ordering bits set: rd = old value"
str_amoadd_d_rl_mem: .asciz "AMOADD.D.RL ordering bits set: memory"
str_amoadd_d_aqrl_rd:  .asciz "AMOADD.D.AQRL ordering bits set: rd = old value"
str_amoadd_d_aqrl_mem: .asciz "AMOADD.D.AQRL ordering bits set: memory"
str_amoxor_d_aq_rd:  .asciz "AMOXOR.D.AQ ordering bits set: rd = old value"
str_amoxor_d_aq_mem: .asciz "AMOXOR.D.AQ ordering bits set: memory"
str_amoxor_d_rl_rd:  .asciz "AMOXOR.D.RL ordering bits set: rd = old value"
str_amoxor_d_rl_mem: .asciz "AMOXOR.D.RL ordering bits set: memory"
str_amoxor_d_aqrl_rd:  .asciz "AMOXOR.D.AQRL ordering bits set: rd = old value"
str_amoxor_d_aqrl_mem: .asciz "AMOXOR.D.AQRL ordering bits set: memory"
str_amoand_d_aq_rd:  .asciz "AMOAND.D.AQ ordering bits set: rd = old value"
str_amoand_d_aq_mem: .asciz "AMOAND.D.AQ ordering bits set: memory"
str_amoand_d_rl_rd:  .asciz "AMOAND.D.RL ordering bits set: rd = old value"
str_amoand_d_rl_mem: .asciz "AMOAND.D.RL ordering bits set: memory"
str_amoand_d_aqrl_rd:  .asciz "AMOAND.D.AQRL ordering bits set: rd = old value"
str_amoand_d_aqrl_mem: .asciz "AMOAND.D.AQRL ordering bits set: memory"
str_amoor_d_aq_rd:  .asciz "AMOOR.D.AQ ordering bits set: rd = old value"
str_amoor_d_aq_mem: .asciz "AMOOR.D.AQ ordering bits set: memory"
str_amoor_d_rl_rd:  .asciz "AMOOR.D.RL ordering bits set: rd = old value"
str_amoor_d_rl_mem: .asciz "AMOOR.D.RL ordering bits set: memory"
str_amoor_d_aqrl_rd:  .asciz "AMOOR.D.AQRL ordering bits set: rd = old value"
str_amoor_d_aqrl_mem: .asciz "AMOOR.D.AQRL ordering bits set: memory"
str_amomin_d_aq_rd:  .asciz "AMOMIN.D.AQ ordering bits set: rd = old value"
str_amomin_d_aq_mem: .asciz "AMOMIN.D.AQ ordering bits set: memory"
str_amomin_d_rl_rd:  .asciz "AMOMIN.D.RL ordering bits set: rd = old value"
str_amomin_d_rl_mem: .asciz "AMOMIN.D.RL ordering bits set: memory"
str_amomin_d_aqrl_rd:  .asciz "AMOMIN.D.AQRL ordering bits set: rd = old value"
str_amomin_d_aqrl_mem: .asciz "AMOMIN.D.AQRL ordering bits set: memory"
str_amomax_d_aq_rd:  .asciz "AMOMAX.D.AQ ordering bits set: rd = old value"
str_amomax_d_aq_mem: .asciz "AMOMAX.D.AQ ordering bits set: memory"
str_amomax_d_rl_rd:  .asciz "AMOMAX.D.RL ordering bits set: rd = old value"
str_amomax_d_rl_mem: .asciz "AMOMAX.D.RL ordering bits set: memory"
str_amomax_d_aqrl_rd:  .asciz "AMOMAX.D.AQRL ordering bits set: rd = old value"
str_amomax_d_aqrl_mem: .asciz "AMOMAX.D.AQRL ordering bits set: memory"
str_amominu_d_aq_rd:  .asciz "AMOMINU.D.AQ ordering bits set: rd = old value"
str_amominu_d_aq_mem: .asciz "AMOMINU.D.AQ ordering bits set: memory"
str_amominu_d_rl_rd:  .asciz "AMOMINU.D.RL ordering bits set: rd = old value"
str_amominu_d_rl_mem: .asciz "AMOMINU.D.RL ordering bits set: memory"
str_amominu_d_aqrl_rd:  .asciz "AMOMINU.D.AQRL ordering bits set: rd = old value"
str_amominu_d_aqrl_mem: .asciz "AMOMINU.D.AQRL ordering bits set: memory"
str_amomaxu_d_aq_rd:  .asciz "AMOMAXU.D.AQ ordering bits set: rd = old value"
str_amomaxu_d_aq_mem: .asciz "AMOMAXU.D.AQ ordering bits set: memory"
str_amomaxu_d_rl_rd:  .asciz "AMOMAXU.D.RL ordering bits set: rd = old value"
str_amomaxu_d_rl_mem: .asciz "AMOMAXU.D.RL ordering bits set: memory"
str_amomaxu_d_aqrl_rd:  .asciz "AMOMAXU.D.AQRL ordering bits set: rd = old value"
str_amomaxu_d_aqrl_mem: .asciz "AMOMAXU.D.AQRL ordering bits set: memory"
    .endif

str_amoswap_w_neigh_0: .asciz "AMOSWAP.W low word: neighbouring words untouched"
str_amoadd_w_neigh_0:  .asciz "AMOADD.W low word: neighbouring words untouched"
str_amoxor_w_neigh_0:  .asciz "AMOXOR.W low word: neighbouring words untouched"
str_amoand_w_neigh_0:  .asciz "AMOAND.W low word: neighbouring words untouched"
str_amoor_w_neigh_0:   .asciz "AMOOR.W low word: neighbouring words untouched"
str_amomin_w_neigh_0:  .asciz "AMOMIN.W low word: neighbouring words untouched"
str_amomax_w_neigh_0:  .asciz "AMOMAX.W low word: neighbouring words untouched"
str_amominu_w_neigh_0: .asciz "AMOMINU.W low word: neighbouring words untouched"
str_amomaxu_w_neigh_0: .asciz "AMOMAXU.W low word: neighbouring words untouched"
str_amoswap_w_neigh_4: .asciz "AMOSWAP.W high word: neighbouring words untouched"
str_amoadd_w_neigh_4:  .asciz "AMOADD.W high word: neighbouring words untouched"
str_amoxor_w_neigh_4:  .asciz "AMOXOR.W high word: neighbouring words untouched"
str_amoand_w_neigh_4:  .asciz "AMOAND.W high word: neighbouring words untouched"
str_amoor_w_neigh_4:   .asciz "AMOOR.W high word: neighbouring words untouched"
str_amomin_w_neigh_4:  .asciz "AMOMIN.W high word: neighbouring words untouched"
str_amomax_w_neigh_4:  .asciz "AMOMAX.W high word: neighbouring words untouched"
str_amominu_w_neigh_4: .asciz "AMOMINU.W high word: neighbouring words untouched"
str_amomaxu_w_neigh_4: .asciz "AMOMAXU.W high word: neighbouring words untouched"
    .if XLEN == 64
str_amoswap_d_neigh: .asciz "AMOSWAP.D: neighbouring words untouched"
str_amoadd_d_neigh:  .asciz "AMOADD.D: neighbouring words untouched"
str_amoxor_d_neigh:  .asciz "AMOXOR.D: neighbouring words untouched"
str_amoand_d_neigh:  .asciz "AMOAND.D: neighbouring words untouched"
str_amoor_d_neigh:   .asciz "AMOOR.D: neighbouring words untouched"
str_amomin_d_neigh:  .asciz "AMOMIN.D: neighbouring words untouched"
str_amomax_d_neigh:  .asciz "AMOMAX.D: neighbouring words untouched"
str_amominu_d_neigh: .asciz "AMOMINU.D: neighbouring words untouched"
str_amomaxu_d_neigh: .asciz "AMOMAXU.D: neighbouring words untouched"
    .endif

/* =======================================================================
 *  Data
 * ======================================================================= */
    .section .bss
    .balign 8
amo_buf:    .skip 24
bx_amo_ref: .skip 8
bx_amo_dut: .skip 8
