/* =====================================================================
 * zicboz/cbozero.S  --  CBO.ZERO (Zicboz): zero a cache block
 *
 * The only category file of the Zicboz suite; see zicboz/tests.S for
 * how this plugs into the rest (main_tests.S -> zicboz/tests.S ->
 * here), and common.S for the boot/UART/reporting harness everything
 * sits on ("check" is used from there, nothing else). CBO.ZERO is its
 * own extension, Zicboz, not RV64I proper, so it has a suite of its own
 * even though that suite is a single instruction.
 *
 * CBO.ZERO rs1 stores zeros to every byte of the cache block that
 * contains the address in rs1: the address is aligned *down* to the
 * block size, the whole block is written, and nothing outside it is.
 * There is no offset (the imm field holds funct12 = 4, which selects
 * the operation) and no destination register (rd must be 0). As a
 * store, it is ordered with this hart's other loads and stores to the
 * same bytes.
 *
 * THE BLOCK SIZE is not discoverable from M-mode (the platform
 * describes it, e.g. in the device tree's riscv,cboz-block-size), so it
 * is an assemble-time constant, CBOZ_BLOCK_BYTES below: 64, QEMU's
 * default (its cboz_blocksize CPU property). Change it for other
 * hardware; it must be a power of two from 8 to 256.
 *
 * HOW A RESULT IS MEASURED. cz_buf is four blocks (B0-B3), aligned to
 * the block size. cz_fill writes a pattern into it in which every byte
 * is nonzero; after the instruction(s) under test, cz_scan compares
 * the buffer against the pattern byte by byte and returns one value
 * describing exactly what changed:
 *     lo  = offset of the first byte that differs from the pattern
 *     hi  = offset of the last differing byte, plus one
 *     bad = bytes in [lo, hi) that are not zero
 *     t6  = (lo << 22) | (hi << 11) | bad
 * so zeroing block k exactly gives (k*B << 22) | ((k+1)*B << 11), i.e.
 * bad = 0 (CZ_EXPV). A
 * block zeroed at the wrong alignment, one that is too big or too
 * small, one zeroed only from the address onwards, a neighbour
 * touched, or a byte left unzeroed each give a different value. The
 * tests only ever target B1 and B2, so both neighbours of every
 * targeted block are inside the scanned buffer.
 *
 * What is checked:
 *   - the zeroed extent is exactly CBOZ_BLOCK_BYTES bytes, and a
 *     block-aligned address zeroes exactly its own block (B1 and B2);
 *   - an unaligned address zeroes the whole containing block: every
 *     single address bit below the block size, the last byte of the
 *     block, and the middle of B2;
 *   - B1 and B2 back to back, and B1 twice;
 *   - loads of every width read 0 afterwards;
 *   - ordering with this hart's own accesses: a store just before it
 *     to the same block is overwritten, a store just after it lands
 *     (and the rest of the block stays zero), and an AMO just after it
 *     reads the zero;
 *   - rs1 = every register x1-x31 (sp, gp and tp included, saved to
 *     memory around the case): the block is zeroed and rs1 is left
 *     unmodified. rs1 = x0 (address 0) is skipped: there is no RAM
 *     there;
 *   - CBO.ZERO leaves the other registers alone;
 *   - below M-mode it is gated by menvcfg.CBZE and, if the hart has
 *     S-mode (misa.S), senvcfg.CBZE. Run in U-mode (MRET, MPP = U) with
 *     an ECALL after it: both set -- no trap (the ECALL traps, mcause
 *     8) and the block is zeroed; menvcfg.CBZE clear -- illegal
 *     (mcause 2, mepc on it, buffer untouched); only senvcfg.CBZE
 *     clear -- illegal with S-mode, zeroes without. In M-mode it works
 *     with both clear. menvcfg/senvcfg are put back afterwards. (QEMU
 *     10.0 checks senvcfg even without S-mode, so with s=false the six
 *     "works in U-mode" checks fail there.)
 * Not tested: CBO.ZERO on a non-writable address.
 *
 * TRAPS: every CBO.ZERO runs armed (TRAP_ARM / TRAP_FAILS, harness.inc),
 * so on a hart without Zicboz, or one where it faults, each check is a
 * check_trap FAIL with the mcause, never an UNEXPECTED TRAP hang. The
 * CBO.ZERO-then-AMOADD.W case also needs A (its AMO is armed too).
 *
 * ASSUMPTIONS: in M-mode CBO.ZERO is always permitted (no envcfg bit
 * gates M-mode). menvcfg exists (U-mode is implemented), and senvcfg
 * too when misa.S is set; U-mode and PMP as for the other U-mode tests
 * (common.S's reset sets PMP up).
 *
 * Bit independence across fields (bitx_zicboz_cbozero, at the end):
 * the only variable field is rs1; rd (0) and funct12 (4) are opcode
 * bits, like the csr field held at mscratch in the Zicsr suite: any
 * other value is a different, reserved encoding. So C(5,2) = 10
 * cases, the two-bit rs1 registers, each checking the scan and that
 * rs1 is unmodified. See BX_C_CZ below and bitx.inc.
 *
 * Built unchanged for both widths.
 * ===================================================================== */

    .include "xlen.inc"
    .include "harness.inc"

    .option norvc            /* mandatory, not stylistic -- see i/loads.S */

    .include "bitx.inc"

    .global tests_zicboz_cbozero

    .section .text

