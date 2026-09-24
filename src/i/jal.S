/* =====================================================================
 * i/jal.S  --  RV64I base-ISA JAL (jump and link)
 *
 * Part of the RV64I base-ISA suite; see i/tests.S for how this
 * plugs into the rest (main_tests.S -> i/tests.S -> here), and
 * common.S for the boot/UART/reporting harness everything sits on
 * ("check", "uart_puts" are used from there; nothing else).
 *
 * JAL combines two things the RVC suite tested separately: a
 * PC-relative jump offset (like C.J) and an arbitrary link register
 * (like C.JALR, except JAL's rd is a full 5-bit field -- any register,
 * not fixed to ra). rd=x0 (discarding the link entirely) is the
 * standard idiom for a plain unconditional jump and is tested as a
 * first-class case, not a degenerate one.
 *
 * JAL has no compressed RV64 encoding at all (C.JAL only exists in
 * RV32C; RV64C reuses that opcode slot for C.ADDIW instead), so unlike
 * the RVC branch/jump instructions there is no relaxation boundary to
 * worry about here -- every JAL in this file is unconditionally a
 * 4-byte instruction, with nothing smaller for the assembler to have
 * ever considered.
 *
 * Scope decision on the offset sweep: JAL's 20-bit immediate spans
 * roughly +-1MB and is scrambled across non-adjacent bits
 * (imm[20|10:1|11|19:12]), which is exactly the kind of encoding this
 * project otherwise walks bit-by-bit (see C.J's treatment in the RVC
 * suite). Doing that exhaustively here would mean constructing test
 * distances up to ~512KB via filler instructions for the highest bit
 * alone -- a bad trade for a test binary that's supposed to build and
 * run quickly. Instead this file covers every individual bit of the
 * low 12 bits (magnitudes 4 through 4096 forward, 8 through 4096
 * backward -- backward's bookkeeping overhead means -4 isn't
 * constructible the way +4 is) plus one dedicated test proving the single low-order bit that a run of 4-byte
 * filler instructions can't otherwise reach (offset%4==2, needing a
 * single 2-byte c.nop as inert filler -- not under test itself, just
 * padding) is wired correctly too. The higher-order bits (magnitudes
 * 8192 and up) are not individually swept; the encoding mechanism
 * being exercised is identical to the bits that are covered, just at
 * a scale this suite doesn't consider worth the binary size and build
 * time it would cost.
 *
 * Bit independence across fields (bitx_i_jal, at the end): every bit
 * pair among rd and the 20-bit offset set together, C(25,2) = 300
 * cases less the 5 noted at BX_C_JAL, each checked for both the landing
 * point and the link value. The full +-1 MiB reach is covered here --
 * without megabytes of filler -- by landing in the counting sled built
 * at run time by bitx.S. See bitx.inc.
 * ===================================================================== */

    .include "xlen.inc"
    .include "harness.inc"

    .option norvc            /* mandatory, not stylistic -- see i/loads.S.
                               * (Moot for JAL itself, which has no RV64
                               * compressed form to be silently substituted
                               * for -- but filler/bookkeeping code in this
                               * file is still plain RV64I by convention,
                               * except the one deliberate c.nop noted
                               * above.) */

    .include "bitx.inc"

    .global tests_i_jal

    .section .text

/* BX_C_JAL nm, rd, v -- one bit-independence case (bitx.inc, bitx.S) for
 * JAL with raw offset field v (offset bits 20:1; bit 20 is the sign).
 * The JAL is assembled into .rodata, planted in the counting sled and
 * run; it must land on exactly the right slot (s5 count) and leave the
 * site's address + 4 in rd, which is poisoned beforehand.
 *
 * Offset +2 alone (bit 1 crossed with an rd bit, 5 cases) is skipped:
 * from a 4-byte instruction it lands in that instruction's own upper
 * half, whose bits are whatever the rest of the encoding happens to be
 * -- not a meaningful target. Bit 1 is still exercised paired with
 * every other offset bit. */
