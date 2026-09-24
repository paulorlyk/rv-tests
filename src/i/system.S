/* =====================================================================
 * i/system.S  --  RV64I/RV32I base-ISA ECALL and EBREAK
 *
 * Part of the RV64I base-ISA suite; see i/tests.S for how this plugs
 * into the rest (main_tests.S -> i/tests.S -> here), and common.S for
 * the boot/UART/reporting harness everything sits on ("check",
 * "test_begin" and the armed trap mode -- trap_resume/trap_count/
 * trap_mcause/... -- are used from there).
 *
 * ECALL and EBREAK are the two SYSTEM-opcode instructions of the base
 * ISA proper (funct3 = 0, funct12 = 0 and 1). Each has exactly one
 * encoding -- rd, rs1 and funct3 must be zero, and anything else is a
 * different or reserved instruction, not a variant -- so, like
 * C.EBREAK (c/quadrant2.S), there is no operand to sweep. What gets
 * checked instead is what a trap handler (a kernel's syscall path, a
 * debugger) relies on. For each of the two, in M-mode unless stated:
 *   - it traps (execution does not fall through), exactly once, and
 *     the handler's MRET brings execution back where it was told to;
 *   - mcause: ECALL = 11 (environment call from M-mode), EBREAK = 3
 *     (breakpoint) -- the two must not be confused;
 *   - mepc is the address of the instruction itself, not the next one
 *     (the handler, not the hardware, steps past it);
 *   - mtval: 0 for ECALL; 0 or the EBREAK's own address for EBREAK
 *     (the privileged spec allows either);
 *   - the mstatus interrupt stack on trap entry: MPP = 3 (came from
 *     M), MIE = 0, MPIE = the MIE from before the trap -- run with MIE
 *     both 0 and 1 (mie = 0 throughout, so MIE = 1 can't let an
 *     interrupt in) -- and MIE is back to that value after the MRET;
 *   - the general registers (the syscall argument registers a0-a7
 *     among them) come through the round trip unchanged;
 *   - three in a row: each traps and resumes exactly once;
 *   - at an address that is 2 mod 4 (legal with the C extension):
 *     mepc is still exact;
 *   - from U-mode (entered with MRET, MPP = U): ECALL's cause becomes
 *     8 (environment call from U-mode), EBREAK's stays 3, MPP on entry
 *     is 0 (U), mepc is exact.
 *
 * Every trap here goes through common.S's armed mode (TRAP_ARM in
 * harness.inc): the handler records mcause/mepc/mtval/mstatus and
 * resumes at an address the test chose, so a missing trap, a wrong
 * cause or an extra trap is a FAIL rather than a hang.
 *
 * ASSUMPTIONS: U-mode is implemented and PMP (if any) lets U-mode
 * reach all memory -- common.S's reset sets that up -- for the U-mode
 * cases; QEMU virt has both.
 *
 * Bit independence across fields: neither instruction has a variable
 * field, so C(0,2) = 0 cases -- the same as C.EBREAK.
 *
 * Built unchanged for both widths.
 * ===================================================================== */

    .include "xlen.inc"
    .include "harness.inc"

    .option norvc            /* mandatory, not stylistic -- see i/loads.S;
                              * here it also keeps "ebreak" from becoming
                              * c.ebreak */

    .global tests_i_system

    .section .text

/* =======================================================================
 *  Shared macros
 * ======================================================================= */

/* SYS_COUNT reg -- reg = trap_count (pc-relative). */
.macro SYS_COUNT reg
    .option push
    .option norelax
    lw      \reg, trap_count
    .option pop
.endm

/* SYS_RUN insn, mie=0, align2=0 -- run \insn once in M-mode with the
 * handler armed. mstatus.MIE is set to \mie just before it (and
 * cleared again afterwards); with align2 the instruction sits at an
 * address that is 2 mod 4 (a c.nop in front of it, and one after it so
 * the code that follows is 4-byte aligned again). Leaves:
 *   s2 = the address of the instruction under test
 *   s3 = traps taken while it ran (trap_count delta)
 *   s4 = 1 if execution came back at the resume address, 2 if the
 *        instruction fell through without trapping
 *   s5 = mstatus straight after the resume (MIE not yet cleared)
 * Clobbers t0. */
