/* =====================================================================
 * zicsr/imm.S  --  Zicsr immediate-operand CSR instructions:
 *                   CSRRWI, CSRRSI, CSRRCI
 *
 * Part of the Zicsr suite; see zicsr/tests.S for how this plugs into the
 * rest (main_tests.S -> zicsr/tests.S -> here), and common.S for the
 * boot/UART/reporting harness everything sits on ("check" is used from
 * there, nothing else).
 *
 * The immediate twins of zicsr/reg.S's CSRRW/CSRRS/CSRRC: the 5-bit
 * uimm sits where rs1 would be and is ZERO-extended to XLEN. So the
 * risks are different from the register forms:
 *   - zero extension: uimm=31 is 0x1f, not -1. CSRRWI 31 writes 0x1f,
 *     CSRRSI 31 sets only the low five bits and CSRRCI 31 clears only
 *     them, over old values whose upper bits would show a sign
 *     extension;
 *   - every uimm bit walked on its own (1, 2, 4, 8, 16) for each of the
 *     three, plus 0 and 31;
 *   - the uimm is not a register number: each instruction runs with the
 *     register x[uimm] holding a value that would give a different
 *     answer if it were read instead;
 *   - uimm=0: CSRRWI writes 0, CSRRSI/CSRRCI write nothing, so with
 *     uimm=0 they read the read-only mhartid/mimpid and the WARL misa
 *     without trapping and agree with CSRRS rs1=x0 (zicsr/reg.S covers
 *     that form itself); one instruction per test, run armed, so a
 *     trap is a FAIL under that instruction's own name;
 *   - rd = old value for each; rd sweep through CSRRWI; rd=x0 for each
 *     (the write still happens);
 *   - a write to a read-only CSR traps, in M-mode too: CSRRWI (with
 *     uimm 0: it writes regardless) on mhartid, and CSRRSI/CSRRCI with a
 *     nonzero uimm on mvendorid/marchid, each raise an
 *     illegal-instruction exception (mcause 2, mepc on the instruction,
 *     mtval 0 or its bits) and leave rd unwritten. Run armed
 *     (harness.inc), so a write that goes through is a FAIL.
 * mscratch is the CSR under test, as in zicsr/reg.S.
 *
 * Bit independence across fields (bitx_zicsr_imm, at the end): rd and
 * uimm, C(10,2) = 45 cases per instruction, each checking rd and
 * mscratch against assemble-time constants -- see BX_C_CSRI and
 * bitx.inc. The csr field is held at mscratch, for the reason given in
 * zicsr/reg.S's header.
 *
 * Built unchanged for both widths: copies and bitwise ops only, so the
 * LIXT patterns truncate consistently on RV32.
 * ===================================================================== */

    .include "xlen.inc"
    .include "harness.inc"

    .option norvc            /* mandatory, not stylistic -- see i/loads.S */

    .include "bitx.inc"

    .global tests_zicsr_imm

    .section .text

/* Old CSR values: CSRI_A for CSRRWI (anything with upper bits set),
 * CSRI_P for CSRRSI (low five bits clear, upper bits a pattern), all
 * ones for CSRRCI. The bitx cases use CSRI_A, CSRI_P and CSRI_Q (low
 * five bits set): uimm bits are data bits, so setting one that is
 * already set, or clearing one that is already clear, would be
 * invisible. */
    .equ CSRI_A, 0x0123456789abcdef
    .equ CSRI_P, 0xa5a5a5a5a5a5a5a0
    .equ CSRI_Q, 0x5a5a5a5a5a5a5a5f

/* =======================================================================
 *  Shared macros
 * ======================================================================= */

/* T_CSRI_CSR insn, init, uimm, exp_csr, name -- mscratch = init,
 * "insn t2, mscratch, uimm", check the new mscratch. */
.macro T_CSRI_CSR insn, init, uimm, exp_csr, name
    TEST_BEGIN \name
    LIXT    t0, \init
    csrw    mscratch, t0
    \insn   t2, mscratch, \uimm
    csrr    t2, mscratch
    la      a0, \name
    LIXT    a1, \exp_csr
    mv      a2, t2
    call    check