/* =======================================================================
 *  Block geometry and shared macros
 * ======================================================================= */
    .equ    CBOZ_BLOCK_BYTES, 64
    .if (CBOZ_BLOCK_BYTES & (CBOZ_BLOCK_BYTES - 1)) || (CBOZ_BLOCK_BYTES < 8) || (CBOZ_BLOCK_BYTES > 256)
    .error  "CBOZ_BLOCK_BYTES must be a power of two from 8 to 256"
    .endif
    .equ    CZ_B, CBOZ_BLOCK_BYTES
    .equ    CZ_SIZE, 4 * CZ_B           /* cz_buf: B0 B1 B2 B3 */
    .equ    CZ_MID, ((CZ_B / 2) | 4)    /* an unaligned offset in a block */

/* CZ_EXPV reg, lo, hi -- reg = what cz_scan returns when exactly
 * [lo, hi) was zeroed. */
.macro CZ_EXPV reg, lo, hi
    LIX     \reg, (((\lo) << 22) | ((\hi) << 11))
.endm

/* CZ_LA reg, sym -- la pinned pc-relative (never gp-relative: gp is
 * swept as rs1 below). */
.macro CZ_LA reg, sym
    .option push
    .option norelax
    la      \reg, \sym
    .option pop
.endm

/* T_CZ_OFF off, lo, hi, name -- fill, CBO.ZERO at cz_buf + off, scan;
 * [lo, hi) is the block that must have been zeroed. */
.macro T_CZ_OFF off, lo, hi, name
    TEST_BEGIN \name
    jal     ra, cz_fill
    CZ_LA   s1, cz_buf+(\off)
    TRAP_ARM .Lczo_trap\@
    cbo.zero (s1)
    TRAP_DISARM
    jal     ra, cz_scan
    mv      s2, t6
    la      a0, \name
    CZ_EXPV a1, \lo, \hi
    mv      a2, s2
    call    check
    TRAP_FAILS .Lczo_trap\@, \name
.endm

/* T_CZ_BIT off -- T_CZ_OFF at B1 + off, for the single-address-bit
 * walk: only emitted while off is below the block size. */
.macro T_CZ_BIT off
    .if (\off) < CZ_B
    T_CZ_OFF CZ_B+(\off), CZ_B, 2*CZ_B, str_cz_bit\off
    .endif
.endm