.macro SYS_RUN insn, mie=0, align2=0
    SYS_COUNT s3
    .option push
    .option norelax
    la      s2, .Lsys_at\@
    .option pop
    TRAP_ARM .Lsys_back\@
    .if \mie
    csrsi   mstatus, MSTATUS_MIE
    .endif
    .if \align2
    .balign 4
    .option push
    .option rvc
    c.nop
    .option pop
    .endif
.Lsys_at\@:
    \insn
    .if \align2
    .option push                    /* back to 4-byte alignment for */
    .option rvc                     /* the code that follows */
    c.nop
    .option pop
    .endif
    li      s4, 2
    j       .Lsys_done\@
.Lsys_back\@:
    li      s4, 1
.Lsys_done\@:
    csrr    s5, mstatus
    csrci   mstatus, MSTATUS_MIE
    TRAP_DISARM
    SYS_COUNT t0
    sub     s3, t0, s3
.endm

/* SYS_RUN_U insn -- as SYS_RUN, but \insn runs in U-mode: MPP = U,
 * MPIE = 0, mepc = the instruction, MRET. The armed handler brings
 * execution back in M-mode. If \insn wrongly doesn't trap, s4 = 2 and
 * the mscratch read after it -- illegal in U-mode -- traps into the
 * still-armed handler instead, so execution never stays in U-mode (the
 * cause check then sees 2). (MPIE is cleared because MRET copies it to
 * MIE, the trap from U-mode copies MIE back into MPIE and the handler's
 * MRET copies that to MIE again: left at the 1 every MRET leaves
 * behind, it would come back as MIE = 1 in M-mode.) Same s2/s3/s4
 * results (s5 not set). Clobbers t0. */
.macro SYS_RUN_U insn
    SYS_COUNT s3
    .option push
    .option norelax
    la      s2, .Lsys_at\@
    .option pop
    TRAP_ARM .Lsys_back\@
    li      t0, MSTATUS_MPP | MSTATUS_MPIE
    csrc    mstatus, t0
    li      s4, 1
    csrw    mepc, s2
    mret
.Lsys_at\@:
    \insn
    li      s4, 2                   /* fell through */
    csrr    t0, mscratch            /* backstop: illegal in U-mode */
.Lsys_back\@:
    TRAP_DISARM
    SYS_COUNT t0
    sub     s3, t0, s3
.endm

/* SYS_FIELD rd, rs, shift, mask -- rd = (rs >> shift) & mask */
.macro SYS_FIELD rd, rs, shift, mask
    srli    \rd, \rs, \shift
    andi    \rd, \rd, \mask
.endm

/* SYS_CHK name, expected, actual -- check(name, LIX expected, actual).
 * actual must not be a0/a1. */
.macro SYS_CHK name, exp, act
    la      a0, \name
    LIX     a1, \exp
    mv      a2, \act
    call    check
.endm

/* T_SYS_TRAP insn, cause, s_taken, s_once, s_cause, s_mepc -- one trap
 * in M-mode: it traps and resumes, exactly once, with mcause = cause
 * and mepc = the instruction. */
.macro T_SYS_TRAP insn, cause, s_taken, s_once, s_cause, s_mepc
    TEST_BEGIN \s_taken
    SYS_RUN \insn
    SYS_CHK \s_taken, 1, s4
    TEST_BEGIN \s_once
    SYS_CHK \s_once, 1, s3
    TEST_BEGIN \s_cause
    TRAP_LD t2, mcause
    SYS_CHK \s_cause, \cause, t2
    TEST_BEGIN \s_mepc
    TRAP_LD t2, mepc
    la      a0, \s_mepc
    mv      a1, s2
    mv      a2, t2
    call    check
.endm

/* T_SYS_MSTATUS insn, mie, s_mpp, s_mie, s_mpie, s_after -- one trap
 * with mstatus.MIE = mie beforehand: on entry MPP = 3, MIE = 0,
 * MPIE = mie; after the handler's MRET, MIE = mie again. */