.endm

/* T_CSRI_OLD insn, init, uimm, name -- rd receives the old value. */
.macro T_CSRI_OLD insn, init, uimm, name
    TEST_BEGIN \name
    LIXT    t0, \init
    csrw    mscratch, t0
    \insn   t2, mscratch, \uimm
    la      a0, \name
    LIXT    a1, \init
    mv      a2, t2
    call    check
.endm

/* T_CSRI_RD rdreg, name -- CSRRWI with rd = rdreg (mscratch = CSRI_A,
 * uimm = 21): rdreg must receive CSRI_A. Captured into t2 before a0-a2
 * are loaded. */
.macro T_CSRI_RD rdreg, name
    TEST_BEGIN \name
    LIXT    t0, CSRI_A
    csrw    mscratch, t0
    csrrwi  \rdreg, mscratch, 21
    mv      t2, \rdreg
    la      a0, \name
    LIXT    a1, CSRI_A
    mv      a2, t2
    call    check
.endm

/* T_CSRI_RDX0 insn, init, uimm, exp_csr, name -- rd=x0 still writes. */
.macro T_CSRI_RDX0 insn, init, uimm, exp_csr, name
    TEST_BEGIN \name
    LIXT    t0, \init
    csrw    mscratch, t0
    \insn   x0, mscratch, \uimm
    csrr    t2, mscratch
    la      a0, \name
    LIXT    a1, \exp_csr
    mv      a2, t2
    call    check
.endm

/* T_CSRI_NOTREG insn, init, uimm, xreg, xval, exp_csr, name -- the
 * register numbered uimm (xreg) holds xval, which would give a
 * different result if the uimm were decoded as rs1. xreg is loaded
 * after mscratch is set up (so xreg = t0 is fine). */
.macro T_CSRI_NOTREG insn, init, uimm, xreg, xval, exp_csr, name
    TEST_BEGIN \name
    LIXT    t0, \init
    csrw    mscratch, t0
    LIXT    \xreg, \xval
    \insn   t2, mscratch, \uimm
    csrr    t2, mscratch
    la      a0, \name
    LIXT    a1, \exp_csr
    mv      a2, t2
    call    check
.endm

/* BX_C_CSRI insn, nm, kind, va, rd, u -- one bit-independence case
 * (bitx.inc): mscratch = va (the pool's first value, which must be va;
 * set through csrw x0/t4), rd = sentinel, "insn x<rd>, mscratch, u".
 * Checks rd = va and mscratch = kind's result -- 0: u (CSRRWI), 1:
 * va | u (CSRRSI), 2: va & ~u (CSRRCI) -- both assemble-time constants.
 * Same capture rules as zicsr/reg.S's BX_C_CSR. */
.macro BX_C_CSRI insn, nm, kind, va, rd, u
    BX_ENTER
    BX_PV   t4, 0
    csrw    mscratch, t4
    BX_PV   x\rd, 2
    \insn   x\rd, mscratch, \u
    csrr    s3, mscratch
    mv      t6, x\rd
    BX_LDC  t5, \va
    BX_REPORT "\nm bitx rd=x\rd uimm=\u rd"
    .if \kind == 0
    BX_LDC  t5, (\u)
    .elseif \kind == 1
    BX_LDC  t5, ((\va) | (\u))
    .else
    BX_LDC  t5, ((\va) & ~(\u))
    .endif
    mv      t6, s3
    BX_REPORT "\nm bitx rd=x\rd uimm=\u csr"
.endm

/* T_CSRI_RO0 insn, csr, name -- "insn s2, csr, 0" (CSRRSI/CSRRCI,
 * uimm=0: no write) on a read-only or WARL CSR must not trap and must
 * read what CSRRS csr, x0 reads (s1). One instruction per test, so a
 * trap is reported under its own name. s2 is poisoned to ~s1 first, so
 * an instruction that doesn't write rd fails. Run armed (TRAP_ARM,
 * harness.inc), reference read included: a trap is a FAIL with its
 * mcause, never an UNEXPECTED TRAP hang. Uses s1, s2. */