.macro BX_C_JAL nm, rd, v
    .if ((\v) - (((\v) & 0x100000) << 1)) > 2
    BX_C_JAL_ \nm, \rd, \v, ((\v) - (((\v) & 0x100000) << 1)), (BX_EXIT - ((\v) - (((\v) & 0x100000) << 1)) - 2 * BX_MARGIN)
    .elseif ((\v) - (((\v) & 0x100000) << 1)) < 0
    BX_C_JAL_ \nm, \rd, \v, ((\v) - (((\v) & 0x100000) << 1)), BX_SITE_B
    .endif
.endm

.macro BX_C_JAL_ nm, rd, v, d, site
    BX_ENTER
    .pushsection .rodata
    .balign 4
    .option push
    .option norelax
96: jal     x\rd, 96b + (\d)
    .option pop
    .popsection
    BX_PLANT \site, 4
    BX_PV   x\rd, 2
    BX_GO   \site
    mv      s3, x\rd
    BX_COUNT \site, \d, 4, 1
    BX_REPORT "\nm bitx rd=x\rd off=\v landed"
    mv      t6, s3
    .option push
    .option norelax
    la      t5, bx_region + (\site) + 4
    .option pop
    BX_REPORT "\nm bitx rd=x\rd off=\v link"
.endm

/* T_JAL_REG rdreg, name_landed, name_link -- fixed small forward
 * offset, sweep rd across a representative sample. Checks two things
 * independently: did execution land at the target, and does rd end up
 * holding exactly this JAL's own address + 4 (JAL is always 4 bytes).
 * rdreg may be a0/a1/a2 -- the link value is captured into s5 (not a
 * t-register) immediately, since it must survive across two check()
 * calls and check() clobbers t0-t6. */
.macro T_JAL_REG rdreg, name_landed, name_link
    TEST_BEGIN \name_landed
    LIX     s4, 0
.Ljal_reg\@:
    jal     \rdreg, 1f
    LIX     s4, 999                 /* poison: only hit if JAL failed to jump */
1:
    mv      s5, \rdreg              /* capture link value before check() runs */
    la      a0, \name_landed
    LIX     a1, 0
    mv      a2, s4
    call    check

    TEST_BEGIN \name_link
    la      t3, .Ljal_reg\@
    addi    t3, t3, 4               /* expected link = this JAL's addr + 4 */
    la      a0, \name_link
    mv      a1, t3
    mv      a2, s5
    call    check
.endm

/* T_JAL_FWD dist, name -- unconditional forward jump of exactly "dist"
 * bytes (multiple of 4, >=8), rd=x0 (the offset is what's under test
 * here, not the link register -- that's T_JAL_REG's job). Structure:
 * jal(4) + poison li(4) + N nop fillers(4N), dist = 8 + 4N. */
.macro T_JAL_FWD dist, name
    TEST_BEGIN \name
    LIX     s2, 0
.Ljal_fwd\@:
    jal     zero, 1f
    LIX     s2, 999                 /* poison: only hit if JAL landed wrong */
    .rept (\dist - 8) / 4
    nop
    .endr
1:
    la      a0, \name
    LIX     a1, 0
    mv      a2, s2
    call    check
.endm

/* T_JAL_BWD dist, name -- unconditional backward jump of exactly
 * "dist" bytes (multiple of 4, >=8). Jumps ahead first (plain, not
 * under test) to reach the filler run without falling into the target
 * linearly, then the real JAL jumps back over that filler to the
 * success marker. dist = 8 + 4N (4 for the success-marker li, 4 for
 * the bookkeeping jump past the filler, 4N for N nop fillers). */
.macro T_JAL_BWD dist, name
    TEST_BEGIN \name
    LIX     s2, 0
    jal     zero, 5f
4:
    LIX     s2, 1                   /* success marker: the true target */
    jal     zero, 6f
5:
    .rept (\dist - 8) / 4
    nop
    .endr
    jal     zero, 4b
    LIX     s2, 99                  /* poison: only hit if JAL landed wrong */