/* T_CZ_RS1 n -- rs1 = x<n>, for every n in 1..31: CBO.ZERO at B1 +
 * CZ_MID through that register, then two checks, the scan and rs1
 * unmodified. There is no fixed helper register while x<n> is live
 * (bug class 1 in CLAUDE.md: every register is in the swept list):
 * sp/gp/tp are saved to cz_save through t0 *before* x<n> is loaded,
 * and afterwards x<n> is stored to cz_save through t0 -- or t1 when
 * x<n> is t0 itself -- which is only loaded after x<n> is captured.
 * The names are defined next to the case (str_cz_rs1_x<n>,
 * str_cz_rs1keep_x<n>). Armed from before x<n> is loaded until sp is
 * back; the resume path reloads sp/gp/tp from cz_save itself and
 * reports both checks as check_trap FAILs. */
.macro T_CZ_RS1 n
    .pushsection .rodata
str_cz_rs1_x\n:     .asciz "CBO.ZERO rs1=x\n: containing block zeroed"
str_cz_rs1keep_x\n: .asciz "CBO.ZERO rs1=x\n: rs1 unchanged"
    .popsection
    TEST_BEGIN str_cz_rs1_x\n
    jal     ra, cz_fill
    CZ_LA   t0, cz_save
    REG_S   sp, 0(t0)
    REG_S   gp, 8(t0)
    REG_S   tp, 16(t0)
    TRAP_ARM .Lczr_trap\@           /* sp still valid here */
    CZ_LA   x\n, cz_buf+CZ_B+CZ_MID
    cbo.zero (x\n)
    .if \n == 5
    CZ_LA   t1, cz_save
    REG_S   x\n, 24(t1)
    REG_L   sp, 0(t1)
    REG_L   gp, 8(t1)
    REG_L   tp, 16(t1)
    .else
    CZ_LA   t0, cz_save
    REG_S   x\n, 24(t0)
    REG_L   sp, 0(t0)
    REG_L   gp, 8(t0)
    REG_L   tp, 16(t0)
    .endif
    TRAP_DISARM
    jal     ra, cz_scan
    mv      s2, t6
    la      a0, str_cz_rs1_x\n
    CZ_EXPV a1, CZ_B, 2*CZ_B
    mv      a2, s2
    call    check
    TEST_BEGIN str_cz_rs1keep_x\n
    CZ_LA   t0, cz_save
    REG_L   s2, 24(t0)
    la      a0, str_cz_rs1keep_x\n
    CZ_LA   a1, cz_buf+CZ_B+CZ_MID
    mv      a2, s2
    call    check
    j       .Lczr_done\@
.Lczr_trap\@:                       /* sp/gp/tp may be x<n>: put them back */
    CZ_LA   t0, cz_save
    REG_L   sp, 0(t0)
    REG_L   gp, 8(t0)
    REG_L   tp, 16(t0)
    TRAP_REPORT str_cz_rs1_x\n
    TRAP_REPORT str_cz_rs1keep_x\n
.Lczr_done\@:
.endm

/* BX_C_CZ nm, rs1 -- one bit-independence case (bitx.inc): fill, then
 * CBO.ZERO through x<rs1> = B1 + CZ_MID, capture rs1 into a4, restore
 * sp/gp/tp and scan. Two checks against values that don't come from
 * the encoding under test: the scan against the assemble-time
 * value for exactly [B, 2B), and a4 against the address loaded afresh into t5.
 * Besides the reserved registers listed in bitx.inc, cz_fill/cz_scan
 * use t0, t1, a5-a7 and ra, all after the case is announced and before
 * x<rs1> is loaded or after it is captured; a4 (x14) is never a
 * candidate. Armed from before x<rs1> is loaded until sp is back; a
 * trap reports both checks as check_trap FAILs (BX_TRAP_FAILS). */
