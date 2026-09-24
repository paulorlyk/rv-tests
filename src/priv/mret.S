/* =====================================================================
 * priv/mret.S  --  MRET (machine-mode trap return)
 *
 * Part of the privileged-architecture suite; see priv/tests.S for how
 * this plugs into the rest (main_tests.S -> priv/tests.S -> here), and
 * common.S for the boot/UART/reporting harness everything sits on
 * ("check", "test_begin" and the armed trap mode -- trap_resume/
 * trap_count/trap_mcause/... -- are used from there).
 *
 * MRET does three things at once: pc <- mepc, privilege <- mstatus.MPP,
 * and the mstatus interrupt-enable stack pops (MIE <- MPIE, MPIE <- 1,
 * MPP <- the least-privileged supported mode, and MPRV <- 0 if the new
 * mode is below M). Every test here executes MRET directly, from test
 * code, with mepc and mstatus set up by hand -- not just as the tail of
 * a trap handler -- so each of those effects is pinned down on its
 * own:
 *   - the jump: MRET lands on mepc (not on the instruction after it);
 *     at a 2 mod 4 target (a compressed instruction, legal with C);
 *     MRET itself leaves mepc unchanged;
 *   - MIE <- MPIE, both ways (MPIE=1/MIE=0 -> MIE=1, MPIE=0/MIE=1 ->
 *     MIE=0; mie = 0 throughout, so MIE = 1 can't let an interrupt in),
 *     and MPIE = 1 afterwards either way;
 *   - MPP afterwards = U if misa says U-mode exists, else M;
 *   - MPP = M: execution stays in M-mode (an M-mode CSR read after it
 *     doesn't trap); MPP = U: it drops to U-mode (the same read traps
 *     as illegal, mcause 2, with MPP = 0 recorded on entry, mepc on the
 *     read);
 *   - MPRV is cleared by an MRET to U-mode and kept by one to M-mode;
 *   - MRET executed in U-mode is illegal (mcause 2, mepc on the MRET);
 *   - the general registers are unchanged.
 * Not tested: that mepc[0] reads as 0 after writing 1 (and so that
 * MRET can't go to an odd address). The spec requires it, but QEMU
 * (10.0) keeps the bit -- it reads back, and MRET jumps to the odd
 * address and takes an illegal-instruction trap there -- so such a
 * test would fail on the reference platform.
 *
 * Every MRET here clears MPIE first unless the test sets it on
 * purpose: MRET copies MPIE into MIE and leaves MPIE = 1, so the next
 * MRET would otherwise turn MIE on (and so would a round trip through
 * U-mode and the handler). The file clears MIE on the way out as well.
 *
 * A wrong privilege change surfaces as a trap: those tests run with
 * the handler armed (TRAP_ARM in harness.inc), so it comes back as a
 * FAIL with the recorded mcause instead of a hang. Every U-mode path
 * also has a backstop for an instruction that wrongly doesn't trap, so
 * execution can't stay in U-mode or loop: an ECALL or an M-mode CSR
 * read after it, which traps into the still-armed handler. The
 * MRET-in-U-mode test needs one more step, since an MRET that wrongly
 * works jumps back to mepc -- the U-mode entry point -- and would run
 * the same MRET again forever: the entry code counts its passes, and
 * the second one branches to the ECALL instead.
 *
 * ASSUMPTIONS: U-mode is implemented and PMP (if any) lets U-mode reach
 * all memory -- common.S's reset sets that up; MRET from M to M and the
 * mstatus-stack tests need neither. QEMU virt has both.
 *
 * Bit independence across fields: MRET has a single fixed encoding (no
 * variable field), so C(0,2) = 0 cases.
 *
 * Built unchanged for both widths.
 * ===================================================================== */

    .include "xlen.inc"
    .include "harness.inc"

    .option norvc            /* mandatory, not stylistic -- see i/loads.S */

    .global tests_priv_mret

    .section .text

/* =======================================================================
 *  Shared macros
 * ======================================================================= */

/* MR_COUNT reg -- reg = trap_count (pc-relative). */
.macro MR_COUNT reg
    .option push
    .option norelax
    lw      \reg, trap_count
    .option pop
.endm

/* MR_MPP_M -- set mstatus.MPP to 3 (MPIE untouched). Clobbers t0. */
.macro MR_MPP_M
    li      t0, MSTATUS_MPP
    csrs    mstatus, t0
.endm

/* MR_MPP_U -- set mstatus.MPP to 0 and MPIE to 0 (see the file
 * header). Clobbers t0. */
