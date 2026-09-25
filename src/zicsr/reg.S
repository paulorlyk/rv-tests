/* =====================================================================
 * zicsr/reg.S  --  Zicsr register-operand CSR instructions:
 *                   CSRRW, CSRRS, CSRRC
 *
 * Part of the Zicsr suite; see zicsr/tests.S for how this plugs into the
 * rest (main_tests.S -> zicsr/tests.S -> here), and common.S for the
 * boot/UART/reporting harness everything sits on ("check" is used from
 * there, nothing else).
 *
 * All three read the old value of the CSR into rd and write a new one
 * built from rs1: CSRRW writes rs1, CSRRS writes old | rs1, CSRRC writes
 * old & ~rs1. So every value test checks two results, rd and the CSR.
 *
 * The CSR under test is mscratch (0x340): the one M-mode CSR the spec
 * makes fully read/write at XLEN bits with no side effects, and which
 * nothing else in the firmware uses (the trap handler doesn't). mepc,
 * misa and the read-only ID CSRs appear only where a test is about the
 * csr field or the no-write rule.
 *
 * What is checked:
 *   - rd sweep and rs1 sweep through CSRRW (the register fields carry the
 *     same decode risk for all three, so, as in i/op_alu.S, they are
 *     swept once), plus rd=x0 and rs1=x0 for each instruction: CSRRW
 *     with rs1=x0 writes 0, CSRRS/CSRRC with rs1=x0 leave the CSR alone;
 *   - values for each instruction, full-width patterns so every bit of
 *     the old value, rs1 and the result matters: rd is the *old* value
 *     (never the new one), the CSR gets the new one, and CSRRS/CSRRC
 *     with a nonzero rs1 holding 0 still leave the CSR unchanged;
 *   - rd==rs1 for each: rs1 must be read before rd is written;
 *   - rs1 unmodified;
 *   - back-to-back: a CSR read in the very next instruction sees the
 *     write before it, and an rd is usable in the very next instruction;
 *   - the csr field: writing mscratch leaves mepc alone and vice versa
 *     (0x340 and 0x341 differ only in csr[0]);
 *   - no write means no trap: CSRRS and CSRRC with rs1=x0 read the
 *     read-only mhartid/mvendorid/marchid/mimpid (a write would raise an
 *     illegal-instruction exception, which common.S reports as UNEXPECTED
 *     TRAP) and agree with each other;
 *   - ... and a write does trap, even in M-mode: CSRRW (with rd and with
 *     rd=x0), and CSRRS/CSRRC with a non-x0 rs1 register that holds 0,
 *     on the read-only mvendorid/marchid/mimpid/mhartid, each raise an
 *     illegal-instruction exception (mcause 2, mepc on the instruction,
 *     mtval 0 or its bits) and leave rd unwritten. These run armed
 *     (harness.inc), so a write that wrongly goes through is a FAIL;
 *   - misa: MXL matches the image's XLEN, and I, M, A and C are set.
 * Not tested: an access to a CSR address that isn't implemented (no
 * address is guaranteed unimplemented on every hart); the side effects
 * of reads, which mscratch doesn't have; and mepc's WARL rule that
 * mepc[0] reads as 0 -- QEMU 10.0 keeps the written bit and only clears
 * it on MRET, so mepc only ever gets even values here.
 *
 * Bit independence across fields (bitx_zicsr_reg, at the end): rd and
 * rs1, C(10,2) = 45 cases per instruction, each checking rd and
 * mscratch against assemble-time constants -- see BX_C_CSR and
 * bitx.inc. The 12-bit csr field is a selector, not an operand: setting
 * two arbitrary bits of it names a different, mostly nonexistent CSR, so
 * it is held at mscratch like the opcode; the csr-field tests above
 * cover it instead.
 *
 * Built unchanged for both widths: CSR reads and writes are XLEN wide,
 * and every operation here is a copy or a bitwise op, so the LIXT
 * patterns truncate consistently on RV32.
 * ===================================================================== */

    .include "xlen.inc"
    .include "harness.inc"

    .option norvc            /* mandatory, not stylistic -- see i/loads.S */

    .include "bitx.inc"

    .global tests_zicsr_reg

    .section .text