.macro BX_C_CZ nm, rs1
    BX_NAME .Lbxc_b\@, "\nm bitx rs1=x\rs1 block"
    BX_NAME .Lbxc_r\@, "\nm bitx rs1=x\rs1 rs1"
    BX_ENTER .Lbxc_b\@
    jal     ra, cz_fill
    TRAP_ARM .Lbxc_trap\@
    CZ_LA   x\rs1, cz_buf+CZ_B+CZ_MID
    cbo.zero (x\rs1)
    mv      a4, x\rs1
    BX_LEAVE
    TRAP_DISARM
    jal     ra, cz_scan
    BX_LDC  t5, ((CZ_B << 22) | ((2 * CZ_B) << 11))
    BX_REPORT_AT .Lbxc_b\@
    CZ_LA   t5, cz_buf+CZ_B+CZ_MID
    mv      t6, a4
    BX_REPORT_AT .Lbxc_r\@
    BX_TRAP_FAILS .Lbxc_trap\@, .Lbxc_b\@, .Lbxc_r\@
.endm

tests_zicboz_cbozero:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    jal     ra, test_cbozero
    jal     ra, test_cz_envcfg

    jal     ra, bitx_zicboz_cbozero

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  Buffer helpers
 * ======================================================================= */

/* cz_fill: cz_buf[i] = (i & 0x7f) | 0x80 for every byte, so no byte is
 * zero. Clobbers t0, t1, t3, t4. */
cz_fill:
    CZ_LA   t0, cz_buf
    li      t1, 0
    li      t3, CZ_SIZE
1:  andi    t4, t1, 0x7f
    ori     t4, t4, 0x80
    sb      t4, 0(t0)
    addi    t0, t0, 1
    addi    t1, t1, 1
    bltu    t1, t3, 1b
    ret

/* cz_scan: compare cz_buf against cz_fill's pattern; t6 = (lo << 22) |
 * (hi << 11) | bad as described in the file header. With nothing
 * changed, lo = CZ_SIZE and hi = 0 (bad is then meaningless, but the
 * value matches no zeroed block). Clobbers t0, t1, t3, t4, a5, a6, a7. */
cz_scan:
    CZ_LA   t0, cz_buf
    li      t1, 0                   /* i */
    li      t4, CZ_SIZE             /* lo */
    li      a5, 0                   /* hi */
    li      a6, 0                   /* differing bytes that are zero */
1:  add     t3, t0, t1
    lbu     t3, 0(t3)
    andi    a7, t1, 0x7f
    ori     a7, a7, 0x80
    beq     t3, a7, 3f
    bgeu    t1, t4, 2f
    mv      t4, t1
2:  addi    a5, t1, 1
    bnez    t3, 3f
    addi    a6, a6, 1
3:  addi    t1, t1, 1
    li      a7, CZ_SIZE
    bltu    t1, a7, 1b
    sub     t6, a5, t4              /* bad = (hi - lo) - zeroed */
    sub     t6, t6, a6
    andi    t6, t6, 0x7ff
    slli    t4, t4, 22
    slli    a5, a5, 11
    or      t6, t6, t4
    or      t6, t6, a5
    ret

/* =======================================================================
 *  CBO.ZERO
 * ======================================================================= */
