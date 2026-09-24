/* =====================================================================
 * zabha/amo.S  --  Zabha byte and halfword atomic memory operations:
 *                  AMOSWAP.B, AMOADD.B, AMOXOR.B, AMOAND.B, AMOOR.B,
 *                  AMOMIN.B, AMOMAX.B, AMOMINU.B, AMOMAXU.B,
 *                  and the same nine as .H
 *
 * Part of the Zabha suite; see zabha/tests.S for how this plugs into
 * the rest (main_tests.S -> zabha/tests.S -> here), and common.S for the
 * boot/UART/reporting harness everything sits on ("check", "uart_puts"
 * are used from there; nothing else).
 *
 * Same shape as the A extension's AMOs (a/amo.S): rd <- mem[rs1] (the
 * OLD value), then mem[rs1] <- op(old, rs2), all as one atomic step,
 * with the address in rs1 and no offset field. Zabha only narrows the
 * width: funct3 = 0 (.B) reads and writes one byte, funct3 = 1 (.H) one
 * halfword, and the old value is sign-extended into rd -- for AMOMINU/
 * AMOMAXU too, like the .W forms. Only the low 8/16 bits of rs2 take
 * part. Every value test checks both results: rd and the byte/halfword
 * left in memory (read back zero-extended with LBU/LHU).
 *
 * All 18 share the AMO encoding (funct5 = operation, funct3 = width,
 * aq/rl), so, as in a/amo.S, rd/rs1/rs2 and their aliasing are swept
 * once, through AMOADD.B (a few alias cases through .H), and the
 * per-instruction depth goes into the values.
 *
 * Per-instruction highlights:
 *   - rd gets the OLD value, never the new one; each instruction's first
 *     case has an old value and a result that differ.
 *   - Sign extension of rd from bit 7 / bit 15, including through the
 *     unsigned MINU/MAXU (the min/max-pair cases with a negative old
 *     value).
 *   - Every byte lane: the value cases rotate the target through all
 *     eight byte offsets (.B) and all four halfword offsets (.H) of a
 *     doubleword, so a lane-select or shift fault in the load or the
 *     store path fails.
 *   - Writes exactly its width: T_ZB_NEIGH runs every instruction at
 *     every lane and checks that all 24 bytes around the target, apart
 *     from the target itself, still hold their fill values. rs2 is
 *     chosen per operation so that the same operation done wider would
 *     change a neighbour (AMOADD's carry out of bit 7/15, AND clearing
 *     the upper bytes, ...).
 *   - rs2 above bit 7/15 is ignored: one case per instruction and width
 *     has garbage there (on both widths: even RV32's register is wider
 *     than a halfword), and MIN/MAX/MINU/MAXU get the (1, 0x100) /
 *     (1, 0x10000) pair, where a register-wide compare picks the other
 *     operand. The "rs2 0xff / 0xffff" cases have the upper bits clear
 *     and must still compare as -1.
 *   - AMOMIN/AMOMAX/AMOMINU/AMOMAXU all run against the same operand
 *     pairs, chosen where the signed and unsigned readings diverge
 *     ((1, -1), (MIN, MAX) in both orders), so a swapped signed/
 *     unsigned or min/max decode fails, and the result comes from
 *     memory in one order and from rs2 in the other. The .H forms also
 *     get (0x00ff, 0x0100), which a compare on the low byte only gets
 *     wrong, and AMOADD.H 0x00ff+1, whose carry must cross into the
 *     upper byte.
 *   - rd=x0: memory is still updated. rs2=x0: AMOSWAP stores 0, AMOOR
 *     returns the old value and leaves memory alone (atomic byte load).
 *   - Aliasing: rd==rs2 (AMOSWAP swaps a register with memory),
 *     rd==rs1, rs1==rs2 (the address's low byte/halfword is the
 *     operand), rd==rs1==rs2, rs1=sp; sources checked unmodified.
 *   - The aq/rl bits must not change the result: every instruction is
 *     also run as .aq, .rl and .aqrl.
 *
 * NAMES. The value, ordering and neighbour tables pass a description to
 * their macro, which defines the name strings next to the case (as the
 * bitx cases do: ZB_NAME), so those have no separate string table. The
 * hand-written register and aliasing tests use str_zb_* labels, defined
 * at the end of the file.
 *
 * TRAPS: every AMO under test runs armed (TRAP_ARM / TRAP_FAILS,
 * harness.inc): on a hart without Zabha (mcause 2), or if a misdecoded
 * address faults, each check of that test is a check_trap FAIL with the
 * mcause, never an UNEXPECTED TRAP hang. QEMU 10 leaves Zabha off by
 * default (-cpu rv64,zabha=true turns it on; the Makefile's run targets
 * do).
 *
 * Not tested: misaligned .H (it traps, or with Zama16B may succeed
 * inside a 16-byte block: implementation-dependent), and AMOCAS.B/
 * AMOCAS.H, which need Zacas as well.
 *
 * Bit independence across fields (bitx_zabha_amo, at the end): every
 * bit pair among rd/rs1/rs2 and the aq/rl bits, C(17,2) = 136 cases per
 * instruction, each checking both rd and memory -- see bitx.inc and
 * BX_C_ZB below.
 *
 * RV32 image (xlen.inc): identical cases; rd's sign extension is to 32
 * bits there (the expected values are written sign-extended to 64 bits
 * and LIX truncates them).
 * ===================================================================== */

    .include "xlen.inc"
    .include "harness.inc"

    .option norvc            /* no compressed AMOs exist, but the helper
                               * li/mv/add sequences must never be
                               * silently re-encoded either */

    .include "bitx.inc"

    .global tests_zabha_amo

    .section .text

/* zb_buf: six words, word i filled with ZB_FILL + i * 0x01010101 by
 * zb_fill before every case (no byte of the fill is a value any case
 * stores or expects). The target is zb_buf + 8 + off, off = 0..7: a
 * lane of the middle doubleword, with a whole word of known bytes below
 * and above it. */
    .equ    ZB_FILL, 0xc3b4e1d2

/* =======================================================================
 *  Shared macros
 * ======================================================================= */

/* ZB_NAME label, text -- define a test name string at label in .rodata. */
.macro ZB_NAME label, text
    .pushsection .rodata
\label: .asciz "\text"
    .popsection
.endm

/* ZB_ST w, reg, addr / ZB_LU w, reg, addr -- byte or halfword store,
 * and zero-extending load, by width. */
.macro ZB_ST w, reg, addr
    .if \w == 1
    sb      \reg, \addr
    .else
    sh      \reg, \addr
    .endif
.endm

.macro ZB_LU w, reg, addr
    .if \w == 1
    lbu     \reg, \addr
    .else
    lhu     \reg, \addr
    .endif
.endm

/* T_ZB_VAL insn, w, off, mem, v, erd, emem, desc -- fixed rd=t2 /
 * rs1=t3 / rs2=t4, the w-byte target at zb_buf + 8 + off set to mem,
 * rs2 = v. Checks rd against erd (the old value sign-extended) and the
 * target, read back zero-extended, against emem. Names: "<desc>: rd =
 * old value" and "<desc>: memory". This t2/t3/t4 encoding is also the
 * bitx reference (BX_C_ZB). */
.macro T_ZB_VAL insn, w, off, mem, v, erd, emem, desc
    ZB_NAME .Lzbv_r\@, "\desc: rd = old value"
    ZB_NAME .Lzbv_m\@, "\desc: memory"
    TEST_BEGIN .Lzbv_r\@
    jal     ra, zb_fill
    la      t3, zb_buf + 8 + \off
    LIX     t4, \mem
    ZB_ST   \w, t4, 0(t3)
    LIX     t4, \v
    TRAP_ARM .Lzbv_trap\@
    \insn   t2, t4, (t3)
    TRAP_DISARM
    mv      s1, t2                  /* check clobbers t0-t6 */
    ZB_LU   \w, s2, 0(t3)
    la      a0, .Lzbv_r\@
    LIX     a1, \erd
    mv      a2, s1
    call    check
    TEST_BEGIN .Lzbv_m\@
    la      a0, .Lzbv_m\@
    LIX     a1, \emem
    mv      a2, s2
    call    check
    TRAP_FAILS .Lzbv_trap\@, .Lzbv_r\@, .Lzbv_m\@