.macro T_CSRI_RO0 insn, csr, name
    TEST_BEGIN \name
    TRAP_ARM .Lro0_trap\@
    csrrs   s1, \csr, x0
    not     s2, s1
    \insn   s2, \csr, 0
    TRAP_DISARM
    la      a0, \name
    mv      a1, s1
    mv      a2, s2
    call    check
    TRAP_FAILS .Lro0_trap\@, \name
.endm

/* T_CSRI_RO rd, desc, insn... -- \insn writes a read-only M-mode CSR
 * (CSRRWI, or CSRRSI/CSRRCI with a nonzero uimm), in M-mode, with rd = a3 when rd = 1 and a4 = 0: it must
 * raise an illegal-instruction exception whatever the value written,
 * and leave rd alone. Run armed (TRAP_ARM, harness.inc), so a write
 * that wrongly goes through falls through to a FAIL, never a hang.
 * trap_mcause is set to -1 first so a stale record can't pass the
 * cause check. Checks: exactly one trap, mcause 2, mepc on the
 * instruction, mtval 0 or its bits, rd unchanged. Uses s2-s4, clobbers
 * t0-t3, a3, a4. */
.macro T_CSRI_RO rd, desc, insn:vararg
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

tests_zicsr_imm:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    jal     ra, test_csri_fields
    jal     ra, test_csri_values
    jal     ra, test_csri_readonly
    jal     ra, test_csri_ro_write

    jal     ra, bitx_zicsr_imm

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  rd sweep (through CSRRWI), rd=x0, rd = old value
 * ======================================================================= */
test_csri_fields:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    T_CSRI_RD ra,  str_csri_rd_ra
    T_CSRI_RD t0,  str_csri_rd_t0
    T_CSRI_RD s0,  str_csri_rd_s0
    T_CSRI_RD a0,  str_csri_rd_a0
    T_CSRI_RD s10, str_csri_rd_s10
    T_CSRI_RD t6,  str_csri_rd_t6

    T_CSRI_RDX0 csrrwi, CSRI_A, 21, 21,             str_csrrwi_rdx0
    T_CSRI_RDX0 csrrsi, CSRI_P, 21, (CSRI_P|21),    str_csrrsi_rdx0
    T_CSRI_RDX0 csrrci, -1,     21, ~21,            str_csrrci_rdx0

    T_CSRI_OLD csrrwi, CSRI_A, 21, str_csrrwi_old
    T_CSRI_OLD csrrsi, CSRI_P, 21, str_csrrsi_old
    T_CSRI_OLD csrrci, -1,     21, str_csrrci_old

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  uimm values: every bit, 0, 31, zero extension, not a register
 * ======================================================================= */