.macro T_SYS_MSTATUS insn, mie, s_mpp, s_mie, s_mpie, s_after
    TEST_BEGIN \s_mpp
    SYS_RUN \insn, \mie
    TRAP_LD t2, mstatus
    SYS_FIELD t2, t2, 11, 3
    SYS_CHK \s_mpp, 3, t2
    TEST_BEGIN \s_mie
    TRAP_LD t2, mstatus
    SYS_FIELD t2, t2, 3, 1
    SYS_CHK \s_mie, 0, t2
    TEST_BEGIN \s_mpie
    TRAP_LD t2, mstatus
    SYS_FIELD t2, t2, 7, 1
    SYS_CHK \s_mpie, \mie, t2
    TEST_BEGIN \s_after
    SYS_FIELD t2, s5, 3, 1
    SYS_CHK \s_after, \mie, t2
.endm

/* T_SYS_REGS insn, s_regs -- a0-a7, t2-t6 and s6-s11 get distinct
 * patterns (k * 0x0101010101010101), one trap, then (reg ^ pattern)
 * ORed together over all of them must be 0. SYS_RUN itself only
 * touches t0 and s2-s5, none of which is in the list; the handler
 * saves and restores what it uses. */
.macro T_SYS_REGS insn, s_regs
    TEST_BEGIN \s_regs
    .set    sys_k, 1
    .irp r, a0,a1,a2,a3,a4,a5,a6,a7,t2,t3,t4,t5,t6,s6,s7,s8,s9,s10,s11
    LIXT    \r, (sys_k * 0x0101010101010101)
    .set    sys_k, sys_k + 1
    .endr
    SYS_RUN \insn
    li      t1, 0
    .set    sys_k, 1
    .irp r, a0,a1,a2,a3,a4,a5,a6,a7,t2,t3,t4,t5,t6,s6,s7,s8,s9,s10,s11
    LIXT    t0, (sys_k * 0x0101010101010101)
    xor     t0, t0, \r
    or      t1, t1, t0
    .set    sys_k, sys_k + 1
    .endr
    mv      s6, t1
    SYS_CHK \s_regs, 0, s6
.endm

/* T_SYS_REPEAT insn, s_count, s_delta -- three in a row, each armed
 * separately: s6 counts the resumes seen here, s7 sums the handler's
 * trap_count deltas. Both must be 3. */
.macro T_SYS_REPEAT insn, s_count, s_delta
    TEST_BEGIN \s_count
    li      s6, 0
    li      s7, 0
    .rept 3
    SYS_RUN \insn
    addi    t0, s4, -1
    seqz    t0, t0
    add     s6, s6, t0
    add     s7, s7, s3
    .endr
    SYS_CHK \s_count, 3, s6
    TEST_BEGIN \s_delta
    SYS_CHK \s_delta, 3, s7
.endm

/* T_SYS_ALIGN2 insn, s_taken, s_mepc -- the instruction at an address
 * that is 2 mod 4: traps and resumes, mepc exact. */
.macro T_SYS_ALIGN2 insn, s_taken, s_mepc
    TEST_BEGIN \s_taken
    SYS_RUN \insn, 0, 1
    SYS_CHK \s_taken, 1, s4
    TEST_BEGIN \s_mepc
    TRAP_LD t2, mepc
    la      a0, \s_mepc
    mv      a1, s2
    mv      a2, t2
    call    check
.endm

/* T_SYS_U insn, cause, s_taken, s_cause, s_mpp, s_mepc -- from U-mode:
 * traps (exactly once) with mcause = cause, MPP = 0 on entry, mepc =
 * the instruction. */