test_cbozero:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    /* --- the extent zeroed is exactly one block: hi - lo --- */
    TEST_BEGIN str_cz_size
    jal     ra, cz_fill
    CZ_LA   s1, cz_buf+CZ_B
    TRAP_ARM .Lcz_trap_size
    cbo.zero (s1)
    TRAP_DISARM
    jal     ra, cz_scan
    srli    t0, t6, 11
    andi    t0, t0, 0x7ff           /* hi */
    srli    t1, t6, 22              /* lo */
    sub     s2, t0, t1
    la      a0, str_cz_size
    LIX     a1, CZ_B
    mv      a2, s2
    call    check
    TRAP_FAILS .Lcz_trap_size, str_cz_size

    /* --- aligned addresses zero exactly their own block --- */
    T_CZ_OFF CZ_B, CZ_B, 2*CZ_B, str_cz_b1
    T_CZ_OFF 2*CZ_B, 2*CZ_B, 3*CZ_B, str_cz_b2

    /* --- unaligned: every single address bit below the block size,
     *     the block's last byte, and the middle of B2 --- */
    .irp    off, 1, 2, 4, 8, 16, 32, 64, 128
    T_CZ_BIT \off
    .endr
    T_CZ_OFF 2*CZ_B-1, CZ_B, 2*CZ_B, str_cz_last
    T_CZ_OFF 2*CZ_B+CZ_MID, 2*CZ_B, 3*CZ_B, str_cz_b2mid

    /* --- B1 and B2 back to back: exactly [B, 3B) --- */
    TEST_BEGIN str_cz_two
    jal     ra, cz_fill
    CZ_LA   s1, cz_buf+CZ_B+CZ_MID
    CZ_LA   s3, cz_buf+2*CZ_B
    TRAP_ARM .Lcz_trap_two
    cbo.zero (s1)
    cbo.zero (s3)
    TRAP_DISARM
    jal     ra, cz_scan
    mv      s2, t6
    la      a0, str_cz_two
    CZ_EXPV a1, CZ_B, 3*CZ_B
    mv      a2, s2
    call    check
    TRAP_FAILS .Lcz_trap_two, str_cz_two

    /* --- the same block twice --- */
    TEST_BEGIN str_cz_twice
    jal     ra, cz_fill
    CZ_LA   s1, cz_buf+CZ_B
    CZ_LA   s3, cz_buf+2*CZ_B-1
    TRAP_ARM .Lcz_trap_twice
    cbo.zero (s1)
    cbo.zero (s3)
    TRAP_DISARM
    jal     ra, cz_scan
    mv      s2, t6
    la      a0, str_cz_twice
    CZ_EXPV a1, CZ_B, 2*CZ_B
    mv      a2, s2
    call    check
    TRAP_FAILS .Lcz_trap_twice, str_cz_twice

    /* --- loads of every width read 0: signed and unsigned, at the
     *     block's first and last naturally aligned slot, ORed --- */
    TEST_BEGIN str_cz_loads
    jal     ra, cz_fill
    CZ_LA   s1, cz_buf+CZ_B
    TRAP_ARM .Lcz_trap_loads
    cbo.zero (s1)
    TRAP_DISARM
    lb      t0, 0(s1)
    lbu     t1, (CZ_B-1)(s1)
    or      s2, t0, t1
    lh      t0, 0(s1)
    lhu     t1, (CZ_B-2)(s1)
    or      s2, s2, t0
    or      s2, s2, t1
    lw      t0, 0(s1)
    lw      t1, (CZ_B-4)(s1)
    or      s2, s2, t0
    or      s2, s2, t1
    .if XLEN == 64
    lwu     t0, 0(s1)
    ld      t1, (CZ_B-8)(s1)
    or      s2, s2, t0
    or      s2, s2, t1
    .endif
    la      a0, str_cz_loads
    LIX     a1, 0
    mv      a2, s2
    call    check
    TRAP_FAILS .Lcz_trap_loads, str_cz_loads

    /* --- a store just before it, to the same block, is overwritten --- */
    TEST_BEGIN str_cz_st_before
    jal     ra, cz_fill
    CZ_LA   s1, cz_buf+CZ_B
    LIX     t0, 0x12345678
    sw      t0, 8(s1)
    TRAP_ARM .Lcz_trap_st_before
    cbo.zero (s1)
    TRAP_DISARM
    jal     ra, cz_scan
    mv      s2, t6
    la      a0, str_cz_st_before
    CZ_EXPV a1, CZ_B, 2*CZ_B
    mv      a2, s2
    call    check
    TRAP_FAILS .Lcz_trap_st_before, str_cz_st_before

    /* --- a store just after it lands, and only its 4 bytes of the
     *     block are nonzero --- */
    TEST_BEGIN str_cz_st_after
    jal     ra, cz_fill
    CZ_LA   s1, cz_buf+CZ_B
    LIX     t0, 0x12345678
    TRAP_ARM .Lcz_trap_st_after
    cbo.zero (s1)
    TRAP_DISARM
    sw      t0, 8(s1)
    LWUX    s2, 8(s1)
    jal     ra, cz_scan
    mv      s3, t6
    la      a0, str_cz_st_after
    LIX     a1, 0x12345678
    mv      a2, s2
    call    check
    TEST_BEGIN str_cz_st_after_rest
    la      a0, str_cz_st_after_rest
    CZ_EXPV a1, CZ_B, 2*CZ_B
    addi    a1, a1, 4               /* bad = the 4 stored bytes */
    mv      a2, s3
    call    check
    TRAP_FAILS .Lcz_trap_st_after, str_cz_st_after, str_cz_st_after_rest

    /* --- an AMO just after it reads the zero, and adds to it --- */
    TEST_BEGIN str_cz_amo_old
    jal     ra, cz_fill
    CZ_LA   s1, cz_buf+CZ_B
    addi    s3, s1, 16
    LIX     t0, 0x2468ace0
    TRAP_ARM .Lcz_trap_amo
    cbo.zero (s1)
    amoadd.w s2, t0, (s3)
    TRAP_DISARM
    LWUX    s4, 0(s3)
    la      a0, str_cz_amo_old
    LIX     a1, 0
    mv      a2, s2
    call    check
    TEST_BEGIN str_cz_amo_new
    la      a0, str_cz_amo_new
    LIX     a1, 0x2468ace0
    mv      a2, s4
    call    check
    TRAP_FAILS .Lcz_trap_amo, str_cz_amo_old, str_cz_amo_new

    /* --- rs1 = every register x1..x31 --- */
    .irp    n, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31
    T_CZ_RS1 \n
    .endr

    /* --- no register side effects: rs1 (s1) and five registers with
     *     distinct patterns, one CBO.ZERO, then (reg ^ expected) ORed
     *     together must be 0 --- */
    TEST_BEGIN str_cz_regs
    jal     ra, cz_fill
    CZ_LA   s1, cz_buf+CZ_B+CZ_MID
    LIXT    a3, 0x0123456789abcdef
    LIXT    a4, 0xfedcba9876543210
    LIXT    a5, 0x5a5a5a5aa5a5a5a5
    LIXT    t3, 0x8000000000000001
    LIXT    t4, 0x7ffffffffffffffe
    TRAP_ARM .Lcz_trap_regs
    cbo.zero (s1)
    TRAP_DISARM
    CZ_LA   t0, cz_buf+CZ_B+CZ_MID
    xor     t5, s1, t0
    LIXT    t0, 0x0123456789abcdef
    xor     t0, a3, t0
    or      t5, t5, t0
    LIXT    t0, 0xfedcba9876543210
    xor     t0, a4, t0
    or      t5, t5, t0
    LIXT    t0, 0x5a5a5a5aa5a5a5a5
    xor     t0, a5, t0
    or      t5, t5, t0
    LIXT    t0, 0x8000000000000001
    xor     t0, t3, t0
    or      t5, t5, t0
    LIXT    t0, 0x7ffffffffffffffe
    xor     t0, t4, t0
    or      t5, t5, t0
    mv      s2, t5
    la      a0, str_cz_regs
    LIX     a1, 0
    mv      a2, s2
    call    check
    TRAP_FAILS .Lcz_trap_regs, str_cz_regs

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  menvcfg/senvcfg.CBZE: CBO.ZERO below M-mode
 *
 *  s8 = misa.S (senvcfg exists only with S-mode), s9/s10 = menvcfg/
 *  senvcfg as found (put back at the end), s11 = what cz_scan returns
 *  for an untouched buffer.
 * ======================================================================= */
    .equ    CZ_CBZE, 0x80               /* menvcfg/senvcfg.CBZE, bit 7 */