6:
    la      a0, \name
    LIX     a1, 1
    mv      a2, s2
    call    check
.endm

tests_i_jal:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    /* --- every register in the full 5-bit rd field --- */
    T_JAL_REG ra,  str_jal_landed_ra,  str_jal_link_ra
    T_JAL_REG t0,  str_jal_landed_t0,  str_jal_link_t0
    T_JAL_REG s0,  str_jal_landed_s0,  str_jal_link_s0
    T_JAL_REG a0,  str_jal_landed_a0,  str_jal_link_a0
    T_JAL_REG s10, str_jal_landed_s10, str_jal_link_s10
    T_JAL_REG t6,  str_jal_landed_t6,  str_jal_link_t6

    TEST_BEGIN str_jal_rd_x0
    /* --- rd=x0: the standard "plain unconditional jump" idiom, not
     *     just a degenerate case --- */
    LIX     s4, 0
    jal     zero, 1f
    LIX     s4, 999
1:
    la      a0, str_jal_rd_x0
    LIX     a1, 0
    mv      a2, s4
    call    check

    TEST_BEGIN str_jal_fwd4
    /* --- minimum forward offset with no room for a poison (jal itself
     *     is already 4 bytes, using the whole budget): just confirms
     *     it doesn't crash and lands on the very next instruction --- */
    LIX     s2, 0
    jal     zero, 1f
1:
    la      a0, str_jal_fwd4
    LIX     a1, 0
    mv      a2, s2
    call    check

    /* --- every individual forward offset-field bit, low 12 bits --- */
    T_JAL_FWD 8,    str_jal_fwd8
    T_JAL_FWD 16,   str_jal_fwd16
    T_JAL_FWD 32,   str_jal_fwd32
    T_JAL_FWD 64,   str_jal_fwd64
    T_JAL_FWD 128,  str_jal_fwd128
    T_JAL_FWD 256,  str_jal_fwd256
    T_JAL_FWD 512,  str_jal_fwd512
    T_JAL_FWD 1024, str_jal_fwd1024
    T_JAL_FWD 2048, str_jal_fwd2048
    T_JAL_FWD 4096, str_jal_fwd4096

    TEST_BEGIN str_jal_fwd_oddbit
    /* --- the one low-order bit a run of 4-byte fillers can never
     *     reach on its own (offset%4==2): a single inert c.nop (not
     *     under test, just 2 bytes of padding) proves it's wired --- */
    LIX     s2, 0
    jal     zero, 1f
    .option rvc
    c.nop
    .option norvc
    LIX     s2, 999
1:
    la      a0, str_jal_fwd_oddbit
    LIX     a1, 0
    mv      a2, s2
    call    check

    /* --- every individual backward offset-field bit, low 12 bits.
     *     Note: unlike forward, there's no constructible "-4" case here
     *     -- the backward bookkeeping (success-marker li + skip-jump)
     *     already costs 8 bytes on its own, so -8 is the true minimum
     *     this construction can reach, not -4. --- */
    T_JAL_BWD 8,    str_jal_bwd8
    T_JAL_BWD 16,   str_jal_bwd16
    T_JAL_BWD 32,   str_jal_bwd32
    T_JAL_BWD 64,   str_jal_bwd64
    T_JAL_BWD 128,  str_jal_bwd128
    T_JAL_BWD 256,  str_jal_bwd256
    T_JAL_BWD 512,  str_jal_bwd512
    T_JAL_BWD 1024, str_jal_bwd1024
    T_JAL_BWD 2048, str_jal_bwd2048
    T_JAL_BWD 4096, str_jal_bwd4096

    TEST_BEGIN str_jal_loop
    /* --- repeated use as a loop's "continue" edge (rd=x0, matching
     *     real-world for-loop codegen), exercised on every iteration
     *     but the last, not just a single one-shot distance --- */
    LIX     s0, 0                   /* iteration counter */