/* Value patterns shared by most tests: old CSR value, rs1 value, and a
 * third distinct value. */
    .equ CSR_A, 0x0123456789abcdef
    .equ CSR_B, 0xf0f0f0f00ff00ff0
    .equ CSR_C, 0x00ff00ff00ff00ff

/* =======================================================================
 *  Shared macros
 * ======================================================================= */

/* T_CSR_VAL insn, init, src, exp_rd, exp_csr, nrd, ncsr -- mscratch =
 * init, then "insn t2, mscratch, t3" with t3 = src; checks rd (t2)
 * against exp_rd and the new mscratch (captured in s1) against exp_csr.
 * Truncation-safe values only (copies and bitwise ops): LIXT. */
.macro T_CSR_VAL insn, init, src, exp_rd, exp_csr, nrd, ncsr
    TEST_BEGIN \nrd
    LIXT    t0, \init
    csrw    mscratch, t0
    LIXT    t3, \src
    \insn   t2, mscratch, t3
    csrr    s1, mscratch
    la      a0, \nrd
    LIXT    a1, \exp_rd
    mv      a2, t2
    call    check
    TEST_BEGIN \ncsr
    la      a0, \ncsr
    LIXT    a1, \exp_csr
    mv      a2, s1
    call    check
.endm

/* T_CSR_RD rdreg, name -- CSRRW with rd = rdreg (mscratch = CSR_A,
 * rs1 = t3 = CSR_B): rdreg must receive CSR_A. Captured into t2 before
 * a0-a2 are loaded (rdreg may be a0). t0 and t3 are free in the sweep
 * list sense: t0 is dead once mscratch is set, t3 is not a candidate. */
.macro T_CSR_RD rdreg, name
    TEST_BEGIN \name
    LIXT    t0, CSR_A
    csrw    mscratch, t0
    LIXT    t3, CSR_B
    csrrw   \rdreg, mscratch, t3
    mv      t2, \rdreg
    la      a0, \name
    LIXT    a1, CSR_A
    mv      a2, t2
    call    check
.endm

/* T_CSR_RS1 rs1reg, name -- CSRRW with rs1 = rs1reg = CSR_B over
 * mscratch = CSR_A: mscratch must become CSR_B. mscratch is set up
 * through t0 before rs1reg is loaded, so rs1reg = t0 is safe. */
.macro T_CSR_RS1 rs1reg, name
    TEST_BEGIN \name
    LIXT    t0, CSR_A
    csrw    mscratch, t0
    LIXT    \rs1reg, CSR_B
    csrrw   t2, mscratch, \rs1reg
    csrr    t2, mscratch
    la      a0, \name
    LIXT    a1, CSR_B
    mv      a2, t2
    call    check
.endm

/* T_CSR_RDX0 insn, exp_csr, name -- rd=x0 (for CSRRW: the csrw idiom):
 * the write still happens. mscratch = CSR_A, rs1 = CSR_B. */
.macro T_CSR_RDX0 insn, exp_csr, name
    TEST_BEGIN \name
    LIXT    t0, CSR_A
    csrw    mscratch, t0
    LIXT    t3, CSR_B
    \insn   x0, mscratch, t3
    csrr    t2, mscratch
    la      a0, \name
    LIXT    a1, \exp_csr
    mv      a2, t2
    call    check
.endm

/* T_CSR_RS1X0 insn, exp_csr, nrd, ncsr -- rs1=x0: rd still reads the
 * old value; CSRRW writes 0, CSRRS/CSRRC write nothing. */
.macro T_CSR_RS1X0 insn, exp_csr, nrd, ncsr
    TEST_BEGIN \nrd
    LIXT    t0, CSR_A
    csrw    mscratch, t0
    \insn   t2, mscratch, x0
    csrr    s1, mscratch
    la      a0, \nrd
    LIXT    a1, CSR_A
    mv      a2, t2
    call    check
    TEST_BEGIN \ncsr
    la      a0, \ncsr
    LIXT    a1, \exp_csr
    mv      a2, s1
    call    check
.endm

/* T_CSR_ALIAS insn, exp_csr, nrd, ncsr -- rd==rs1 (t1): the old rs1 is
 * the operand, and rd then receives the old CSR value. */