/* CZ_ENVCFG m, s -- menvcfg.CBZE = m, and senvcfg.CBZE = s if the hart
 * has S-mode. Clobbers t0. */
.macro CZ_ENVCFG m, s
    li      t0, CZ_CBZE
    .if \m
    csrs    menvcfg, t0
    .else
    csrc    menvcfg, t0
    .endif
    beqz    s8, .Lcz_env_nos\@
    .if \s
    csrs    senvcfg, t0
    .else
    csrc    senvcfg, t0
    .endif
.Lcz_env_nos\@:
.endm

/* T_CZ_U m, s, trap, s_cause, s_mepc, s_scan -- with CBZE = m / s,
 * CBO.ZERO on B1 in U-mode (MPP = U, MPIE = 0, MRET), an ECALL after
 * it. trap = 1: it must trap (mcause 2, mepc on it, buffer untouched);
 * 0: it must not (the ECALL traps: mcause 8, mepc on the ECALL, B1
 * zeroed); S: trap = misa.S. Both ways end in the armed handler, so
 * neither can hang. */
.macro T_CZ_U m, s, trap, s_cause, s_mepc, s_scan
    TEST_BEGIN \s_cause
    CZ_ENVCFG \m, \s
    jal     ra, cz_fill
    CZ_LA   s1, cz_buf+CZ_B
    CZ_LA   s2, .Lczu_at\@
    CZ_LA   s3, .Lczu_ecall\@
    TRAP_ARM .Lczu_back\@
    li      t0, MSTATUS_MPP | MSTATUS_MPIE
    csrc    mstatus, t0
    csrw    mepc, s2
    mret