.macro T_SYS_U insn, cause, s_taken, s_cause, s_mpp, s_mepc
    TEST_BEGIN \s_taken
    SYS_RUN_U \insn
    slli    t2, s3, 4               /* s4 = 1 and s3 = 1 -> 0x11 */
    or      t2, t2, s4
    SYS_CHK \s_taken, 0x11, t2
    TEST_BEGIN \s_cause
    TRAP_LD t2, mcause
    SYS_CHK \s_cause, \cause, t2
    TEST_BEGIN \s_mpp
    TRAP_LD t2, mstatus
    SYS_FIELD t2, t2, 11, 3
    SYS_CHK \s_mpp, 0, t2
    TEST_BEGIN \s_mepc
    TRAP_LD t2, mepc
    la      a0, \s_mepc
    mv      a1, s2
    mv      a2, t2
    call    check
.endm

/* =======================================================================
 *  Entry point
 * ======================================================================= */
tests_i_system:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)
    REG_S   s0, 8(sp)

    csrrw   s0, mie, zero           /* no interrupt sources while MIE is
                                     * set on purpose below */

    jal     ra, test_ecall
    jal     ra, test_ebreak

    csrci   mstatus, MSTATUS_MIE
    csrw    mie, s0
    REG_L   ra, 0(sp)
    REG_L   s0, 8(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  ECALL
 * ======================================================================= */
test_ecall:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    T_SYS_TRAP ecall, 11, str_ecall_taken, str_ecall_once, str_ecall_mcause, str_ecall_mepc

    /* --- mtval is 0 --- */
    TEST_BEGIN str_ecall_mtval
    SYS_RUN ecall
    TRAP_LD t2, mtval
    SYS_CHK str_ecall_mtval, 0, t2

    T_SYS_MSTATUS ecall, 0, str_ecall_mie0_mpp, str_ecall_mie0_mie, str_ecall_mie0_mpie, str_ecall_mie0_after
    T_SYS_MSTATUS ecall, 1, str_ecall_mie1_mpp, str_ecall_mie1_mie, str_ecall_mie1_mpie, str_ecall_mie1_after
    T_SYS_REGS ecall, str_ecall_regs
    T_SYS_REPEAT ecall, str_ecall_repeat, str_ecall_repeat_delta
    T_SYS_ALIGN2 ecall, str_ecall_align2, str_ecall_align2_mepc
    T_SYS_U ecall, 8, str_ecall_u_taken, str_ecall_u_mcause, str_ecall_u_mpp, str_ecall_u_mepc

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  EBREAK
 * ======================================================================= */
test_ebreak:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    T_SYS_TRAP ebreak, 3, str_ebreak_taken, str_ebreak_once, str_ebreak_mcause, str_ebreak_mepc

    /* --- mtval is 0 or the EBREAK's own address: t2 = 1 if so --- */
    TEST_BEGIN str_ebreak_mtval
    SYS_RUN ebreak
    TRAP_LD t2, mtval
    beqz    t2, 1f
    sub     t2, t2, s2
1:  seqz    t2, t2
    SYS_CHK str_ebreak_mtval, 1, t2

    T_SYS_MSTATUS ebreak, 0, str_ebreak_mie0_mpp, str_ebreak_mie0_mie, str_ebreak_mie0_mpie, str_ebreak_mie0_after
    T_SYS_MSTATUS ebreak, 1, str_ebreak_mie1_mpp, str_ebreak_mie1_mie, str_ebreak_mie1_mpie, str_ebreak_mie1_after
    T_SYS_REGS ebreak, str_ebreak_regs
    T_SYS_REPEAT ebreak, str_ebreak_repeat, str_ebreak_repeat_delta
    T_SYS_ALIGN2 ebreak, str_ebreak_align2, str_ebreak_align2_mepc
    T_SYS_U ebreak, 3, str_ebreak_u_taken, str_ebreak_u_mcause, str_ebreak_u_mpp, str_ebreak_u_mepc

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  Strings
 * ======================================================================= */
    .section .rodata
str_ecall_taken:        .asciz "ECALL traps, handler's MRET resumes execution"
str_ecall_once:         .asciz "ECALL traps exactly once"
str_ecall_mcause:       .asciz "ECALL mcause == 11 (environment call from M-mode)"
str_ecall_mepc:         .asciz "ECALL mepc == the ECALL itself"
str_ecall_mtval:        .asciz "ECALL mtval == 0"
str_ecall_mie0_mpp:     .asciz "ECALL (MIE=0) entry: MPP == 3 (M)"
str_ecall_mie0_mie:     .asciz "ECALL (MIE=0) entry: MIE == 0"
str_ecall_mie0_mpie:    .asciz "ECALL (MIE=0) entry: MPIE == 0"
str_ecall_mie0_after:   .asciz "ECALL (MIE=0) after MRET: MIE == 0"
str_ecall_mie1_mpp:     .asciz "ECALL (MIE=1) entry: MPP == 3 (M)"
str_ecall_mie1_mie:     .asciz "ECALL (MIE=1) entry: MIE == 0"
str_ecall_mie1_mpie:    .asciz "ECALL (MIE=1) entry: MPIE == 1"
str_ecall_mie1_after:   .asciz "ECALL (MIE=1) after MRET: MIE == 1"
str_ecall_regs:         .asciz "ECALL: a0-a7, t2-t6, s6-s11 survive the round trip"
str_ecall_repeat:       .asciz "ECALL x3 in a row, each resumes exactly once"
str_ecall_repeat_delta: .asciz "ECALL x3: trap handler hit exactly 3 times"
str_ecall_align2:       .asciz "ECALL at an address 2 mod 4 traps and resumes"
str_ecall_align2_mepc:  .asciz "ECALL at an address 2 mod 4: mepc exact"
str_ecall_u_taken:      .asciz "ECALL from U-mode traps exactly once"
str_ecall_u_mcause:     .asciz "ECALL from U-mode: mcause == 8"
str_ecall_u_mpp:        .asciz "ECALL from U-mode: MPP == 0 (U)"
str_ecall_u_mepc:       .asciz "ECALL from U-mode: mepc == the ECALL itself"

str_ebreak_taken:        .asciz "EBREAK traps, handler's MRET resumes execution"
str_ebreak_once:         .asciz "EBREAK traps exactly once"
str_ebreak_mcause:       .asciz "EBREAK mcause == 3 (breakpoint)"
str_ebreak_mepc:         .asciz "EBREAK mepc == the EBREAK itself"
str_ebreak_mtval:        .asciz "EBREAK mtval == 0 or the EBREAK's address"
str_ebreak_mie0_mpp:     .asciz "EBREAK (MIE=0) entry: MPP == 3 (M)"
str_ebreak_mie0_mie:     .asciz "EBREAK (MIE=0) entry: MIE == 0"
str_ebreak_mie0_mpie:    .asciz "EBREAK (MIE=0) entry: MPIE == 0"
str_ebreak_mie0_after:   .asciz "EBREAK (MIE=0) after MRET: MIE == 0"
str_ebreak_mie1_mpp:     .asciz "EBREAK (MIE=1) entry: MPP == 3 (M)"
str_ebreak_mie1_mie:     .asciz "EBREAK (MIE=1) entry: MIE == 0"
str_ebreak_mie1_mpie:    .asciz "EBREAK (MIE=1) entry: MPIE == 1"
str_ebreak_mie1_after:   .asciz "EBREAK (MIE=1) after MRET: MIE == 1"
str_ebreak_regs:         .asciz "EBREAK: a0-a7, t2-t6, s6-s11 survive the round trip"
str_ebreak_repeat:       .asciz "EBREAK x3 in a row, each resumes exactly once"
str_ebreak_repeat_delta: .asciz "EBREAK x3: trap handler hit exactly 3 times"
str_ebreak_align2:       .asciz "EBREAK at an address 2 mod 4 traps and resumes"
str_ebreak_align2_mepc:  .asciz "EBREAK at an address 2 mod 4: mepc exact"
str_ebreak_u_taken:      .asciz "EBREAK from U-mode traps exactly once"
str_ebreak_u_mcause:     .asciz "EBREAK from U-mode: mcause == 3"
str_ebreak_u_mpp:        .asciz "EBREAK from U-mode: MPP == 0 (U)"
str_ebreak_u_mepc:       .asciz "EBREAK from U-mode: mepc == the EBREAK itself"