.endm

/* ZB_KEEP i, off, w -- set .Lzb_keep to the mask of the bytes of
 * zb_buf word i that are NOT part of the w-byte target at
 * zb_buf + 8 + off (all of them, for a word the target isn't in). */
.macro ZB_KEEP i, off, w
    .set    .Lzb_keep, 0xffffffff
    .irp    j, 0, 1, 2, 3
    .if ((4 * \i + \j) >= (8 + \off)) && ((4 * \i + \j) < (8 + \off + \w))
    .set    .Lzb_keep, .Lzb_keep & ~(0xff << (8 * \j))
    .endif
    .endr
.endm

/* T_ZB_NEIGH insn, w, off, v, desc -- run insn on the fill at
 * zb_buf + 8 + off with rs2 = v, then check that every byte of zb_buf
 * outside the w-byte target still holds its fill value (one check: the
 * OR over all six words of (word ^ fill) & keep must be 0). Name:
 * "<desc>: neighbouring bytes untouched". */
.macro T_ZB_NEIGH insn, w, off, v, desc
    ZB_NAME .Lzbn_n\@, "\desc: neighbouring bytes untouched"
    TEST_BEGIN .Lzbn_n\@
    jal     ra, zb_fill
    la      t3, zb_buf + 8 + \off
    LIX     t4, \v
    TRAP_ARM .Lzbn_trap\@
    \insn   t2, t4, (t3)
    TRAP_DISARM
    la      t3, zb_buf
    LIX     t5, 0
    .irp    i, 0, 1, 2, 3, 4, 5
    ZB_KEEP \i, \off, \w
    LWUX    t0, (4 * \i)(t3)
    LIX     t1, ZB_FILL + \i * 0x01010101
    xor     t0, t0, t1
    LIX     t1, .Lzb_keep
    and     t0, t0, t1
    or      t5, t5, t0
    .endr
    mv      t2, t5
    la      a0, .Lzbn_n\@
    LIX     a1, 0
    mv      a2, t2
    call    check
    TRAP_FAILS .Lzbn_trap\@, .Lzbn_n\@
.endm

/* T_ZB_RD/RS1/RS2 reg, name -- sweep one register field at a time
 * (through AMOADD.B at offset 3: memory 0x10, rs2 0x23), the other two
 * fixed at t2/t3/t4, none of which is in the swept lists. RD checks rd
 * (old value 0x10, captured to t2 before a0-a2 are reused); RS1/RS2
 * check memory (0x33), which only comes out right if the right address
 * and the right addend were used. */
.macro T_ZB_RD rdreg, name
    TEST_BEGIN \name
    jal     ra, zb_fill
    la      t3, zb_buf + 8 + 3
    LIX     t4, 0x10
    sb      t4, 0(t3)
    LIX     t4, 0x23
    TRAP_ARM .Lzr_trap\@
    amoadd.b \rdreg, t4, (t3)
    mv      t2, \rdreg
    TRAP_DISARM
    la      a0, \name
    LIX     a1, 0x10
    mv      a2, t2
    call    check
    TRAP_FAILS .Lzr_trap\@, \name
.endm

.macro T_ZB_RS1 rs1reg, name
    TEST_BEGIN \name
    jal     ra, zb_fill
    la      \rs1reg, zb_buf + 8 + 3
    LIX     t4, 0x10
    sb      t4, 0(\rs1reg)
    LIX     t4, 0x23
    TRAP_ARM .Lzs1_trap\@
    amoadd.b t2, t4, (\rs1reg)
    TRAP_DISARM
    la      t3, zb_buf + 8 + 3
    lbu     t2, 0(t3)
    la      a0, \name
    LIX     a1, 0x33
    mv      a2, t2
    call    check
    TRAP_FAILS .Lzs1_trap\@, \name
.endm

.macro T_ZB_RS2 rs2reg, name
    TEST_BEGIN \name
    jal     ra, zb_fill
    la      t3, zb_buf + 8 + 3
    LIX     t4, 0x10
    sb      t4, 0(t3)
    LIX     \rs2reg, 0x23
    TRAP_ARM .Lzs2_trap\@
    amoadd.b t2, \rs2reg, (t3)
    TRAP_DISARM
    lbu     t2, 0(t3)
    la      a0, \name
    LIX     a1, 0x33
    mv      a2, t2
    call    check
    TRAP_FAILS .Lzs2_trap\@, \name
.endm

/* BX_C_ZB insn, w, nm, rd, rs1, rs2, o -- one bit-independence case
 * (bitx.inc), a/amo.S's BX_C_AMO at byte/halfword width: rd/rs1/rs2 as
 * given, o = the raw aq/rl field (bit 1 = aq, bit 0 = rl), which only
 * selects the mnemonic suffix.
 *
 * Two register-sized slots, bx_zb_ref and bx_zb_dut, are set to the
 * sentinel with the pool's vb as the w-byte old value at offset 0, so
 * the rest of each slot is sentinel bytes that must survive. The
 * reference is the same instruction through the background encoding
 * (rd=t2, rs1=t3, rs2=t4, no ordering bits) on bx_zb_ref -- the
 * encoding the T_ZB_VAL tables pin down against literals. The case
 * under test runs on bx_zb_dut with rd pre-loaded with the sentinel,
 * then rs2 = va, then rs1 = the address: rs1 is loaded last so it
 * always holds a valid address, and when rs2 aliases rs1 the operand is
 * that address -- the reference is fed the same (bx_zb_dut's address)
 * as its rs2. Two checks per case: rd, then the whole slot.
 *
 * Besides the reserved registers listed in bitx.inc, a4 (x14) and a5
 * (x15) carry the two slots' read-backs across the first check (check
 * leaves a3-a7 alone); both have three or more bits set, so neither is
 * ever a candidate. s3 holds bx_zb_dut's address, and is reused to
 * disarm.
 *
 * Trapping: one TRAP_ARM, before anything is swept, covers both the
 * reference and the case; after a trap, BX_TRAP_FAILS restores
 * sp/gp/tp and reports both names as check_trap FAILs. */
.macro BX_C_ZB insn, w, nm, rd, rs1, rs2, o
    .if (\o) == 0
    BX_C_ZB_ \insn, \w, \nm, \rd, \rs1, \rs2, \insn, 0, 0
    .elseif (\o) == 1
    BX_C_ZB_ \insn, \w, \nm, \rd, \rs1, \rs2, \insn\().rl, 0, 1
    .elseif (\o) == 2
    BX_C_ZB_ \insn, \w, \nm, \rd, \rs1, \rs2, \insn\().aq, 1, 0
    .else
    BX_C_ZB_ \insn, \w, \nm, \rd, \rs1, \rs2, \insn\().aqrl, 1, 1
    .endif
.endm

.macro BX_C_ZB_ insn, w, nm, rd, rs1, rs2, dut, aq, rl
    BX_NAME .Lbxz_n\@, "\nm bitx rd=x\rd rs1=x\rs1 rs2=x\rs2 aq=\aq rl=\rl"
    BX_NAME .Lbxz_m\@, "\nm bitx rd=x\rd rs1=x\rs1 rs2=x\rs2 aq=\aq rl=\rl mem"
    BX_ENTER .Lbxz_n\@
    TRAP_ARM .Lbxz_trap\@          /* covers the reference and the case */
    .option push
    .option norelax
    la      t3, bx_zb_ref
    la      s3, bx_zb_dut
    .option pop
    BX_PV   t4, 2
    REG_S   t4, 0(t3)
    REG_S   t4, 0(s3)
    BX_PV   t4, 1
    ZB_ST   \w, t4, 0(t3)
    ZB_ST   \w, t4, 0(s3)
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
    BX_REPORT_AT .Lbxz_n\@
    mv      t5, a5
    mv      t6, a4
    BX_REPORT_AT .Lbxz_m\@
    BX_TRAP_FAILS .Lbxz_trap\@, .Lbxz_n\@, .Lbxz_m\@
.endm

tests_zabha_amo:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    jal     ra, test_zb_regs
    jal     ra, test_zb_b
    jal     ra, test_zb_h
    jal     ra, test_zb_order
    jal     ra, test_zb_neigh

    jal     ra, bitx_zabha_amo

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* zb_fill: zb_buf word i = ZB_FILL + i * 0x01010101. Clobbers t0/t1
 * only. */