.Lczu_at\@:
    cbo.zero (s1)                   /* in U-mode */
.Lczu_ecall\@:
    ecall
.Lczu_back\@:
    TRAP_DISARM
    jal     ra, cz_scan
    mv      s4, t6
    .ifc \trap, S
    mv      s5, s8
    .else
    li      s5, \trap
    .endif
    /* expected: s5 != 0 -> 2 / the CBO.ZERO / untouched,
     *           s5 == 0 -> 8 / the ECALL / B1 zeroed */
    li      a1, 2
    bnez    s5, 1f
    li      a1, 8
1:  TRAP_LD a2, mcause
    la      a0, \s_cause
    call    check
    TEST_BEGIN \s_mepc
    mv      a1, s2
    bnez    s5, 1f
    mv      a1, s3
1:  TRAP_LD a2, mepc
    la      a0, \s_mepc
    call    check
    TEST_BEGIN \s_scan
    mv      a1, s11
    bnez    s5, 1f
    CZ_EXPV a1, CZ_B, 2*CZ_B
1:  mv      a2, s4
    la      a0, \s_scan
    call    check
.endm

test_cz_envcfg:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    csrr    s8, misa
    li      t0, 1 << 18             /* misa.S */
    and     s8, s8, t0
    csrr    s9, menvcfg
    li      s10, 0
    beqz    s8, 1f
    csrr    s10, senvcfg
1:  jal     ra, cz_fill
    jal     ra, cz_scan
    mv      s11, t6

    T_CZ_U  1, 1, 0, str_cz_env_on_cause, str_cz_env_on_mepc, str_cz_env_on_scan
    T_CZ_U  0, 1, 1, str_cz_env_m0_cause, str_cz_env_m0_mepc, str_cz_env_m0_scan
    T_CZ_U  1, 0, S, str_cz_env_s0_cause, str_cz_env_s0_mepc, str_cz_env_s0_scan

    /* --- M-mode ignores CBZE: both clear, still zeroes --- */
    CZ_ENVCFG 0, 0
    T_CZ_OFF CZ_B, CZ_B, 2*CZ_B, str_cz_env_m_mode

    csrw    menvcfg, s9
    beqz    s8, 1f
    csrw    senvcfg, s10
1:
    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* Bit independence across fields -- see the file header, BX_C_CZ and
 * bitx.inc. rs1 is the only variable field: its ten two-bit registers
 * (x3 = gp among them). */
bitx_zicboz_cbozero:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    BX_E_R5 BX_C_CZ, "CBO.ZERO"

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  Strings
 * ======================================================================= */
    .section .rodata