test_csri_values:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    /* --- CSRRWI: CSR = zero-extended uimm --- */
    T_CSRI_CSR csrrwi, CSRI_A, 0,  0,    str_csrrwi_0
    T_CSRI_CSR csrrwi, CSRI_A, 1,  1,    str_csrrwi_1
    T_CSRI_CSR csrrwi, CSRI_A, 2,  2,    str_csrrwi_2
    T_CSRI_CSR csrrwi, CSRI_A, 4,  4,    str_csrrwi_4
    T_CSRI_CSR csrrwi, CSRI_A, 8,  8,    str_csrrwi_8
    T_CSRI_CSR csrrwi, CSRI_A, 16, 16,   str_csrrwi_16
    T_CSRI_CSR csrrwi, CSRI_A, 31, 0x1f, str_csrrwi_31
    T_CSRI_CSR csrrwi, -1,     16, 16,   str_csrrwi_16_ones

    /* --- CSRRSI: CSR = old | uimm, upper bits untouched --- */
    T_CSRI_CSR csrrsi, CSRI_P, 0,  CSRI_P,        str_csrrsi_0
    T_CSRI_CSR csrrsi, CSRI_P, 1,  (CSRI_P|1),    str_csrrsi_1
    T_CSRI_CSR csrrsi, CSRI_P, 2,  (CSRI_P|2),    str_csrrsi_2
    T_CSRI_CSR csrrsi, CSRI_P, 4,  (CSRI_P|4),    str_csrrsi_4
    T_CSRI_CSR csrrsi, CSRI_P, 8,  (CSRI_P|8),    str_csrrsi_8
    T_CSRI_CSR csrrsi, CSRI_P, 16, (CSRI_P|16),   str_csrrsi_16
    T_CSRI_CSR csrrsi, CSRI_P, 31, (CSRI_P|0x1f), str_csrrsi_31
    T_CSRI_CSR csrrsi, 0,      31, 0x1f,          str_csrrsi_31_zero

    /* --- CSRRCI: CSR = old & ~uimm, upper bits untouched --- */
    T_CSRI_CSR csrrci, -1,     0,  -1,            str_csrrci_0
    T_CSRI_CSR csrrci, -1,     1,  ~1,            str_csrrci_1
    T_CSRI_CSR csrrci, -1,     2,  ~2,            str_csrrci_2
    T_CSRI_CSR csrrci, -1,     4,  ~4,            str_csrrci_4
    T_CSRI_CSR csrrci, -1,     8,  ~8,            str_csrrci_8
    T_CSRI_CSR csrrci, -1,     16, ~16,           str_csrrci_16
    T_CSRI_CSR csrrci, -1,     31, ~0x1f,         str_csrrci_31
    T_CSRI_CSR csrrci, CSRI_A, 31, (CSRI_A&~0x1f), str_csrrci_31_pat

    /* --- the uimm is not a register number: x[uimm] holds a value
     *     that would give a different answer --- */
    T_CSRI_NOTREG csrrwi, CSRI_A, 31, t6, -1,     31,          str_csrrwi_notreg
    T_CSRI_NOTREG csrrsi, 0,      5,  t0, -1,     5,           str_csrrsi_notreg
    T_CSRI_NOTREG csrrci, -1,     16, a6, -1,     ~16,         str_csrrci_notreg
    T_CSRI_NOTREG csrrsi, CSRI_P, 10, a0, CSRI_A, (CSRI_P|10), str_csrrsi_notreg_a0

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  uimm=0 on read-only CSRs: no write, no trap, same value as CSRRS x0
 * ======================================================================= */
test_csri_readonly:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    T_CSRI_RO0 csrrsi, mhartid, str_csrrsi_mhartid
    T_CSRI_RO0 csrrci, mhartid, str_csrrci_mhartid
    T_CSRI_RO0 csrrsi, mimpid,  str_csrrsi_mimpid
    T_CSRI_RO0 csrrci, mimpid,  str_csrrci_mimpid

    /* misa is WARL rather than read-only, but a non-writing read must
     * not disturb it either way */
    T_CSRI_RO0 csrrsi, misa,    str_csrrsi_misa
    T_CSRI_RO0 csrrci, misa,    str_csrrci_misa

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* Bit independence across fields -- see the file header, BX_C_CSRI and
 * bitx.inc. rd background t2 (x7), uimm background 0; csr fixed at
 * mscratch. Only va and the sentinel are used from the pool, and va
 * differs per instruction (see CSRI_Q). */
/* =======================================================================
 *  Writes to read-only CSRs trap, in M-mode too
 * ======================================================================= */
test_csri_ro_write:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    T_CSRI_RO 1, "CSRRWI rd, mhartid, 0 (M-mode)", csrrwi a3, mhartid, 0
    T_CSRI_RO 1, "CSRRSI rd, mvendorid, 1 (M-mode)", csrrsi a3, mvendorid, 1
    T_CSRI_RO 1, "CSRRCI rd, marchid, 1 (M-mode)", csrrci a3, marchid, 1

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

bitx_zicsr_imm:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    BX_POOL CSRI_A, 0
    BX_E_RI5 BX_C_CSRI, "csrrwi, CSRRWI, 0, CSRI_A", 7, "1,2,4,8,16", 0
    BX_POOL CSRI_P, 0
    BX_E_RI5 BX_C_CSRI, "csrrsi, CSRRSI, 1, CSRI_P", 7, "1,2,4,8,16", 0
    BX_POOL CSRI_Q, 0
    BX_E_RI5 BX_C_CSRI, "csrrci, CSRRCI, 2, CSRI_Q", 7, "1,2,4,8,16", 0

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  Strings
 * ======================================================================= */
    .section .rodata