2:
    addi    s0, s0, 1
    LIX     t0, 4
    beq     s0, t0, 3f              /* plain beq: not the instruction under test */
    jal     zero, 2b
3:
    la      a0, str_jal_loop
    LIX     a1, 4
    mv      a2, s0
    call    check

    jal     ra, bitx_i_jal

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

bitx_i_jal:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    call    bx_sled_init
    BX_POOL 0, 0                    /* only the sentinel is used */
    /* offset background +8 for the rd-only pairs (0 would jump to
     * itself) */
    BX_E_RI5 BX_C_JAL, "JAL", 7, "0x2,0x4,0x8,0x10,0x20,0x40,0x80,0x100,0x200,0x400,0x800,0x1000,0x2000,0x4000,0x8000,0x10000,0x20000,0x40000,0x80000,0x100000", 8

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

    .section .rodata
str_jal_landed_ra:  .asciz "JAL rd=ra(x1) landed"
str_jal_landed_t0:  .asciz "JAL rd=t0(x5) landed"
str_jal_landed_s0:  .asciz "JAL rd=s0(x8) landed"
str_jal_landed_a0:  .asciz "JAL rd=a0(x10) landed"
str_jal_landed_s10: .asciz "JAL rd=s10(x26) landed"
str_jal_landed_t6:  .asciz "JAL rd=t6(x31) landed"
str_jal_link_ra:  .asciz "JAL rd=ra(x1) link value correct (pc+4)"
str_jal_link_t0:  .asciz "JAL rd=t0(x5) link value correct (pc+4)"
str_jal_link_s0:  .asciz "JAL rd=s0(x8) link value correct (pc+4)"
str_jal_link_a0:  .asciz "JAL rd=a0(x10) link value correct (pc+4)"
str_jal_link_s10: .asciz "JAL rd=s10(x26) link value correct (pc+4)"
str_jal_link_t6:  .asciz "JAL rd=t6(x31) link value correct (pc+4)"
str_jal_rd_x0:    .asciz "JAL rd=x0 (plain unconditional jump idiom)"
str_jal_fwd4:    .asciz "JAL forward +4 (bit2, minimum, no poison possible)"
str_jal_fwd8:    .asciz "JAL forward +8 (bit3)"
str_jal_fwd16:   .asciz "JAL forward +16 (bit4)"
str_jal_fwd32:   .asciz "JAL forward +32 (bit5)"
str_jal_fwd64:   .asciz "JAL forward +64 (bit6)"
str_jal_fwd128:  .asciz "JAL forward +128 (bit7)"
str_jal_fwd256:  .asciz "JAL forward +256 (bit8)"
str_jal_fwd512:  .asciz "JAL forward +512 (bit9)"
str_jal_fwd1024: .asciz "JAL forward +1024 (bit10)"
str_jal_fwd2048: .asciz "JAL forward +2048 (bit11)"
str_jal_fwd4096: .asciz "JAL forward +4096 (bit12)"
str_jal_fwd_oddbit: .asciz "JAL forward +10 (odd low bit, offset%4==2)"
str_jal_bwd8:    .asciz "JAL backward -8 (bit3, minimum)"
str_jal_bwd16:   .asciz "JAL backward -16 (bit4)"
str_jal_bwd32:   .asciz "JAL backward -32 (bit5)"
str_jal_bwd64:   .asciz "JAL backward -64 (bit6)"
str_jal_bwd128:  .asciz "JAL backward -128 (bit7)"
str_jal_bwd256:  .asciz "JAL backward -256 (bit8)"
str_jal_bwd512:  .asciz "JAL backward -512 (bit9)"
str_jal_bwd1024: .asciz "JAL backward -1024 (bit10)"
str_jal_bwd2048: .asciz "JAL backward -2048 (bit11)"
str_jal_bwd4096: .asciz "JAL backward -4096 (bit12)"
str_jal_loop:    .asciz "JAL as a loop's backward continue edge, 3 iterations"