.macro T_CSR_ALIAS insn, exp_csr, nrd, ncsr
    TEST_BEGIN \nrd
    LIXT    t0, CSR_A
    csrw    mscratch, t0
    LIXT    t1, CSR_B
    \insn   t1, mscratch, t1
    csrr    s1, mscratch
    mv      t2, t1
    la      a0, \nrd
    LIXT    a1, CSR_A
    mv      a2, t2
    call    check
    TEST_BEGIN \ncsr
    la      a0, \ncsr
    LIXT    a1, \exp_csr
    mv      a2, s1
    call    check
.endm

/* T_CSR_PRESERVED insn, name -- rs1 is not written. */
.macro T_CSR_PRESERVED insn, name
    TEST_BEGIN \name
    LIXT    t0, CSR_A
    csrw    mscratch, t0
    LIXT    t3, CSR_B
    \insn   t2, mscratch, t3
    mv      t4, t3
    la      a0, \name
    LIXT    a1, CSR_B
    mv      a2, t4
    call    check
.endm

/* BX_C_CSR insn, nm, kind, rd, rs1 -- one bit-independence case
 * (bitx.inc). mscratch = va (the pool's first value, set through the
 * fixed csrw x0/t4 encoding), rd = sentinel, rs1 = vb (loaded after rd,
 * so rd==rs1 reads vb), then "insn x<rd>, mscratch, x<rs1>". Two checks:
 * rd = va, and mscratch = kind's result -- 0: vb (CSRRW), 1: va | vb
 * (CSRRS), 2: va & ~vb (CSRRC) -- both assemble-time constants, so no
 * reference encoding shares the rd/rs1 bits under test. mscratch is
 * captured into s3 (reserved scratch, never a candidate) straight away;
 * no memory is touched between the instruction and BX_REPORT's
 * BX_LEAVE, so rd may be sp/gp/tp. rs1 is never x0 (its background is
 * t3), so every case writes. */
.macro BX_C_CSR insn, nm, kind, rd, rs1
    BX_ENTER
    BX_PV   t4, 0
    csrw    mscratch, t4
    BX_PV   x\rd, 2
    BX_PV   x\rs1, 1
    \insn   x\rd, mscratch, x\rs1
    csrr    s3, mscratch
    mv      t6, x\rd
    BX_LDC  t5, CSR_A
    BX_REPORT "\nm bitx rd=x\rd rs1=x\rs1 rd"
    .if \kind == 0
    BX_LDC  t5, CSR_B
    .elseif \kind == 1
    BX_LDC  t5, (CSR_A|CSR_B)
    .else
    BX_LDC  t5, (CSR_A&~CSR_B)
    .endif
    mv      t6, s3
    BX_REPORT "\nm bitx rd=x\rd rs1=x\rs1 csr"
.endm

/* T_CSR_RO rd, desc, insn... -- \insn writes a read-only M-mode CSR
 * (CSRRW, or CSRRS/CSRRC with rs1 = a4), in M-mode, with rd = a3 when rd = 1 and a4 = 0: it must
 * raise an illegal-instruction exception whatever the value written,
 * and leave rd alone. Run armed (TRAP_ARM, harness.inc), so a write
 * that wrongly goes through falls through to a FAIL, never a hang.
 * trap_mcause is set to -1 first so a stale record can't pass the
 * cause check. Checks: exactly one trap, mcause 2, mepc on the
 * instruction, mtval 0 or its bits, rd unchanged. Uses s2-s4, clobbers
 * t0-t3, a3, a4. */
.macro T_CSR_RO rd, desc, insn:vararg
    .pushsection .rodata
.Lro_once\@:  .asciz "\desc: traps exactly once"
.Lro_cause\@: .asciz "\desc: mcause == 2 (illegal instruction)"
.Lro_mepc\@:  .asciz "\desc: mepc == the instruction"
.Lro_mtval\@: .asciz "\desc: mtval == 0 or the instruction"
    .if \rd