str_csri_rd_ra:         .asciz "CSRRWI rd=ra"
str_csri_rd_t0:         .asciz "CSRRWI rd=t0"
str_csri_rd_s0:         .asciz "CSRRWI rd=s0"
str_csri_rd_a0:         .asciz "CSRRWI rd=a0"
str_csri_rd_s10:        .asciz "CSRRWI rd=s10"
str_csri_rd_t6:         .asciz "CSRRWI rd=t6"
str_csrrwi_rdx0:        .asciz "CSRRWI rd=x0 (csrwi) still writes"
str_csrrsi_rdx0:        .asciz "CSRRSI rd=x0 (csrsi) still sets"
str_csrrci_rdx0:        .asciz "CSRRCI rd=x0 (csrci) still clears"
str_csrrwi_old:         .asciz "CSRRWI rd = old value"
str_csrrsi_old:         .asciz "CSRRSI rd = old value"
str_csrrci_old:         .asciz "CSRRCI rd = old value"

str_csrrwi_0:           .asciz "CSRRWI uimm=0 writes 0"
str_csrrwi_1:           .asciz "CSRRWI uimm=1"
str_csrrwi_2:           .asciz "CSRRWI uimm=2"
str_csrrwi_4:           .asciz "CSRRWI uimm=4"
str_csrrwi_8:           .asciz "CSRRWI uimm=8"
str_csrrwi_16:          .asciz "CSRRWI uimm=16"
str_csrrwi_31:          .asciz "CSRRWI uimm=31 writes 0x1f (zero-extended)"
str_csrrwi_16_ones:     .asciz "CSRRWI uimm=16 over all ones replaces every bit"
str_csrrsi_0:           .asciz "CSRRSI uimm=0 leaves the CSR unchanged"
str_csrrsi_1:           .asciz "CSRRSI uimm=1"
str_csrrsi_2:           .asciz "CSRRSI uimm=2"
str_csrrsi_4:           .asciz "CSRRSI uimm=4"
str_csrrsi_8:           .asciz "CSRRSI uimm=8"
str_csrrsi_16:          .asciz "CSRRSI uimm=16"
str_csrrsi_31:          .asciz "CSRRSI uimm=31 sets only the low five bits"
str_csrrsi_31_zero:     .asciz "CSRRSI uimm=31 over 0 gives 0x1f (zero-extended)"
str_csrrci_0:           .asciz "CSRRCI uimm=0 leaves the CSR unchanged"
str_csrrci_1:           .asciz "CSRRCI uimm=1"
str_csrrci_2:           .asciz "CSRRCI uimm=2"
str_csrrci_4:           .asciz "CSRRCI uimm=4"
str_csrrci_8:           .asciz "CSRRCI uimm=8"
str_csrrci_16:          .asciz "CSRRCI uimm=16"
str_csrrci_31:          .asciz "CSRRCI uimm=31 clears only the low five bits"
str_csrrci_31_pat:      .asciz "CSRRCI uimm=31 over a pattern"
str_csrrwi_notreg:      .asciz "CSRRWI uimm=31 is not x31"
str_csrrsi_notreg:      .asciz "CSRRSI uimm=5 is not x5"
str_csrrci_notreg:      .asciz "CSRRCI uimm=16 is not x16"
str_csrrsi_notreg_a0:   .asciz "CSRRSI uimm=10 is not x10"

str_csrrsi_mhartid:     .asciz "CSRRSI uimm=0 reads mhartid, no trap"
str_csrrci_mhartid:     .asciz "CSRRCI uimm=0 reads mhartid, no trap"
str_csrrsi_mimpid:      .asciz "CSRRSI uimm=0 reads mimpid, no trap"
str_csrrci_mimpid:      .asciz "CSRRCI uimm=0 reads mimpid, no trap"
str_csrrsi_misa:        .asciz "CSRRSI uimm=0 reads misa"
str_csrrci_misa:        .asciz "CSRRCI uimm=0 reads misa"