zb_fill:
    la      t0, zb_buf
    .irp    i, 0, 1, 2, 3, 4, 5
    LIX     t1, ZB_FILL + \i * 0x01010101
    sw      t1, (4 * \i)(t0)
    .endr
    ret

/* =======================================================================
 *  Register fields and aliasing (through AMOADD.B unless noted)
 * ======================================================================= */
test_zb_regs:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    T_ZB_RD ra,  str_zb_rd_ra
    T_ZB_RD t0,  str_zb_rd_t0
    T_ZB_RD s0,  str_zb_rd_s0
    T_ZB_RD a0,  str_zb_rd_a0
    T_ZB_RD s10, str_zb_rd_s10
    T_ZB_RD t6,  str_zb_rd_t6

    T_ZB_RS1 ra,  str_zb_rs1_ra
    T_ZB_RS1 t0,  str_zb_rs1_t0
    T_ZB_RS1 s0,  str_zb_rs1_s0
    T_ZB_RS1 a0,  str_zb_rs1_a0
    T_ZB_RS1 s10, str_zb_rs1_s10
    T_ZB_RS1 t6,  str_zb_rs1_t6

    T_ZB_RS2 ra,  str_zb_rs2_ra
    T_ZB_RS2 t0,  str_zb_rs2_t0
    T_ZB_RS2 s0,  str_zb_rs2_s0
    T_ZB_RS2 a0,  str_zb_rs2_a0
    T_ZB_RS2 s10, str_zb_rs2_s10
    T_ZB_RS2 t6,  str_zb_rs2_t6

    TEST_BEGIN str_zb_rs1_sp_rd
    /* rs1=sp: an address register the compressed ISA treats specially;
     * the AMO must use it like any other */
    addi    sp, sp, -16
    LIX     t4, 0x10
    sb      t4, 0(sp)
    LIX     t4, 0x23
    TRAP_ARM .Lzb_trap_sp
    amoadd.b t2, t4, (sp)
    TRAP_DISARM
    mv      s1, t2
    lbu     s2, 0(sp)
    addi    sp, sp, 16
    la      a0, str_zb_rs1_sp_rd
    LIX     a1, 0x10
    mv      a2, s1
    call    check
    TEST_BEGIN str_zb_rs1_sp_mem
    la      a0, str_zb_rs1_sp_mem
    LIX     a1, 0x33
    mv      a2, s2
    call    check
    j       .Lzb_sp_done
.Lzb_trap_sp:                       /* trapped with sp still lowered */
    addi    sp, sp, 16
    TRAP_REPORT str_zb_rs1_sp_rd
    TRAP_REPORT str_zb_rs1_sp_mem
.Lzb_sp_done:

    /* rd=x0: result discarded, memory still updated */
    TEST_BEGIN str_zb_rd_x0
    jal     ra, zb_fill
    la      t3, zb_buf + 8 + 3
    LIX     t4, 0x10
    sb      t4, 0(t3)
    LIX     t4, 0x23
    TRAP_ARM .Lzb_trap_rd_x0
    amoadd.b x0, t4, (t3)
    TRAP_DISARM
    lbu     t2, 0(t3)
    la      a0, str_zb_rd_x0
    LIX     a1, 0x33
    mv      a2, t2
    call    check
    TRAP_FAILS .Lzb_trap_rd_x0, str_zb_rd_x0

    /* rs2=x0 through AMOSWAP.B: stores 0 */
    TEST_BEGIN str_zb_swap_rs2_x0_rd
    jal     ra, zb_fill
    la      t3, zb_buf + 8 + 1
    LIX     t4, 0x5b
    sb      t4, 0(t3)
    TRAP_ARM .Lzb_trap_swap_x0
    amoswap.b t2, x0, (t3)
    TRAP_DISARM
    mv      s1, t2
    lbu     s2, 0(t3)
    la      a0, str_zb_swap_rs2_x0_rd
    LIX     a1, 0x5b
    mv      a2, s1
    call    check
    TEST_BEGIN str_zb_swap_rs2_x0_mem
    la      a0, str_zb_swap_rs2_x0_mem
    LIX     a1, 0
    mv      a2, s2
    call    check
    TRAP_FAILS .Lzb_trap_swap_x0, str_zb_swap_rs2_x0_rd, str_zb_swap_rs2_x0_mem

    /* rs2=x0 through AMOOR.B: the atomic-load idiom, memory unchanged */
    TEST_BEGIN str_zb_or_rs2_x0_rd
    jal     ra, zb_fill
    la      t3, zb_buf + 8 + 6
    LIX     t4, 0x87
    sb      t4, 0(t3)
    TRAP_ARM .Lzb_trap_or_x0
    amoor.b t2, x0, (t3)
    TRAP_DISARM
    mv      s1, t2
    lbu     s2, 0(t3)
    la      a0, str_zb_or_rs2_x0_rd
    LIX     a1, 0xffffffffffffff87
    mv      a2, s1
    call    check
    TEST_BEGIN str_zb_or_rs2_x0_mem
    la      a0, str_zb_or_rs2_x0_mem
    LIX     a1, 0x87
    mv      a2, s2
    call    check
    TRAP_FAILS .Lzb_trap_or_x0, str_zb_or_rs2_x0_rd, str_zb_or_rs2_x0_mem

    TEST_BEGIN str_zb_swap_rd_rs2_rd
    /* rd==rs2 through AMOSWAP.H: swaps the register with memory -- the
     * old rs2 must be read before rd is written */
    jal     ra, zb_fill
    la      t3, zb_buf + 8 + 2
    LIX     t4, 0x3344
    sh      t4, 0(t3)
    LIX     t2, 0x7788
    TRAP_ARM .Lzb_trap_swap_rd_rs2
    amoswap.h t2, t2, (t3)
    TRAP_DISARM
    mv      s1, t2
    lhu     s2, 0(t3)
    la      a0, str_zb_swap_rd_rs2_rd
    LIX     a1, 0x3344
    mv      a2, s1
    call    check
    TEST_BEGIN str_zb_swap_rd_rs2_mem
    la      a0, str_zb_swap_rd_rs2_mem
    LIX     a1, 0x7788
    mv      a2, s2
    call    check
    TRAP_FAILS .Lzb_trap_swap_rd_rs2, str_zb_swap_rd_rs2_rd, str_zb_swap_rd_rs2_mem

    /* rd==rs2 */
    TEST_BEGIN str_zb_alias_rd_rs2_rd
    jal     ra, zb_fill
    la      t3, zb_buf + 8 + 3
    LIX     t4, 0x10
    sb      t4, 0(t3)
    LIX     t2, 0x23
    TRAP_ARM .Lzb_trap_rd_rs2
    amoadd.b t2, t2, (t3)
    TRAP_DISARM
    mv      s1, t2
    lbu     s2, 0(t3)
    la      a0, str_zb_alias_rd_rs2_rd
    LIX     a1, 0x10
    mv      a2, s1
    call    check
    TEST_BEGIN str_zb_alias_rd_rs2_mem
    la      a0, str_zb_alias_rd_rs2_mem
    LIX     a1, 0x33
    mv      a2, s2
    call    check
    TRAP_FAILS .Lzb_trap_rd_rs2, str_zb_alias_rd_rs2_rd, str_zb_alias_rd_rs2_mem

    /* rd==rs1: the address must be taken before rd is overwritten */
    TEST_BEGIN str_zb_alias_rd_rs1_rd
    jal     ra, zb_fill
    la      t3, zb_buf + 8 + 3
    LIX     t4, 0x10
    sb      t4, 0(t3)
    LIX     t4, 0x23
    TRAP_ARM .Lzb_trap_rd_rs1
    amoadd.b t3, t4, (t3)
    TRAP_DISARM
    mv      s1, t3
    la      t3, zb_buf + 8 + 3
    lbu     s2, 0(t3)
    la      a0, str_zb_alias_rd_rs1_rd
    LIX     a1, 0x10
    mv      a2, s1
    call    check
    TEST_BEGIN str_zb_alias_rd_rs1_mem
    la      a0, str_zb_alias_rd_rs1_mem
    LIX     a1, 0x33
    mv      a2, s2
    call    check
    TRAP_FAILS .Lzb_trap_rd_rs1, str_zb_alias_rd_rs1_rd, str_zb_alias_rd_rs1_mem

    /* rs1==rs2 through AMOSWAP.B: stores its own address's low byte */
    TEST_BEGIN str_zb_alias_rs1_rs2_rd
    jal     ra, zb_fill
    la      t3, zb_buf + 8 + 5
    mv      s3, t3
    LIX     t4, 0xc9
    sb      t4, 0(t3)
    TRAP_ARM .Lzb_trap_rs1_rs2
    amoswap.b t2, t3, (t3)
    TRAP_DISARM
    mv      s1, t2
    lbu     s2, 0(s3)
    la      a0, str_zb_alias_rs1_rs2_rd
    LIX     a1, 0xffffffffffffffc9
    mv      a2, s1
    call    check
    TEST_BEGIN str_zb_alias_rs1_rs2_mem
    la      a0, str_zb_alias_rs1_rs2_mem
    andi    a1, s3, 0xff
    mv      a2, s2
    call    check
    TRAP_FAILS .Lzb_trap_rs1_rs2, str_zb_alias_rs1_rs2_rd, str_zb_alias_rs1_rs2_mem

    /* rs1==rs2 through AMOADD.H: adds the address's low halfword */
    TEST_BEGIN str_zb_alias_rs1_rs2_add_rd
    jal     ra, zb_fill
    la      t3, zb_buf + 8 + 4
    mv      s3, t3
    LIX     t4, 0x0100
    sh      t4, 0(t3)
    TRAP_ARM .Lzb_trap_rs1_rs2_add
    amoadd.h t2, t3, (t3)
    TRAP_DISARM
    mv      s1, t2
    lhu     s2, 0(s3)
    la      a0, str_zb_alias_rs1_rs2_add_rd
    LIX     a1, 0x0100
    mv      a2, s1
    call    check
    TEST_BEGIN str_zb_alias_rs1_rs2_add_mem
    la      a0, str_zb_alias_rs1_rs2_add_mem
    addi    a1, s3, 0x100
    slli    a1, a1, XLEN - 16       /* the halfword read back is */
    srli    a1, a1, XLEN - 16       /* zero-extended */
    mv      a2, s2
    call    check
    TRAP_FAILS .Lzb_trap_rs1_rs2_add, str_zb_alias_rs1_rs2_add_rd, str_zb_alias_rs1_rs2_add_mem

    /* rd==rs1==rs2 through AMOSWAP.H */
    TEST_BEGIN str_zb_alias_all_same_rd
    jal     ra, zb_fill
    la      t3, zb_buf + 8 + 6
    mv      s3, t3
    LIX     t4, 0xba98
    sh      t4, 0(t3)
    TRAP_ARM .Lzb_trap_all_same
    amoswap.h t3, t3, (t3)
    TRAP_DISARM
    mv      s1, t3
    lhu     s2, 0(s3)
    la      a0, str_zb_alias_all_same_rd
    LIX     a1, 0xffffffffffffba98
    mv      a2, s1
    call    check
    TEST_BEGIN str_zb_alias_all_same_mem
    la      a0, str_zb_alias_all_same_mem
    slli    a1, s3, XLEN - 16
    srli    a1, a1, XLEN - 16
    mv      a2, s2
    call    check
    TRAP_FAILS .Lzb_trap_all_same, str_zb_alias_all_same_rd, str_zb_alias_all_same_mem

    /* sources unmodified */
    TEST_BEGIN str_zb_rs1_preserved
    jal     ra, zb_fill
    la      t3, zb_buf + 8 + 3
    LIX     t4, 0x10
    sb      t4, 0(t3)
    LIXT    t4, 0x0fedcba987654321
    mv      s1, t3
    mv      s2, t4
    TRAP_ARM .Lzb_trap_preserved
    amoadd.b t2, t4, (t3)
    TRAP_DISARM
    mv      s4, t3
    mv      s5, t4
    la      a0, str_zb_rs1_preserved
    mv      a1, s1
    mv      a2, s4
    call    check
    TEST_BEGIN str_zb_rs2_preserved
    la      a0, str_zb_rs2_preserved
    mv      a1, s2
    mv      a2, s5
    call    check
    TRAP_FAILS .Lzb_trap_preserved, str_zb_rs1_preserved, str_zb_rs2_preserved

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  .B values. The offsets walk the target through all eight byte lanes
 *  of the doubleword. Columns: insn, width, offset, old byte, rs2,
 *  expected rd (sign-extended), expected byte.
 * ======================================================================= */