.Lro_rd\@:    .asciz "\desc: rd not written"
    .endif
    .popsection
    TEST_BEGIN .Lro_once\@
    .option push
    .option norelax
    lw      s3, trap_count
    la      s2, .Lro_at\@
    la      t0, trap_mcause
    .option pop
    li      t1, -1
    REG_S   t1, 0(t0)
    li      a4, 0
    LIXT    a3, 0x5ac3a55a3cc3a5c3
    TRAP_ARM .Lro_back\@
.Lro_at\@:
    \insn
    TRAP_DISARM                     /* no trap: disarm, then FAIL */
.Lro_back\@:
    mv      s4, a3
    .option push
    .option norelax
    lw      t0, trap_count
    .option pop
    sub     s3, t0, s3
    la      a0, .Lro_once\@
    li      a1, 1
    mv      a2, s3
    call    check
    TEST_BEGIN .Lro_cause\@
    TRAP_LD t2, mcause
    la      a0, .Lro_cause\@
    li      a1, 2
    mv      a2, t2
    call    check
    TEST_BEGIN .Lro_mepc\@
    TRAP_LD t2, mepc
    la      a0, .Lro_mepc\@
    mv      a1, s2
    mv      a2, t2
    call    check
    TEST_BEGIN .Lro_mtval\@
    TRAP_LD t2, mtval
    li      t3, 0
    beqz    t2, 1f
    LWUX    t3, 0(s2)
1:  la      a0, .Lro_mtval\@
    mv      a1, t3
    mv      a2, t2
    call    check
    .if \rd
    TEST_BEGIN .Lro_rd\@
    la      a0, .Lro_rd\@
    LIXT    a1, 0x5ac3a55a3cc3a5c3
    mv      a2, s4
    call    check
    .endif
.endm

tests_zicsr_reg:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    jal     ra, test_csr_fields
    jal     ra, test_csr_values
    jal     ra, test_csr_order
    jal     ra, test_csr_select
    jal     ra, test_csr_ro_write

    jal     ra, bitx_zicsr_reg

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  Register fields: rd / rs1 sweeps (through CSRRW), x0, aliasing,
 *  sources preserved
 * ======================================================================= */
test_csr_fields:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    T_CSR_RD ra,  str_csr_rd_ra
    T_CSR_RD t0,  str_csr_rd_t0
    T_CSR_RD s0,  str_csr_rd_s0
    T_CSR_RD a0,  str_csr_rd_a0
    T_CSR_RD s10, str_csr_rd_s10
    T_CSR_RD t6,  str_csr_rd_t6

    T_CSR_RS1 ra,  str_csr_rs1_ra
    T_CSR_RS1 t0,  str_csr_rs1_t0
    T_CSR_RS1 s0,  str_csr_rs1_s0
    T_CSR_RS1 a0,  str_csr_rs1_a0
    T_CSR_RS1 s10, str_csr_rs1_s10
    T_CSR_RS1 t6,  str_csr_rs1_t6

    /* rd=x0: the write still happens */
    T_CSR_RDX0 csrrw, CSR_B,              str_csrrw_rdx0
    T_CSR_RDX0 csrrs, (CSR_A|CSR_B),    str_csrrs_rdx0
    T_CSR_RDX0 csrrc, (CSR_A&~CSR_B),   str_csrrc_rdx0

    /* rs1=x0: CSRRW writes zero, CSRRS/CSRRC write nothing */
    T_CSR_RS1X0 csrrw, 0,     str_csrrw_rs1x0_rd, str_csrrw_rs1x0_csr
    T_CSR_RS1X0 csrrs, CSR_A, str_csrrs_rs1x0_rd, str_csrrs_rs1x0_csr
    T_CSR_RS1X0 csrrc, CSR_A, str_csrrc_rs1x0_rd, str_csrrc_rs1x0_csr

    /* rd==rs1 */
    T_CSR_ALIAS csrrw, CSR_B,            str_csrrw_alias_rd, str_csrrw_alias_csr
    T_CSR_ALIAS csrrs, (CSR_A|CSR_B),  str_csrrs_alias_rd, str_csrrs_alias_csr
    T_CSR_ALIAS csrrc, (CSR_A&~CSR_B), str_csrrc_alias_rd, str_csrrc_alias_csr

    /* rs1 unmodified */
    T_CSR_PRESERVED csrrw, str_csrrw_preserved
    T_CSR_PRESERVED csrrs, str_csrrs_preserved
    T_CSR_PRESERVED csrrc, str_csrrc_preserved

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  Values
 * ======================================================================= */