.macro MR_MPP_U
    li      t0, MSTATUS_MPP | MSTATUS_MPIE
    csrc    mstatus, t0
.endm

/* MR_TO_M target -- MRET to target, staying in M-mode, with MPIE = 0
 * so MIE comes out 0. Clobbers t0. */
.macro MR_TO_M target
    li      t0, MSTATUS_MPIE
    csrc    mstatus, t0
    MR_MPP_M
    la      t0, \target
    csrw    mepc, t0
    mret
.endm

/* MR_FIELD rd, rs, shift, mask -- rd = (rs >> shift) & mask */
.macro MR_FIELD rd, rs, shift, mask
    srli    \rd, \rs, \shift
    andi    \rd, \rd, \mask
.endm

/* MR_CHK name, expected, actual -- check(name, LIX expected, actual).
 * actual must not be a0/a1. */
.macro MR_CHK name, exp, act
    la      a0, \name
    LIX     a1, \exp
    mv      a2, \act
    call    check
.endm

/* MR_CHKR name, expected, actual -- same, expected in a register (not
 * a0/a2). */
.macro MR_CHKR name, exp, act
    la      a0, \name
    mv      a1, \exp
    mv      a2, \act
    call    check
.endm

/* =======================================================================
 *  Entry point
 * ======================================================================= */