test_zb_b:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    /* ----- AMOSWAP.B ----- */
    T_ZB_VAL amoswap.b, 1, 0, 0x12, 0x9a, 0x12, 0x9a, "AMOSWAP.B basic swap"
    T_ZB_VAL amoswap.b, 1, 1, 0x80, 0x01, 0xffffffffffffff80, 0x01, "AMOSWAP.B old byte 0x80 (rd sign-extends bit 7)"
    T_ZB_VAL amoswap.b, 1, 2, 0xff, 0x00, 0xffffffffffffffff, 0x00, "AMOSWAP.B stores 0, old byte all ones"
    T_ZB_VAL amoswap.b, 1, 3, 0x11, 0xdeadbe22, 0x11, 0x22, "AMOSWAP.B rs2 0xdeadbe22 (stores only rs2[7:0])"

    /* ----- AMOADD.B ----- */
    T_ZB_VAL amoadd.b, 1, 4, 0x05, 0x07, 0x05, 0x0c, "AMOADD.B 5+7"
    T_ZB_VAL amoadd.b, 1, 5, 0x7f, 0x01, 0x7f, 0x80, "AMOADD.B 0x7f+1 wraps to 0x80"
    T_ZB_VAL amoadd.b, 1, 6, 0xff, 0x01, 0xffffffffffffffff, 0x00, "AMOADD.B 0xff+1 = 0 (carry out of bit 7 dropped)"
    T_ZB_VAL amoadd.b, 1, 7, 0x80, 0x80, 0xffffffffffffff80, 0x00, "AMOADD.B 0x80+0x80 = 0"
    T_ZB_VAL amoadd.b, 1, 0, 0x01, 0xffffffffffffffff, 0x01, 0x00, "AMOADD.B 1 + (-1) = 0"
    T_ZB_VAL amoadd.b, 1, 1, 0x05, 0x12345607, 0x05, 0x0c, "AMOADD.B 5 + 0x12345607 (rs2[7:0] only)"

    /* ----- AMOXOR.B ----- */
    T_ZB_VAL amoxor.b, 1, 2, 0xa5, 0x0f, 0xffffffffffffffa5, 0xaa, "AMOXOR.B 0xa5^0x0f"
    T_ZB_VAL amoxor.b, 1, 3, 0x3c, 0x3c, 0x3c, 0x00, "AMOXOR.B x^x = 0"
    T_ZB_VAL amoxor.b, 1, 4, 0x80, 0xffffffffffffffff, 0xffffffffffffff80, 0x7f, "AMOXOR.B 0x80 ^ -1 = 0x7f"
    T_ZB_VAL amoxor.b, 1, 5, 0x0f, 0xabcdef30, 0x0f, 0x3f, "AMOXOR.B 0x0f ^ 0xabcdef30 (rs2[7:0] only)"

    /* ----- AMOAND.B ----- */
    T_ZB_VAL amoand.b, 1, 6, 0xf0, 0x3c, 0xfffffffffffffff0, 0x30, "AMOAND.B 0xf0&0x3c"
    T_ZB_VAL amoand.b, 1, 7, 0x12, 0x00, 0x12, 0x00, "AMOAND.B x&0 = 0"
    T_ZB_VAL amoand.b, 1, 0, 0x81, 0xffffffffffffffff, 0xffffffffffffff81, 0x81, "AMOAND.B 0x81 & -1 unchanged"
    T_ZB_VAL amoand.b, 1, 1, 0xff, 0x1234560f, 0xffffffffffffffff, 0x0f, "AMOAND.B 0xff & 0x1234560f (rs2[7:0] only)"

    /* ----- AMOOR.B ----- */
    T_ZB_VAL amoor.b, 1, 2, 0xf0, 0x0f, 0xfffffffffffffff0, 0xff, "AMOOR.B 0xf0|0x0f"
    T_ZB_VAL amoor.b, 1, 3, 0x00, 0x80, 0x00, 0x80, "AMOOR.B 0|0x80 sets bit 7"
    T_ZB_VAL amoor.b, 1, 4, 0x12, 0x00, 0x12, 0x12, "AMOOR.B x|0 unchanged"
    T_ZB_VAL amoor.b, 1, 5, 0x00, 0xffffff01, 0x00, 0x01, "AMOOR.B 0 | 0xffffff01 (rs2[7:0] only)"

    /* ----- AMOMIN.B / AMOMAX.B / AMOMINU.B / AMOMAXU.B: the same
     * pairs through all four ----- */
    T_ZB_VAL amomin.b,  1, 6, 0x01, 0xffffffffffffffff, 0x01, 0xff, "AMOMIN.B (1, -1)"
    T_ZB_VAL amomax.b,  1, 6, 0x01, 0xffffffffffffffff, 0x01, 0x01, "AMOMAX.B (1, -1)"
    T_ZB_VAL amominu.b, 1, 6, 0x01, 0xffffffffffffffff, 0x01, 0x01, "AMOMINU.B (1, -1)"
    T_ZB_VAL amomaxu.b, 1, 6, 0x01, 0xffffffffffffffff, 0x01, 0xff, "AMOMAXU.B (1, -1)"

    T_ZB_VAL amomin.b,  1, 7, 0x01, 0xff, 0x01, 0xff, "AMOMIN.B (1, rs2 0xff with upper bits clear)"
    T_ZB_VAL amomax.b,  1, 7, 0x01, 0xff, 0x01, 0x01, "AMOMAX.B (1, rs2 0xff with upper bits clear)"
    T_ZB_VAL amominu.b, 1, 7, 0x01, 0xff, 0x01, 0x01, "AMOMINU.B (1, rs2 0xff with upper bits clear)"
    T_ZB_VAL amomaxu.b, 1, 7, 0x01, 0xff, 0x01, 0xff, "AMOMAXU.B (1, rs2 0xff with upper bits clear)"

    T_ZB_VAL amomin.b,  1, 0, 0x80, 0x7f, 0xffffffffffffff80, 0x80, "AMOMIN.B (0x80, 0x7f)"
    T_ZB_VAL amomax.b,  1, 0, 0x80, 0x7f, 0xffffffffffffff80, 0x7f, "AMOMAX.B (0x80, 0x7f)"
    T_ZB_VAL amominu.b, 1, 0, 0x80, 0x7f, 0xffffffffffffff80, 0x7f, "AMOMINU.B (0x80, 0x7f)"
    T_ZB_VAL amomaxu.b, 1, 0, 0x80, 0x7f, 0xffffffffffffff80, 0x80, "AMOMAXU.B (0x80, 0x7f)"

    T_ZB_VAL amomin.b,  1, 1, 0x7f, 0x80, 0x7f, 0x80, "AMOMIN.B (0x7f, 0x80)"
    T_ZB_VAL amomax.b,  1, 1, 0x7f, 0x80, 0x7f, 0x7f, "AMOMAX.B (0x7f, 0x80)"
    T_ZB_VAL amominu.b, 1, 1, 0x7f, 0x80, 0x7f, 0x7f, "AMOMINU.B (0x7f, 0x80)"
    T_ZB_VAL amomaxu.b, 1, 1, 0x7f, 0x80, 0x7f, 0x80, "AMOMAXU.B (0x7f, 0x80)"

    T_ZB_VAL amomin.b,  1, 2, 0xfe, 0xffffffffffffffff, 0xfffffffffffffffe, 0xfe, "AMOMIN.B (-2, -1)"
    T_ZB_VAL amomax.b,  1, 2, 0xfe, 0xffffffffffffffff, 0xfffffffffffffffe, 0xff, "AMOMAX.B (-2, -1)"
    T_ZB_VAL amominu.b, 1, 2, 0xfe, 0xffffffffffffffff, 0xfffffffffffffffe, 0xfe, "AMOMINU.B (-2, -1)"
    T_ZB_VAL amomaxu.b, 1, 2, 0xfe, 0xffffffffffffffff, 0xfffffffffffffffe, 0xff, "AMOMAXU.B (-2, -1)"

    T_ZB_VAL amomin.b,  1, 3, 0x03, 0x07, 0x03, 0x03, "AMOMIN.B (3, 7)"
    T_ZB_VAL amomax.b,  1, 3, 0x03, 0x07, 0x03, 0x07, "AMOMAX.B (3, 7)"
    T_ZB_VAL amominu.b, 1, 3, 0x03, 0x07, 0x03, 0x03, "AMOMINU.B (3, 7)"
    T_ZB_VAL amomaxu.b, 1, 3, 0x03, 0x07, 0x03, 0x07, "AMOMAXU.B (3, 7)"

    T_ZB_VAL amomin.b,  1, 4, 0x05, 0x05, 0x05, 0x05, "AMOMIN.B (5, 5)"
    T_ZB_VAL amomax.b,  1, 4, 0x05, 0x05, 0x05, 0x05, "AMOMAX.B (5, 5)"
    T_ZB_VAL amominu.b, 1, 4, 0x05, 0x05, 0x05, 0x05, "AMOMINU.B (5, 5)"
    T_ZB_VAL amomaxu.b, 1, 4, 0x05, 0x05, 0x05, 0x05, "AMOMAXU.B (5, 5)"

    T_ZB_VAL amomin.b,  1, 5, 0x01, 0x100, 0x01, 0x00, "AMOMIN.B (1, rs2 0x100: compares rs2[7:0] = 0)"
    T_ZB_VAL amomax.b,  1, 5, 0x01, 0x100, 0x01, 0x01, "AMOMAX.B (1, rs2 0x100: compares rs2[7:0] = 0)"
    T_ZB_VAL amominu.b, 1, 5, 0x01, 0x100, 0x01, 0x00, "AMOMINU.B (1, rs2 0x100: compares rs2[7:0] = 0)"
    T_ZB_VAL amomaxu.b, 1, 5, 0x01, 0x100, 0x01, 0x01, "AMOMAXU.B (1, rs2 0x100: compares rs2[7:0] = 0)"

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  .H values. The offsets walk the target through all four halfword
 *  lanes of the doubleword.
 * ======================================================================= */