test_csr_values:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    /* --- CSRRW: rd = old, CSR = rs1 --- */
    T_CSR_VAL csrrw, CSR_A, CSR_B, CSR_A, CSR_B, str_csrrw_ab_rd, str_csrrw_ab_csr
    T_CSR_VAL csrrw, 0, -1, 0, -1, str_csrrw_ones_rd, str_csrrw_ones_csr
    T_CSR_VAL csrrw, -1, 0, -1, 0, str_csrrw_zero_rd, str_csrrw_zero_csr
    T_CSR_VAL csrrw, CSR_A, CSR_A, CSR_A, CSR_A, str_csrrw_same_rd, str_csrrw_same_csr

    /* --- CSRRS: rd = old, CSR = old | rs1 --- */
    T_CSR_VAL csrrs, CSR_A, CSR_B, CSR_A, (CSR_A|CSR_B), str_csrrs_ab_rd, str_csrrs_ab_csr
    T_CSR_VAL csrrs, 0, -1, 0, -1, str_csrrs_ones_rd, str_csrrs_ones_csr
    T_CSR_VAL csrrs, CSR_A, 0, CSR_A, CSR_A, str_csrrs_zero_rd, str_csrrs_zero_csr
    TEST_BEGIN str_csrrs_top
    csrw    mscratch, x0
    LIX     t3, INTX_MIN
    csrrs   t2, mscratch, t3
    csrr    s1, mscratch
    la      a0, str_csrrs_top
    LIX     a1, INTX_MIN
    mv      a2, s1
    call    check

    /* --- CSRRC: rd = old, CSR = old & ~rs1 --- */
    T_CSR_VAL csrrc, CSR_A, CSR_B, CSR_A, (CSR_A&~CSR_B), str_csrrc_ab_rd, str_csrrc_ab_csr
    T_CSR_VAL csrrc, -1, -1, -1, 0, str_csrrc_ones_rd, str_csrrc_ones_csr
    T_CSR_VAL csrrc, CSR_A, 0, CSR_A, CSR_A, str_csrrc_zero_rd, str_csrrc_zero_csr
    TEST_BEGIN str_csrrc_top
    LIX     t0, -1
    csrw    mscratch, t0
    LIX     t3, INTX_MIN
    csrrc   t2, mscratch, t3
    csrr    s1, mscratch
    la      a0, str_csrrc_top
    LIX     a1, INTX_MAX
    mv      a2, s1
    call    check

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  Back-to-back: no stale CSR or rd value in the next instruction
 * ======================================================================= */
test_csr_order:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    /* --- two CSRRWs in a row: the second reads what the first wrote --- */
    TEST_BEGIN str_csr_b2b_first
    LIXT    t0, CSR_A
    csrw    mscratch, t0
    LIXT    t3, CSR_B
    LIXT    t4, CSR_C
    csrrw   t1, mscratch, t3
    csrrw   t2, mscratch, t4
    csrr    s1, mscratch
    mv      s2, t1
    mv      s4, t2
    la      a0, str_csr_b2b_first
    LIXT    a1, CSR_A
    mv      a2, s2
    call    check
    TEST_BEGIN str_csr_b2b_second
    la      a0, str_csr_b2b_second
    LIXT    a1, CSR_B
    mv      a2, s4
    call    check
    TEST_BEGIN str_csr_b2b_final
    la      a0, str_csr_b2b_final
    LIXT    a1, CSR_C
    mv      a2, s1
    call    check

    /* --- CSRRS then CSRRC in a row (read-modify-write on the result of
     *     a read-modify-write) --- */
    TEST_BEGIN str_csr_sc_mid
    csrw    mscratch, x0
    LIXT    t3, CSR_B
    LIXT    t4, CSR_C
    csrrs   x0, mscratch, t3
    csrrc   t2, mscratch, t4
    csrr    s1, mscratch
    mv      s2, t2
    la      a0, str_csr_sc_mid
    LIXT    a1, CSR_B
    mv      a2, s2
    call    check
    TEST_BEGIN str_csr_sc_final
    la      a0, str_csr_sc_final
    LIXT    a1, (CSR_B&~CSR_C)
    mv      a2, s1
    call    check

    /* --- rd consumed by the very next instruction --- */
    TEST_BEGIN str_csr_rd_fwd
    LIXT    t0, CSR_A
    csrw    mscratch, t0
    LIXT    t3, CSR_B
    csrrw   t1, mscratch, t3
    add     t2, t1, t1
    la      a0, str_csr_rd_fwd
    LIXT    a1, (CSR_A+CSR_A)
    mv      a2, t2
    call    check

    /* --- a register written right before is the CSRRS operand --- */
    TEST_BEGIN str_csr_rs1_fwd
    csrw    mscratch, x0
    LIXT    t3, CSR_A
    addi    t3, t3, 1
    csrrs   x0, mscratch, t3
    csrr    t2, mscratch
    la      a0, str_csr_rs1_fwd
    LIXT    a1, (CSR_A+1)
    mv      a2, t2
    call    check

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  The csr field: distinct CSRs, read-only CSRs, misa
 * ======================================================================= */