str_cz_size:          .asciz "CBO.ZERO zeroes exactly CBOZ_BLOCK_BYTES bytes"
str_cz_b1:            .asciz "CBO.ZERO aligned address: exactly its block (B1)"
str_cz_b2:            .asciz "CBO.ZERO aligned address: exactly its block (B2)"
str_cz_bit1:          .asciz "CBO.ZERO address bit 0 set: containing block zeroed"
str_cz_bit2:          .asciz "CBO.ZERO address bit 1 set: containing block zeroed"
str_cz_bit4:          .asciz "CBO.ZERO address bit 2 set: containing block zeroed"
str_cz_bit8:          .asciz "CBO.ZERO address bit 3 set: containing block zeroed"
str_cz_bit16:         .asciz "CBO.ZERO address bit 4 set: containing block zeroed"
str_cz_bit32:         .asciz "CBO.ZERO address bit 5 set: containing block zeroed"
    .if CZ_B > 64
str_cz_bit64:         .asciz "CBO.ZERO address bit 6 set: containing block zeroed"
    .endif
    .if CZ_B > 128
str_cz_bit128:        .asciz "CBO.ZERO address bit 7 set: containing block zeroed"
    .endif
str_cz_last:          .asciz "CBO.ZERO last byte of a block: that block zeroed"
str_cz_b2mid:         .asciz "CBO.ZERO middle of B2: B2 zeroed"
str_cz_two:           .asciz "CBO.ZERO two adjacent blocks back to back"
str_cz_twice:         .asciz "CBO.ZERO same block twice"
str_cz_loads:         .asciz "CBO.ZERO then loads of every width read 0"
str_cz_st_before:     .asciz "CBO.ZERO overwrites a store just before it"
str_cz_st_after:      .asciz "CBO.ZERO then store: the store lands"
str_cz_st_after_rest: .asciz "CBO.ZERO then store: rest of the block still zero"
str_cz_amo_old:       .asciz "CBO.ZERO then AMOADD.W: old value is 0"
str_cz_amo_new:       .asciz "CBO.ZERO then AMOADD.W: memory holds the sum"
str_cz_regs:          .asciz "CBO.ZERO leaves registers unchanged"
str_cz_env_on_cause:  .asciz "CBO.ZERO in U-mode, m/senvcfg.CBZE=1: no trap (mcause == 8, the ECALL after it)"
str_cz_env_on_mepc:   .asciz "CBO.ZERO in U-mode, m/senvcfg.CBZE=1: mepc == the ECALL after it"
str_cz_env_on_scan:   .asciz "CBO.ZERO in U-mode, m/senvcfg.CBZE=1: block zeroed"
str_cz_env_m0_cause:  .asciz "CBO.ZERO in U-mode, menvcfg.CBZE=0: mcause == 2 (illegal instruction)"
str_cz_env_m0_mepc:   .asciz "CBO.ZERO in U-mode, menvcfg.CBZE=0: mepc == the CBO.ZERO"
str_cz_env_m0_scan:   .asciz "CBO.ZERO in U-mode, menvcfg.CBZE=0: memory untouched"
str_cz_env_s0_cause:  .asciz "CBO.ZERO in U-mode, senvcfg.CBZE=0: illegal iff S-mode (mcause 2, else 8)"
str_cz_env_s0_mepc:   .asciz "CBO.ZERO in U-mode, senvcfg.CBZE=0: mepc == the CBO.ZERO iff S-mode"
str_cz_env_s0_scan:   .asciz "CBO.ZERO in U-mode, senvcfg.CBZE=0: untouched iff S-mode, else zeroed"
str_cz_env_m_mode:    .asciz "CBO.ZERO in M-mode, m/senvcfg.CBZE=0: block zeroed"

/* =======================================================================
 *  Buffers
 * ======================================================================= */
    .section .bss
    .balign CZ_B
cz_buf:     .skip CZ_SIZE
    .balign 8
cz_save:    .skip 32                /* sp, gp, tp, captured rs1 */