tests_priv_mret:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)
    REG_S   s0, 8(sp)

    csrrw   s0, mie, zero           /* no interrupt sources while MIE is
                                     * set on purpose below */

    jal     ra, test_mret_jump
    jal     ra, test_mret_mstatus
    jal     ra, test_mret_priv
    jal     ra, test_mret_regs

    csrci   mstatus, MSTATUS_MIE
    csrw    mie, s0
    REG_L   ra, 0(sp)
    REG_L   s0, 8(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  The jump: pc <- mepc
 * ======================================================================= */
test_mret_jump:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    /* --- MRET lands on mepc: s4 = 1 there, 2 if it fell through --- */
    TEST_BEGIN str_mret_jump
    li      s4, 0
    MR_TO_M .Lmr_jump_target
    li      s4, 2
    j       .Lmr_jump_done
    li      s4, 3                   /* never reached */
.Lmr_jump_target:
    li      s4, 1
.Lmr_jump_done:
    csrr    s2, mepc
    MR_CHK  str_mret_jump, 1, s4

    /* --- ... and leaves mepc as it was --- */
    TEST_BEGIN str_mret_mepc_kept
    la      t2, .Lmr_jump_target
    MR_CHKR str_mret_mepc_kept, t2, s2

    /* --- a target at an address 2 mod 4 holding a compressed
     *     instruction --- */
    TEST_BEGIN str_mret_align2
    li      s4, 0
    MR_TO_M .Lmr_c_target
    li      s4, 2
    j       .Lmr_c_done
    .balign 4
    .option push
    .option rvc
    c.nop                           /* never reached */
.Lmr_c_target:
    c.li    s4, 1                   /* ends 4-byte aligned again */
    .option pop
.Lmr_c_done:
    MR_CHK  str_mret_align2, 1, s4

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  The interrupt-enable stack: MIE <- MPIE, MPIE <- 1, MPP <- least
 *  privileged
 * ======================================================================= */
test_mret_mstatus:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    /* --- MPIE = 1, MIE = 0 before: MIE = 1, MPIE = 1 after --- */
    TEST_BEGIN str_mret_mpie1_mie
    csrci   mstatus, MSTATUS_MIE
    li      t0, MSTATUS_MPIE
    csrs    mstatus, t0
    MR_MPP_M
    la      t0, 1f
    csrw    mepc, t0
    mret
1:  csrr    s5, mstatus
    csrci   mstatus, MSTATUS_MIE
    MR_FIELD t2, s5, 3, 1
    MR_CHK  str_mret_mpie1_mie, 1, t2
    TEST_BEGIN str_mret_mpie1_mpie
    MR_FIELD t2, s5, 7, 1
    MR_CHK  str_mret_mpie1_mpie, 1, t2

    /* --- MPP afterwards: U (0) if misa has U, else M (3) --- */
    TEST_BEGIN str_mret_mpp_after
    csrr    t0, misa
    MR_FIELD t0, t0, 20, 1          /* misa.U */
    xori    t0, t0, 1
    slli    t1, t0, 1
    add     s6, t1, t0              /* 0 or 3 */
    MR_FIELD t2, s5, 11, 3
    MR_CHKR str_mret_mpp_after, s6, t2

    /* --- MPIE = 0, MIE = 1 before: MIE = 0, MPIE = 1 after --- */
    TEST_BEGIN str_mret_mpie0_mie
    li      t0, MSTATUS_MPIE
    csrc    mstatus, t0
    csrsi   mstatus, MSTATUS_MIE
    MR_MPP_M
    la      t0, 1f
    csrw    mepc, t0
    mret
1:  csrr    s5, mstatus
    csrci   mstatus, MSTATUS_MIE
    MR_FIELD t2, s5, 3, 1
    MR_CHK  str_mret_mpie0_mie, 0, t2
    TEST_BEGIN str_mret_mpie0_mpie
    MR_FIELD t2, s5, 7, 1
    MR_CHK  str_mret_mpie0_mpie, 1, t2

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  The privilege change: privilege <- MPP, MPRV
 * ======================================================================= */
test_mret_priv:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    /* --- MPP = M: still in M-mode, so reading mscratch doesn't trap --- */
    TEST_BEGIN str_mret_stay_m
    MR_COUNT s3
    TRAP_ARM .Lmr_m_back
    MR_TO_M .Lmr_m_at
.Lmr_m_at:
    csrr    t0, mscratch
.Lmr_m_back:
    TRAP_DISARM
    MR_COUNT t0
    sub     s3, t0, s3
    MR_CHK  str_mret_stay_m, 0, s3

    /* --- MPP = U: in U-mode, the same read is illegal --- */
    TEST_BEGIN str_mret_to_u
    MR_COUNT s3
    la      s2, .Lmr_u_at
    TRAP_ARM .Lmr_u_back
    MR_MPP_U
    csrw    mepc, s2
    mret
.Lmr_u_at:
    csrr    t0, mscratch
.Lmr_u_back:
    TRAP_DISARM
    MR_COUNT t0
    sub     s3, t0, s3
    MR_CHK  str_mret_to_u, 1, s3
    TEST_BEGIN str_mret_to_u_mcause
    TRAP_LD t2, mcause
    MR_CHK  str_mret_to_u_mcause, 2, t2
    TEST_BEGIN str_mret_to_u_mpp
    TRAP_LD t2, mstatus
    MR_FIELD t2, t2, 11, 3
    MR_CHK  str_mret_to_u_mpp, 0, t2
    TEST_BEGIN str_mret_to_u_mepc
    TRAP_LD t2, mepc
    MR_CHKR str_mret_to_u_mepc, s2, t2

    /* --- MRET to U-mode clears MPRV: recorded by the ECALL that
     *     brings execution back (the mscratch read after it is the
     *     backstop if the ECALL doesn't trap) --- */
    TEST_BEGIN str_mret_mprv_u
    TRAP_ARM .Lmr_mprv_back
    MR_MPP_U
    li      t0, MSTATUS_MPRV
    csrs    mstatus, t0
    la      t0, .Lmr_mprv_at
    csrw    mepc, t0
    mret
.Lmr_mprv_at:
    ecall
    csrr    t0, mscratch            /* backstop: illegal in U-mode */
.Lmr_mprv_back:
    li      t0, MSTATUS_MPRV
    csrc    mstatus, t0
    TRAP_DISARM
    TRAP_LD t2, mstatus
    MR_FIELD t2, t2, 17, 1
    MR_CHK  str_mret_mprv_u, 0, t2

    /* --- MRET to M-mode keeps MPRV (no memory access until it's
     *     cleared again: MPP reads U afterwards, so MPRV = 1 would
     *     make loads and stores run with U-mode privilege) --- */
    TEST_BEGIN str_mret_mprv_m
    li      t0, MSTATUS_MPRV
    csrs    mstatus, t0
    MR_TO_M 1f
1:  csrr    s5, mstatus
    li      t0, MSTATUS_MPRV
    csrc    mstatus, t0
    MR_FIELD t2, s5, 17, 1
    MR_CHK  str_mret_mprv_m, 1, t2

    /* --- MRET in U-mode is illegal. U-mode is entered at
     *     .Lmr_iu_entry, which is also what mepc still holds when the
     *     MRET under test runs; s4 counts the passes through the entry
     *     code. An MRET that wrongly works goes back to mepc, and the
     *     second pass branches to the ECALL; one that falls through
     *     lands on the same ECALL. Either way the armed handler catches
     *     it, with mcause 8 (or 11) and mepc on the ECALL -- a FAIL, not
     *     a loop. --- */
    TEST_BEGIN str_mret_in_u
    MR_COUNT s3
    la      s2, .Lmr_iu_at
    li      s4, 0
    TRAP_ARM .Lmr_iu_back
    MR_MPP_U
    la      t0, .Lmr_iu_entry
    csrw    mepc, t0
    mret
.Lmr_iu_entry:                      /* U-mode from here */
    addi    s4, s4, 1
    li      t0, 2
    beq     s4, t0, .Lmr_iu_escape
.Lmr_iu_at:
    mret                            /* under test: must trap */
.Lmr_iu_escape:
    ecall                           /* backstop */
.Lmr_iu_back:
    TRAP_DISARM
    MR_COUNT t0
    sub     s3, t0, s3
    MR_CHK  str_mret_in_u, 1, s3
    TEST_BEGIN str_mret_in_u_mcause
    TRAP_LD t2, mcause
    MR_CHK  str_mret_in_u_mcause, 2, t2
    TEST_BEGIN str_mret_in_u_mepc
    TRAP_LD t2, mepc
    MR_CHKR str_mret_in_u_mepc, s2, t2
    TEST_BEGIN str_mret_in_u_mpp
    TRAP_LD t2, mstatus
    MR_FIELD t2, t2, 11, 3
    MR_CHK  str_mret_in_u_mpp, 0, t2

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  Registers: a0-a7, t2-t6 and s6-s11 get distinct patterns
 *  (k * 0x0101010101010101), one MRET (M to M; MR_TO_M uses only t0),
 *  then (reg ^ pattern) ORed together must be 0.
 * ======================================================================= */
test_mret_regs:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    TEST_BEGIN str_mret_regs
    .set    mr_k, 1
    .irp r, a0,a1,a2,a3,a4,a5,a6,a7,t2,t3,t4,t5,t6,s6,s7,s8,s9,s10,s11
    LIXT    \r, (mr_k * 0x0101010101010101)
    .set    mr_k, mr_k + 1
    .endr
    MR_TO_M 1f
1:  li      t1, 0
    .set    mr_k, 1
    .irp r, a0,a1,a2,a3,a4,a5,a6,a7,t2,t3,t4,t5,t6,s6,s7,s8,s9,s10,s11
    LIXT    t0, (mr_k * 0x0101010101010101)
    xor     t0, t0, \r
    or      t1, t1, t0
    .set    mr_k, mr_k + 1
    .endr
    mv      s6, t1
    MR_CHK  str_mret_regs, 0, s6

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  Strings
 * ======================================================================= */
    .section .rodata
str_mret_jump:         .asciz "MRET jumps to mepc"
str_mret_mepc_kept:    .asciz "MRET leaves mepc unchanged"
str_mret_align2:       .asciz "MRET to a compressed instruction at 2 mod 4"
str_mret_mpie1_mie:    .asciz "MRET with MPIE=1, MIE=0: MIE becomes 1"
str_mret_mpie1_mpie:   .asciz "MRET with MPIE=1, MIE=0: MPIE is 1 after"
str_mret_mpp_after:    .asciz "MRET: MPP becomes the least-privileged mode (misa)"
str_mret_mpie0_mie:    .asciz "MRET with MPIE=0, MIE=1: MIE becomes 0"
str_mret_mpie0_mpie:   .asciz "MRET with MPIE=0, MIE=1: MPIE is 1 after"
str_mret_stay_m:       .asciz "MRET with MPP=M stays in M-mode (mscratch readable)"
str_mret_to_u:         .asciz "MRET with MPP=U drops to U-mode (mscratch read traps)"
str_mret_to_u_mcause:  .asciz "MRET with MPP=U: mscratch read mcause == 2"
str_mret_to_u_mpp:     .asciz "MRET with MPP=U: trap entry MPP == 0 (U)"
str_mret_to_u_mepc:    .asciz "MRET with MPP=U: mepc == the mscratch read"
str_mret_mprv_u:       .asciz "MRET to U-mode clears MPRV"
str_mret_mprv_m:       .asciz "MRET to M-mode keeps MPRV"
str_mret_in_u:         .asciz "MRET in U-mode traps exactly once"
str_mret_in_u_mcause:  .asciz "MRET in U-mode: mcause == 2 (illegal instruction)"
str_mret_in_u_mepc:    .asciz "MRET in U-mode: mepc == the MRET itself"
str_mret_in_u_mpp:     .asciz "MRET in U-mode: trap entry MPP == 0 (U)"
str_mret_regs:         .asciz "MRET: a0-a7, t2-t6, s6-s11 unchanged"