test_csr_select:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    /* --- mscratch (0x340) and mepc (0x341) differ only in csr[0]: each
     *     keeps its own value. mepc gets an even value, so its WARL
     *     rule (mepc[0] = 0) doesn't come into it. --- */
    TEST_BEGIN str_csr_sel_mscratch
    LIXT    t0, CSR_A
    LIXT    t1, (CSR_B&~1)
    csrrw   x0, mscratch, t0
    csrrw   x0, mepc, t1
    csrrs   s1, mscratch, x0
    csrrs   s2, mepc, x0
    la      a0, str_csr_sel_mscratch
    LIXT    a1, CSR_A
    mv      a2, s1
    call    check
    TEST_BEGIN str_csr_sel_mepc
    la      a0, str_csr_sel_mepc
    LIXT    a1, (CSR_B&~1)
    mv      a2, s2
    call    check

    /* --- the same the other way round: mepc written first, then
     *     mscratch --- */
    TEST_BEGIN str_csr_sel_mepc2
    LIXT    t0, CSR_C
    LIXT    t1, (CSR_A&~1)
    csrrw   x0, mepc, t1
    csrrw   x0, mscratch, t0
    csrrs   s2, mepc, x0
    la      a0, str_csr_sel_mepc2
    LIXT    a1, (CSR_A&~1)
    mv      a2, s2
    call    check

    /* --- read-only CSRs: CSRRS/CSRRC with rs1=x0 don't write, so they
     *     must not trap, and must agree --- */
    TEST_BEGIN str_csr_ro_mhartid
    csrrs   s1, mhartid, x0
    csrrc   s2, mhartid, x0
    la      a0, str_csr_ro_mhartid
    mv      a1, s1
    mv      a2, s2
    call    check

    TEST_BEGIN str_csr_ro_mvendorid
    csrrs   s1, mvendorid, x0
    csrrc   s2, mvendorid, x0
    la      a0, str_csr_ro_mvendorid
    mv      a1, s1
    mv      a2, s2
    call    check

    TEST_BEGIN str_csr_ro_marchid
    csrrs   s1, marchid, x0
    csrrc   s2, marchid, x0
    la      a0, str_csr_ro_marchid
    mv      a1, s1
    mv      a2, s2
    call    check

    TEST_BEGIN str_csr_ro_mimpid
    csrrs   s1, mimpid, x0
    csrrc   s2, mimpid, x0
    la      a0, str_csr_ro_mimpid
    mv      a1, s1
    mv      a2, s2
    call    check

    /* --- misa: MXL (the top two bits) = 2 on RV64, 1 on RV32; and the
     *     extensions this image is built for (A = bit 0, C = 2, I = 8,
     *     M = 12) are reported --- */
    TEST_BEGIN str_csr_misa_mxl
    csrrs   s1, misa, x0
    srli    t2, s1, XLEN - 2
    la      a0, str_csr_misa_mxl
    .if XLEN == 64
    LIX     a1, 2
    .else
    LIX     a1, 1
    .endif
    mv      a2, t2
    call    check

    TEST_BEGIN str_csr_misa_imac
    LIX     t0, ((1<<0)|(1<<2)|(1<<8)|(1<<12))
    and     t2, s1, t0
    la      a0, str_csr_misa_imac
    LIX     a1, ((1<<0)|(1<<2)|(1<<8)|(1<<12))
    mv      a2, t2
    call    check

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* Bit independence across fields -- see the file header, BX_C_CSR and
 * bitx.inc. rd background t2 (x7), rs1 background t3 (x28); csr fixed
 * at mscratch. */