test_zb_h:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    /* ----- AMOSWAP.H ----- */
    T_ZB_VAL amoswap.h, 2, 0, 0x1234, 0x9abc, 0x1234, 0x9abc, "AMOSWAP.H basic swap"
    T_ZB_VAL amoswap.h, 2, 2, 0x8000, 0x0001, 0xffffffffffff8000, 0x0001, "AMOSWAP.H old halfword 0x8000 (rd sign-extends bit 15)"
    T_ZB_VAL amoswap.h, 2, 4, 0xffff, 0x0000, 0xffffffffffffffff, 0x0000, "AMOSWAP.H stores 0, old halfword all ones"
    T_ZB_VAL amoswap.h, 2, 6, 0x1111, 0xdead2222, 0x1111, 0x2222, "AMOSWAP.H rs2 0xdead2222 (stores only rs2[15:0])"

    /* ----- AMOADD.H ----- */
    T_ZB_VAL amoadd.h, 2, 0, 0x0005, 0x0007, 0x0005, 0x000c, "AMOADD.H 5+7"
    T_ZB_VAL amoadd.h, 2, 2, 0x7fff, 0x0001, 0x7fff, 0x8000, "AMOADD.H 0x7fff+1 wraps to 0x8000"
    T_ZB_VAL amoadd.h, 2, 4, 0xffff, 0x0001, 0xffffffffffffffff, 0x0000, "AMOADD.H 0xffff+1 = 0 (carry out of bit 15 dropped)"
    T_ZB_VAL amoadd.h, 2, 6, 0x8000, 0x8000, 0xffffffffffff8000, 0x0000, "AMOADD.H 0x8000+0x8000 = 0"
    T_ZB_VAL amoadd.h, 2, 0, 0x0001, 0xffffffffffffffff, 0x0001, 0x0000, "AMOADD.H 1 + (-1) = 0"
    T_ZB_VAL amoadd.h, 2, 2, 0x0005, 0x12340007, 0x0005, 0x000c, "AMOADD.H 5 + 0x12340007 (rs2[15:0] only)"
    T_ZB_VAL amoadd.h, 2, 4, 0x00ff, 0x0001, 0x00ff, 0x0100, "AMOADD.H 0x00ff+1 = 0x0100 (carry into the upper byte)"

    /* ----- AMOXOR.H ----- */
    T_ZB_VAL amoxor.h, 2, 6, 0xa5a5, 0x0ff0, 0xffffffffffffa5a5, 0xaa55, "AMOXOR.H 0xa5a5^0x0ff0"
    T_ZB_VAL amoxor.h, 2, 0, 0x3c3c, 0x3c3c, 0x3c3c, 0x0000, "AMOXOR.H x^x = 0"
    T_ZB_VAL amoxor.h, 2, 2, 0x8000, 0xffffffffffffffff, 0xffffffffffff8000, 0x7fff, "AMOXOR.H 0x8000 ^ -1 = 0x7fff"
    T_ZB_VAL amoxor.h, 2, 4, 0x0f0f, 0xabcd3030, 0x0f0f, 0x3f3f, "AMOXOR.H 0x0f0f ^ 0xabcd3030 (rs2[15:0] only)"

    /* ----- AMOAND.H ----- */
    T_ZB_VAL amoand.h, 2, 6, 0xff00, 0x0ff0, 0xffffffffffffff00, 0x0f00, "AMOAND.H 0xff00&0x0ff0"
    T_ZB_VAL amoand.h, 2, 0, 0x1234, 0x0000, 0x1234, 0x0000, "AMOAND.H x&0 = 0"
    T_ZB_VAL amoand.h, 2, 2, 0x8001, 0xffffffffffffffff, 0xffffffffffff8001, 0x8001, "AMOAND.H 0x8001 & -1 unchanged"
    T_ZB_VAL amoand.h, 2, 4, 0xffff, 0x12340f0f, 0xffffffffffffffff, 0x0f0f, "AMOAND.H 0xffff & 0x12340f0f (rs2[15:0] only)"

    /* ----- AMOOR.H ----- */
    T_ZB_VAL amoor.h, 2, 6, 0xff00, 0x0ff0, 0xffffffffffffff00, 0xfff0, "AMOOR.H 0xff00|0x0ff0"
    T_ZB_VAL amoor.h, 2, 0, 0x0000, 0x8000, 0x0000, 0x8000, "AMOOR.H 0|0x8000 sets bit 15"
    T_ZB_VAL amoor.h, 2, 2, 0x1234, 0x0000, 0x1234, 0x1234, "AMOOR.H x|0 unchanged"
    T_ZB_VAL amoor.h, 2, 4, 0x0000, 0xffff0001, 0x0000, 0x0001, "AMOOR.H 0 | 0xffff0001 (rs2[15:0] only)"

    /* ----- AMOMIN.H / AMOMAX.H / AMOMINU.H / AMOMAXU.H ----- */
    T_ZB_VAL amomin.h,  2, 6, 0x0001, 0xffffffffffffffff, 0x0001, 0xffff, "AMOMIN.H (1, -1)"
    T_ZB_VAL amomax.h,  2, 6, 0x0001, 0xffffffffffffffff, 0x0001, 0x0001, "AMOMAX.H (1, -1)"
    T_ZB_VAL amominu.h, 2, 6, 0x0001, 0xffffffffffffffff, 0x0001, 0x0001, "AMOMINU.H (1, -1)"
    T_ZB_VAL amomaxu.h, 2, 6, 0x0001, 0xffffffffffffffff, 0x0001, 0xffff, "AMOMAXU.H (1, -1)"

    T_ZB_VAL amomin.h,  2, 0, 0x0001, 0xffff, 0x0001, 0xffff, "AMOMIN.H (1, rs2 0xffff with upper bits clear)"
    T_ZB_VAL amomax.h,  2, 0, 0x0001, 0xffff, 0x0001, 0x0001, "AMOMAX.H (1, rs2 0xffff with upper bits clear)"
    T_ZB_VAL amominu.h, 2, 0, 0x0001, 0xffff, 0x0001, 0x0001, "AMOMINU.H (1, rs2 0xffff with upper bits clear)"
    T_ZB_VAL amomaxu.h, 2, 0, 0x0001, 0xffff, 0x0001, 0xffff, "AMOMAXU.H (1, rs2 0xffff with upper bits clear)"

    T_ZB_VAL amomin.h,  2, 2, 0x8000, 0x7fff, 0xffffffffffff8000, 0x8000, "AMOMIN.H (0x8000, 0x7fff)"
    T_ZB_VAL amomax.h,  2, 2, 0x8000, 0x7fff, 0xffffffffffff8000, 0x7fff, "AMOMAX.H (0x8000, 0x7fff)"
    T_ZB_VAL amominu.h, 2, 2, 0x8000, 0x7fff, 0xffffffffffff8000, 0x7fff, "AMOMINU.H (0x8000, 0x7fff)"
    T_ZB_VAL amomaxu.h, 2, 2, 0x8000, 0x7fff, 0xffffffffffff8000, 0x8000, "AMOMAXU.H (0x8000, 0x7fff)"

    T_ZB_VAL amomin.h,  2, 4, 0x7fff, 0x8000, 0x7fff, 0x8000, "AMOMIN.H (0x7fff, 0x8000)"
    T_ZB_VAL amomax.h,  2, 4, 0x7fff, 0x8000, 0x7fff, 0x7fff, "AMOMAX.H (0x7fff, 0x8000)"
    T_ZB_VAL amominu.h, 2, 4, 0x7fff, 0x8000, 0x7fff, 0x7fff, "AMOMINU.H (0x7fff, 0x8000)"
    T_ZB_VAL amomaxu.h, 2, 4, 0x7fff, 0x8000, 0x7fff, 0x8000, "AMOMAXU.H (0x7fff, 0x8000)"

    T_ZB_VAL amomin.h,  2, 6, 0xfffe, 0xffffffffffffffff, 0xfffffffffffffffe, 0xfffe, "AMOMIN.H (-2, -1)"
    T_ZB_VAL amomax.h,  2, 6, 0xfffe, 0xffffffffffffffff, 0xfffffffffffffffe, 0xffff, "AMOMAX.H (-2, -1)"
    T_ZB_VAL amominu.h, 2, 6, 0xfffe, 0xffffffffffffffff, 0xfffffffffffffffe, 0xfffe, "AMOMINU.H (-2, -1)"
    T_ZB_VAL amomaxu.h, 2, 6, 0xfffe, 0xffffffffffffffff, 0xfffffffffffffffe, 0xffff, "AMOMAXU.H (-2, -1)"

    T_ZB_VAL amomin.h,  2, 0, 0x0003, 0x0007, 0x0003, 0x0003, "AMOMIN.H (3, 7)"
    T_ZB_VAL amomax.h,  2, 0, 0x0003, 0x0007, 0x0003, 0x0007, "AMOMAX.H (3, 7)"
    T_ZB_VAL amominu.h, 2, 0, 0x0003, 0x0007, 0x0003, 0x0003, "AMOMINU.H (3, 7)"
    T_ZB_VAL amomaxu.h, 2, 0, 0x0003, 0x0007, 0x0003, 0x0007, "AMOMAXU.H (3, 7)"

    T_ZB_VAL amomin.h,  2, 2, 0x0005, 0x0005, 0x0005, 0x0005, "AMOMIN.H (5, 5)"
    T_ZB_VAL amomax.h,  2, 2, 0x0005, 0x0005, 0x0005, 0x0005, "AMOMAX.H (5, 5)"
    T_ZB_VAL amominu.h, 2, 2, 0x0005, 0x0005, 0x0005, 0x0005, "AMOMINU.H (5, 5)"
    T_ZB_VAL amomaxu.h, 2, 2, 0x0005, 0x0005, 0x0005, 0x0005, "AMOMAXU.H (5, 5)"

    T_ZB_VAL amomin.h,  2, 4, 0x0001, 0x10000, 0x0001, 0x0000, "AMOMIN.H (1, rs2 0x10000: compares rs2[15:0] = 0)"
    T_ZB_VAL amomax.h,  2, 4, 0x0001, 0x10000, 0x0001, 0x0001, "AMOMAX.H (1, rs2 0x10000: compares rs2[15:0] = 0)"
    T_ZB_VAL amominu.h, 2, 4, 0x0001, 0x10000, 0x0001, 0x0000, "AMOMINU.H (1, rs2 0x10000: compares rs2[15:0] = 0)"
    T_ZB_VAL amomaxu.h, 2, 4, 0x0001, 0x10000, 0x0001, 0x0001, "AMOMAXU.H (1, rs2 0x10000: compares rs2[15:0] = 0)"

    /* a compare on the low byte only would read (-1, 0) here */
    T_ZB_VAL amomin.h,  2, 6, 0x00ff, 0x0100, 0x00ff, 0x00ff, "AMOMIN.H (0x00ff, 0x0100)"
    T_ZB_VAL amomax.h,  2, 6, 0x00ff, 0x0100, 0x00ff, 0x0100, "AMOMAX.H (0x00ff, 0x0100)"
    T_ZB_VAL amominu.h, 2, 6, 0x00ff, 0x0100, 0x00ff, 0x00ff, "AMOMINU.H (0x00ff, 0x0100)"
    T_ZB_VAL amomaxu.h, 2, 6, 0x00ff, 0x0100, 0x00ff, 0x0100, "AMOMAXU.H (0x00ff, 0x0100)"

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  Ordering bits: .aq/.rl/.aqrl must not change the result (same
 *  operands as each instruction's first case)
 * ======================================================================= */

/* T_ZB_ORD insn, w, off, mem, v, erd, emem, desc -- T_ZB_VAL for each of
 * insn.aq, insn.rl and insn.aqrl. */
.macro T_ZB_ORD insn, w, off, mem, v, erd, emem, desc
    .irp    o, aq, rl, aqrl
    T_ZB_VAL \insn\().\o, \w, \off, \mem, \v, \erd, \emem, "\desc, .\o"
    .endr
.endm

test_zb_order:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    T_ZB_ORD amoswap.b, 1, 0, 0x12, 0x9a, 0x12, 0x9a, "AMOSWAP.B basic swap"
    T_ZB_ORD amoadd.b,  1, 4, 0x05, 0x07, 0x05, 0x0c, "AMOADD.B 5+7"
    T_ZB_ORD amoxor.b,  1, 2, 0xa5, 0x0f, 0xffffffffffffffa5, 0xaa, "AMOXOR.B 0xa5^0x0f"
    T_ZB_ORD amoand.b,  1, 6, 0xf0, 0x3c, 0xfffffffffffffff0, 0x30, "AMOAND.B 0xf0&0x3c"
    T_ZB_ORD amoor.b,   1, 2, 0xf0, 0x0f, 0xfffffffffffffff0, 0xff, "AMOOR.B 0xf0|0x0f"
    T_ZB_ORD amomin.b,  1, 6, 0x01, 0xffffffffffffffff, 0x01, 0xff, "AMOMIN.B (1, -1)"
    T_ZB_ORD amomax.b,  1, 6, 0x01, 0xffffffffffffffff, 0x01, 0x01, "AMOMAX.B (1, -1)"
    T_ZB_ORD amominu.b, 1, 6, 0x01, 0xffffffffffffffff, 0x01, 0x01, "AMOMINU.B (1, -1)"
    T_ZB_ORD amomaxu.b, 1, 6, 0x01, 0xffffffffffffffff, 0x01, 0xff, "AMOMAXU.B (1, -1)"

    T_ZB_ORD amoswap.h, 2, 0, 0x1234, 0x9abc, 0x1234, 0x9abc, "AMOSWAP.H basic swap"
    T_ZB_ORD amoadd.h,  2, 0, 0x0005, 0x0007, 0x0005, 0x000c, "AMOADD.H 5+7"
    T_ZB_ORD amoxor.h,  2, 6, 0xa5a5, 0x0ff0, 0xffffffffffffa5a5, 0xaa55, "AMOXOR.H 0xa5a5^0x0ff0"
    T_ZB_ORD amoand.h,  2, 6, 0xff00, 0x0ff0, 0xffffffffffffff00, 0x0f00, "AMOAND.H 0xff00&0x0ff0"
    T_ZB_ORD amoor.h,   2, 6, 0xff00, 0x0ff0, 0xffffffffffffff00, 0xfff0, "AMOOR.H 0xff00|0x0ff0"
    T_ZB_ORD amomin.h,  2, 6, 0x0001, 0xffffffffffffffff, 0x0001, 0xffff, "AMOMIN.H (1, -1)"
    T_ZB_ORD amomax.h,  2, 6, 0x0001, 0xffffffffffffffff, 0x0001, 0x0001, "AMOMAX.H (1, -1)"
    T_ZB_ORD amominu.h, 2, 6, 0x0001, 0xffffffffffffffff, 0x0001, 0x0001, "AMOMINU.H (1, -1)"
    T_ZB_ORD amomaxu.h, 2, 6, 0x0001, 0xffffffffffffffff, 0x0001, 0xffff, "AMOMAXU.H (1, -1)"

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  Neighbouring bytes untouched, every instruction at every lane. rs2
 *  per operation: its low byte/halfword changes the target, and above
 *  that it holds what the same operation done wider would write into a
 *  neighbour -- ones for SWAP/XOR/OR/MAXU, zeros for AND/MINU, a carry
 *  out of the lane for ADD (the fill bytes are all >= 0xb4), and a MIN/
 *  MAX operand beyond every fill value either way.
 * ======================================================================= */
test_zb_neigh:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    .irp off, 0, 1, 2, 3, 4, 5, 6, 7
    T_ZB_NEIGH amoswap.b, 1, \off, 0xffff8181, "AMOSWAP.B byte \off"
    T_ZB_NEIGH amoadd.b,  1, \off, 0xffffc1c1, "AMOADD.B byte \off"
    T_ZB_NEIGH amoxor.b,  1, \off, 0xffff8181, "AMOXOR.B byte \off"
    T_ZB_NEIGH amoand.b,  1, \off, 0x00008181, "AMOAND.B byte \off"
    T_ZB_NEIGH amoor.b,   1, \off, 0xffff8181, "AMOOR.B byte \off"
    T_ZB_NEIGH amomin.b,  1, \off, 0x80008080, "AMOMIN.B byte \off"
    T_ZB_NEIGH amomax.b,  1, \off, 0x7fff7f7f, "AMOMAX.B byte \off"
    T_ZB_NEIGH amominu.b, 1, \off, 0x00000101, "AMOMINU.B byte \off"
    T_ZB_NEIGH amomaxu.b, 1, \off, 0xffffffff, "AMOMAXU.B byte \off"
    .endr

    .irp off, 0, 2, 4, 6
    T_ZB_NEIGH amoswap.h, 2, \off, 0xffff8181, "AMOSWAP.H halfword at byte \off"
    T_ZB_NEIGH amoadd.h,  2, \off, 0xffffc1c1, "AMOADD.H halfword at byte \off"
    T_ZB_NEIGH amoxor.h,  2, \off, 0xffff8181, "AMOXOR.H halfword at byte \off"
    T_ZB_NEIGH amoand.h,  2, \off, 0x00008181, "AMOAND.H halfword at byte \off"
    T_ZB_NEIGH amoor.h,   2, \off, 0xffff8181, "AMOOR.H halfword at byte \off"
    T_ZB_NEIGH amomin.h,  2, \off, 0x80008080, "AMOMIN.H halfword at byte \off"
    T_ZB_NEIGH amomax.h,  2, \off, 0x7fff7f7f, "AMOMAX.H halfword at byte \off"
    T_ZB_NEIGH amominu.h, 2, \off, 0x00000101, "AMOMINU.H halfword at byte \off"
    T_ZB_NEIGH amomaxu.h, 2, \off, 0xffffffff, "AMOMAXU.H halfword at byte \off"
    .endr

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* Bit independence across fields -- see the file header, BX_C_ZB and
 * bitx.inc. The aq/rl field is the 2-bit "immediate" (0x1 = rl,
 * 0x2 = aq), background 0. Pool: va = rs2, vb = the old memory value.
 * The old byte/halfword (0x96 / 0xa596) has its sign bit set, so rd's
 * sign extension is exercised, and against rs2's (0x78 / 0x5678) the
 * signed and unsigned orders disagree; rs2 carries garbage above its
 * low byte/halfword. With that pair MIN and MAXU would keep the old
 * value, so a case that ignored rs2 altogether would still pass: they
 * get the pair the other way round, which makes every operation's
 * result depend on rs2. */
bitx_zabha_amo:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    BX_POOL 0xdeadbeef12345678, 0x3c3c3c3cc3b4a596
    BX_E_RRRI5 BX_C_ZB, "amoswap.b, 1, AMOSWAP.B", "0x1,0x2", 0
    BX_E_RRRI5 BX_C_ZB, "amoadd.b, 1, AMOADD.B", "0x1,0x2", 0
    BX_E_RRRI5 BX_C_ZB, "amoxor.b, 1, AMOXOR.B", "0x1,0x2", 0
    BX_E_RRRI5 BX_C_ZB, "amoand.b, 1, AMOAND.B", "0x1,0x2", 0
    BX_E_RRRI5 BX_C_ZB, "amoor.b, 1, AMOOR.B", "0x1,0x2", 0
    BX_E_RRRI5 BX_C_ZB, "amomax.b, 1, AMOMAX.B", "0x1,0x2", 0
    BX_E_RRRI5 BX_C_ZB, "amominu.b, 1, AMOMINU.B", "0x1,0x2", 0
    BX_POOL 0xdeadbeefc3b4a596, 0x3c3c3c3c12345678
    BX_E_RRRI5 BX_C_ZB, "amomin.b, 1, AMOMIN.B", "0x1,0x2", 0
    BX_E_RRRI5 BX_C_ZB, "amomaxu.b, 1, AMOMAXU.B", "0x1,0x2", 0

    BX_POOL 0xdeadbeef12345678, 0x3c3c3c3cc3b4a596
    BX_E_RRRI5 BX_C_ZB, "amoswap.h, 2, AMOSWAP.H", "0x1,0x2", 0
    BX_E_RRRI5 BX_C_ZB, "amoadd.h, 2, AMOADD.H", "0x1,0x2", 0
    BX_E_RRRI5 BX_C_ZB, "amoxor.h, 2, AMOXOR.H", "0x1,0x2", 0
    BX_E_RRRI5 BX_C_ZB, "amoand.h, 2, AMOAND.H", "0x1,0x2", 0
    BX_E_RRRI5 BX_C_ZB, "amoor.h, 2, AMOOR.H", "0x1,0x2", 0
    BX_E_RRRI5 BX_C_ZB, "amomax.h, 2, AMOMAX.H", "0x1,0x2", 0
    BX_E_RRRI5 BX_C_ZB, "amominu.h, 2, AMOMINU.H", "0x1,0x2", 0
    BX_POOL 0xdeadbeefc3b4a596, 0x3c3c3c3c12345678
    BX_E_RRRI5 BX_C_ZB, "amomin.h, 2, AMOMIN.H", "0x1,0x2", 0
    BX_E_RRRI5 BX_C_ZB, "amomaxu.h, 2, AMOMAXU.H", "0x1,0x2", 0

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  Strings (the register and aliasing tests; the tables name their
 *  cases inline, see the file header)
 * ======================================================================= */
    .section .rodata
str_zb_rd_ra:  .asciz "Zabha AMO rd=ra(x1) (via AMOADD.B)"
str_zb_rd_t0:  .asciz "Zabha AMO rd=t0(x5) (via AMOADD.B)"
str_zb_rd_s0:  .asciz "Zabha AMO rd=s0(x8) (via AMOADD.B)"
str_zb_rd_a0:  .asciz "Zabha AMO rd=a0(x10) (via AMOADD.B)"
str_zb_rd_s10: .asciz "Zabha AMO rd=s10(x26) (via AMOADD.B)"
str_zb_rd_t6:  .asciz "Zabha AMO rd=t6(x31) (via AMOADD.B)"
str_zb_rs1_ra:  .asciz "Zabha AMO rs1=ra(x1) (via AMOADD.B)"
str_zb_rs1_t0:  .asciz "Zabha AMO rs1=t0(x5) (via AMOADD.B)"
str_zb_rs1_s0:  .asciz "Zabha AMO rs1=s0(x8) (via AMOADD.B)"
str_zb_rs1_a0:  .asciz "Zabha AMO rs1=a0(x10) (via AMOADD.B)"
str_zb_rs1_s10: .asciz "Zabha AMO rs1=s10(x26) (via AMOADD.B)"
str_zb_rs1_t6:  .asciz "Zabha AMO rs1=t6(x31) (via AMOADD.B)"
str_zb_rs2_ra:  .asciz "Zabha AMO rs2=ra(x1) (via AMOADD.B)"
str_zb_rs2_t0:  .asciz "Zabha AMO rs2=t0(x5) (via AMOADD.B)"
str_zb_rs2_s0:  .asciz "Zabha AMO rs2=s0(x8) (via AMOADD.B)"
str_zb_rs2_a0:  .asciz "Zabha AMO rs2=a0(x10) (via AMOADD.B)"
str_zb_rs2_s10: .asciz "Zabha AMO rs2=s10(x26) (via AMOADD.B)"
str_zb_rs2_t6:  .asciz "Zabha AMO rs2=t6(x31) (via AMOADD.B)"
str_zb_rs1_sp_rd:  .asciz "Zabha AMO rs1=sp(x2) (via AMOADD.B): rd = old value"
str_zb_rs1_sp_mem: .asciz "Zabha AMO rs1=sp(x2) (via AMOADD.B): memory"
str_zb_rd_x0: .asciz "Zabha AMO rd=x0 still updates memory (via AMOADD.B)"
str_zb_swap_rs2_x0_rd:  .asciz "AMOSWAP.B rs2=x0: rd = old value"
str_zb_swap_rs2_x0_mem: .asciz "AMOSWAP.B rs2=x0: memory = 0"
str_zb_or_rs2_x0_rd:    .asciz "AMOOR.B rs2=x0 (atomic byte load): rd = old value, sign-extended"
str_zb_or_rs2_x0_mem:   .asciz "AMOOR.B rs2=x0 (atomic byte load): memory unchanged"
str_zb_swap_rd_rs2_rd:  .asciz "AMOSWAP.H rd==rs2 swaps reg and memory: rd = old memory"
str_zb_swap_rd_rs2_mem: .asciz "AMOSWAP.H rd==rs2 swaps reg and memory: memory = old rs2"
str_zb_alias_rd_rs2_rd:  .asciz "Zabha AMO rd==rs2 (via AMOADD.B): rd = old value"
str_zb_alias_rd_rs2_mem: .asciz "Zabha AMO rd==rs2 (via AMOADD.B): memory = old + old rs2"
str_zb_alias_rd_rs1_rd:  .asciz "Zabha AMO rd==rs1 (via AMOADD.B): rd = old value"
str_zb_alias_rd_rs1_mem: .asciz "Zabha AMO rd==rs1 (via AMOADD.B): memory at the old rs1"
str_zb_alias_rs1_rs2_rd:  .asciz "AMOSWAP.B rs1==rs2: rd = old value"
str_zb_alias_rs1_rs2_mem: .asciz "AMOSWAP.B rs1==rs2: memory = its own address's low byte"
str_zb_alias_rs1_rs2_add_rd:  .asciz "AMOADD.H rs1==rs2: rd = old value"
str_zb_alias_rs1_rs2_add_mem: .asciz "AMOADD.H rs1==rs2: memory = old + address's low halfword"
str_zb_alias_all_same_rd:  .asciz "AMOSWAP.H rd==rs1==rs2: rd = old value"
str_zb_alias_all_same_mem: .asciz "AMOSWAP.H rd==rs1==rs2: memory = its own address's low halfword"
str_zb_rs1_preserved: .asciz "Zabha AMO rs1 unmodified (via AMOADD.B)"
str_zb_rs2_preserved: .asciz "Zabha AMO rs2 unmodified (via AMOADD.B)"

/* =======================================================================
 *  Data
 * ======================================================================= */
    .section .bss
    .balign 8
zb_buf:    .skip 24
bx_zb_ref: .skip 8
bx_zb_dut: .skip 8