/* =======================================================================
 *  Writes to read-only CSRs trap, in M-mode too
 * ======================================================================= */
test_csr_ro_write:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    T_CSR_RO 1, "CSRRW rd, mvendorid, rs1 (M-mode)", csrrw a3, mvendorid, a4
    T_CSR_RO 0, "CSRRW x0, mhartid, rs1 (M-mode)", csrrw x0, mhartid, a4
    T_CSR_RO 1, "CSRRS rd, marchid, rs1 holding 0 (M-mode)", csrrs a3, marchid, a4
    T_CSR_RO 1, "CSRRC rd, mimpid, rs1 holding 0 (M-mode)", csrrc a3, mimpid, a4

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

bitx_zicsr_reg:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    BX_POOL CSR_A, CSR_B
    BX_E_RR5 BX_C_CSR, "csrrw, CSRRW, 0", 7, 28
    BX_E_RR5 BX_C_CSR, "csrrs, CSRRS, 1", 7, 28
    BX_E_RR5 BX_C_CSR, "csrrc, CSRRC, 2", 7, 28

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  Strings
 * ======================================================================= */
    .section .rodata
str_csr_rd_ra:          .asciz "CSRRW rd=ra"
str_csr_rd_t0:          .asciz "CSRRW rd=t0"
str_csr_rd_s0:          .asciz "CSRRW rd=s0"
str_csr_rd_a0:          .asciz "CSRRW rd=a0"
str_csr_rd_s10:         .asciz "CSRRW rd=s10"
str_csr_rd_t6:          .asciz "CSRRW rd=t6"
str_csr_rs1_ra:         .asciz "CSRRW rs1=ra"
str_csr_rs1_t0:         .asciz "CSRRW rs1=t0"
str_csr_rs1_s0:         .asciz "CSRRW rs1=s0"
str_csr_rs1_a0:         .asciz "CSRRW rs1=a0"
str_csr_rs1_s10:        .asciz "CSRRW rs1=s10"
str_csr_rs1_t6:         .asciz "CSRRW rs1=t6"

str_csrrw_rdx0:         .asciz "CSRRW rd=x0 (csrw) still writes"
str_csrrs_rdx0:         .asciz "CSRRS rd=x0 (csrs) still sets"
str_csrrc_rdx0:         .asciz "CSRRC rd=x0 (csrc) still clears"
str_csrrw_rs1x0_rd:     .asciz "CSRRW rs1=x0: rd = old value"
str_csrrw_rs1x0_csr:    .asciz "CSRRW rs1=x0: CSR = 0"
str_csrrs_rs1x0_rd:     .asciz "CSRRS rs1=x0 (csrr): rd = old value"
str_csrrs_rs1x0_csr:    .asciz "CSRRS rs1=x0 (csrr): CSR unchanged"
str_csrrc_rs1x0_rd:     .asciz "CSRRC rs1=x0: rd = old value"
str_csrrc_rs1x0_csr:    .asciz "CSRRC rs1=x0: CSR unchanged"
str_csrrw_alias_rd:     .asciz "CSRRW rd==rs1: rd = old CSR"
str_csrrw_alias_csr:    .asciz "CSRRW rd==rs1: CSR = old rs1"
str_csrrs_alias_rd:     .asciz "CSRRS rd==rs1: rd = old CSR"
str_csrrs_alias_csr:    .asciz "CSRRS rd==rs1: CSR = old | old rs1"
str_csrrc_alias_rd:     .asciz "CSRRC rd==rs1: rd = old CSR"
str_csrrc_alias_csr:    .asciz "CSRRC rd==rs1: CSR = old & ~old rs1"
str_csrrw_preserved:    .asciz "CSRRW leaves rs1 unchanged"
str_csrrs_preserved:    .asciz "CSRRS leaves rs1 unchanged"
str_csrrc_preserved:    .asciz "CSRRC leaves rs1 unchanged"

str_csrrw_ab_rd:        .asciz "CSRRW pattern: rd = old value"
str_csrrw_ab_csr:       .asciz "CSRRW pattern: CSR = rs1"
str_csrrw_ones_rd:      .asciz "CSRRW 0 <- all ones: rd = 0"
str_csrrw_ones_csr:     .asciz "CSRRW 0 <- all ones: CSR = all ones"
str_csrrw_zero_rd:      .asciz "CSRRW all ones <- 0: rd = all ones"
str_csrrw_zero_csr:     .asciz "CSRRW all ones <- 0: CSR = 0"
str_csrrw_same_rd:      .asciz "CSRRW same value: rd = old value"
str_csrrw_same_csr:     .asciz "CSRRW same value: CSR unchanged"
str_csrrs_ab_rd:        .asciz "CSRRS pattern: rd = old value"
str_csrrs_ab_csr:       .asciz "CSRRS pattern: CSR = old | rs1"
str_csrrs_ones_rd:      .asciz "CSRRS 0 | all ones: rd = 0"
str_csrrs_ones_csr:     .asciz "CSRRS 0 | all ones: CSR = all ones"
str_csrrs_zero_rd:      .asciz "CSRRS rs1 (not x0) = 0: rd = old value"
str_csrrs_zero_csr:     .asciz "CSRRS rs1 (not x0) = 0: CSR unchanged"
str_csrrs_top:          .asciz "CSRRS sets the top bit"
str_csrrc_ab_rd:        .asciz "CSRRC pattern: rd = old value"
str_csrrc_ab_csr:       .asciz "CSRRC pattern: CSR = old & ~rs1"
str_csrrc_ones_rd:      .asciz "CSRRC all ones & ~all ones: rd = all ones"
str_csrrc_ones_csr:     .asciz "CSRRC all ones & ~all ones: CSR = 0"
str_csrrc_zero_rd:      .asciz "CSRRC rs1 (not x0) = 0: rd = old value"
str_csrrc_zero_csr:     .asciz "CSRRC rs1 (not x0) = 0: CSR unchanged"
str_csrrc_top:          .asciz "CSRRC clears only the top bit"

str_csr_b2b_first:      .asciz "CSRRW back-to-back: first rd = original"
str_csr_b2b_second:     .asciz "CSRRW back-to-back: second rd = first write"
str_csr_b2b_final:      .asciz "CSRRW back-to-back: CSR = second write"
str_csr_sc_mid:         .asciz "CSRRS then CSRRC: CSRRC reads CSRRS's result"
str_csr_sc_final:       .asciz "CSRRS then CSRRC: CSR = set, then cleared"
str_csr_rd_fwd:         .asciz "CSRRW rd used by the next instruction"
str_csr_rs1_fwd:        .asciz "CSRRS rs1 written by the previous instruction"

str_csr_sel_mscratch:   .asciz "CSRRW csr field: mscratch keeps its value after a mepc write"
str_csr_sel_mepc:       .asciz "CSRRW csr field: mepc holds its own value"
str_csr_sel_mepc2:      .asciz "CSRRW csr field: mepc keeps its value after a mscratch write"
str_csr_ro_mhartid:     .asciz "CSRRS rs1=x0 read mhartid, no trap, CSRRC agrees"
str_csr_ro_mvendorid:   .asciz "CSRRS rs1=x0 read mvendorid, no trap, CSRRC agrees"
str_csr_ro_marchid:     .asciz "CSRRS rs1=x0 read marchid, no trap, CSRRC agrees"
str_csr_ro_mimpid:      .asciz "CSRRS rs1=x0 read mimpid, no trap, CSRRC agrees"
    .if XLEN == 64
str_csr_misa_mxl:       .asciz "CSRRS reads misa.MXL = 2 (RV64)"
    .else
str_csr_misa_mxl:       .asciz "CSRRS reads misa.MXL = 1 (RV32)"
    .endif
str_csr_misa_imac:      .asciz "CSRRS reads misa: reports I, M, A, C"
