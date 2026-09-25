/* =====================================================================
 * i/fence.S  --  RV64I/RV32I base-ISA FENCE (memory and I/O ordering)
 *
 * Part of the RV64I base-ISA suite; see i/tests.S for how this plugs
 * into the rest (main_tests.S -> i/tests.S -> here), and common.S for
 * the boot/UART/reporting harness everything sits on ("check",
 * "test_begin" and the armed trap mode are used from there). FENCE is
 * RV32I proper (MISC-MEM opcode, funct3 = 0); FENCE.I, funct3 = 1, is
 * Zifencei and lives in zifencei/fencei.S.
 *
 * Encoding: fm[31:28] pred[27:24] succ[23:20] rs1[19:15] 000 rd[11:7]
 * 0001111, pred/succ = {I, O, R, W} from bit 3 down. FENCE orders
 * memory and I/O accesses as seen by *other* harts and devices; on a
 * single hart, with nothing else on the bus, the ordering itself isn't
 * observable. What a single hart can check, and what a decoder can get
 * wrong, is everything else:
 *   - FENCE has no architectural side effect: no register changes,
 *     no trap, and the instruction right after it runs exactly once --
 *     for the common pred/succ combinations, FENCE.TSO (fm = 1000),
 *     PAUSE (Zihintpause's FENCE w,0, a HINT that must still execute
 *     as a FENCE on a hart without Zihintpause) and FENCE 0,0;
 *   - the reserved fields are ignored, as the spec requires: nonzero rd
 *     is not written, nonzero rs1 is not read as anything, and a
 *     reserved fm value is treated as a normal fence -- each alone and
 *     all at once;
 *   - four FENCEs back to back, and one at an address that is 2 mod 4
 *     (legal with the C extension);
 *   - memory around a FENCE: a load after a store (FENCE w,r) sees the
 *     store, four byte stores then a word load (FENCE rw,rw), a load
 *     before a FENCE r,w sees the old value and a store after it lands;
 *   - device I/O around a FENCE: the UART's line control register
 *     (LCR), written then read back across FENCE o,i, and written twice
 *     across FENCE o,o (the later write wins). LCR, not the scratch
 *     register, which not every 8250/16550 has; the transmitter is
 *     drained (LSR.TEMT) before each LCR write, the values only change
 *     parity/stop bits (never DLAB or break), and 8N1 is restored
 *     before anything more is printed, on the trap path too;
 *   - FENCE is unprivileged: in U-mode it doesn't trap (the ECALL after
 *     it is what traps, with mcause 8 and mepc at the ECALL).
 *
 * TRAPS: FENCE is base ISA, but a decoder that traps on one of the
 * variants (a reserved field, fm = 1000, pred or succ = 0) is a
 * misbehaving FENCE, and that must be a FAIL, not an UNEXPECTED TRAP
 * hang. So every FENCE here runs armed (TRAP_ARM/TRAP_FAILS,
 * harness.inc), the bitx cases included (BX_TRAP_FAILS). The U-mode
 * test is armed by construction: the ECALL after the FENCE (and an
 * mscratch read after that) always ends in the handler.
 *
 * ASSUMPTIONS: the ns16550a's LCR (offset 3) reads back what was
 * written and its LSR (offset 5) has TEMT at bit 6, as on every 16550
 * (common.S's UART_BASE and 8N1 setup), and U-mode is implemented
 * with PMP (if any) letting U-mode reach all memory, which common.S's
 * reset sets up.
 *
 * Bit independence across fields (bitx_i_fence, at the end): every
 * FENCE encoding is a fence, so all 22 bits of rd, rs1 and the 12-bit
 * fm/pred/succ field are variable, background 0 (FENCE 0,0 with the
 * reserved fields zero), C(22,2) = 231 cases, each emitted with .insn.
 * Every one must leave rd alone and let a store before it be read back
 * after it. See BX_C_FE below and bitx.inc.
 *
 * Built unchanged for both widths.
 * ===================================================================== */

    .include "xlen.inc"
    .include "harness.inc"

    .option norvc            /* mandatory, not stylistic -- see i/loads.S */

    .include "bitx.inc"

    .global tests_i_fence

    .equ FE_UART,      0x10000000       /* common.S's UART_BASE */
    .equ FE_UART_LCR,  3
    .equ FE_UART_LSR,  5
    .equ FE_LSR_TEMT,  0x40             /* transmitter completely idle */
    .equ FE_LCR_8N1,   0x03             /* common.S's UART_LCR_8N1 */
    .equ FE_LCR_8N2,   0x07             /* 2 stop bits */
    .equ FE_LCR_8E1,   0x1b             /* even parity */
    .equ FE_BX_PAT,   0x0123456789abcdef

    .section .text

/* =======================================================================
 *  Shared macros
 * ======================================================================= */

/* FE_CHK name, expected, actual -- check(name, LIX expected, actual).
 * actual must not be a0/a1. */
.macro FE_CHK name, exp, act
    la      a0, \name
    LIX     a1, \exp
    mv      a2, \act
    call    check
.endm

/* T_FE_REGS name, n, align2, insn -- \insn (any FENCE form, written as
 * the assembler or .insn takes it) run \n times back to back, with
 * five registers holding distinct patterns (a3, a4, a5, t3, t4: rd and
 * rs1 of the reserved-field variants are chosen among them) and
 * s1 = 0. The instruction right after is "addi s1, s1, 1". One check:
 * (reg ^ pattern) ORed together, ORed with s1 ^ 1, must be 0 -- every
 * register untouched and the next instruction run exactly once. With
 * align2 the FENCEs start at an address that is 2 mod 4 (a c.nop in
 * front; one after the addi aligns the code that follows again). */
.macro T_FE_REGS name, n, align2, insn:vararg
    TEST_BEGIN \name
    LIXT    a3, 0x0123456789abcdef
    LIXT    a4, 0xfedcba9876543210
    LIXT    a5, 0x5a5a5a5aa5a5a5a5
    LIXT    t3, 0x8000000000000001
    LIXT    t4, 0x7ffffffffffffffe
    li      s1, 0
    TRAP_ARM .Lfe_trap\@
    .if \align2
    .option push
    .option rvc
    c.nop
    .option pop
    .endif
    .rept   \n
    \insn
    .endr
    addi    s1, s1, 1
    .if \align2
    .option push
    .option rvc
    c.nop
    .option pop
    .endif
    TRAP_DISARM
    LIXT    t0, 0x0123456789abcdef
    xor     t5, a3, t0
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
    xori    t0, s1, 1
    or      s2, t5, t0
    FE_CHK  \name, 0, s2
    TRAP_FAILS .Lfe_trap\@, \name
.endm

/* BX_C_FE nm, rd, rs1, v -- one bit-independence case (bitx.inc): the
 * FENCE encoding with rd/rs1 as given and imm = v (the raw 12-bit
 * fm/pred/succ field), emitted with .insn.
 *
 * fe_buf is zeroed, rd and rs1 are loaded with the sentinel (rd first:
 * when they alias, it's the same register and the same value), the
 * pattern FE_BX_PAT is stored to fe_buf, the FENCE under test runs, rd
 * is captured into a4 and fe_buf is read back. Two checks: the
 * read-back is the pattern (an assemble-time constant), and rd still
 * holds the sentinel (0 for x0).
 *
 * Besides the reserved registers listed in bitx.inc, s3 (fe_buf's
 * address), t4 (the pattern, then disarming) and a4 (x14, the captured
 * rd) are used; none is ever a candidate.
 *
 * Trapping: armed before anything is swept; after a trap,
 * BX_TRAP_FAILS restores sp/gp/tp and reports both names as check_trap
 * FAILs. */
.macro BX_C_FE nm, rd, rs1, v
    BX_NAME .Lbxe_m\@, "\nm bitx rd=x\rd rs1=x\rs1 imm=\v mem"
    BX_NAME .Lbxe_r\@, "\nm bitx rd=x\rd rs1=x\rs1 imm=\v rd"
    BX_ENTER .Lbxe_m\@
    .option push
    .option norelax
    la      s3, fe_buf
    .option pop
    REG_S   zero, 0(s3)
    TRAP_ARM .Lbxe_trap\@
    BX_PV   x\rd, 2
    BX_PV   x\rs1, 2
    BX_PV   t4, 0
    REG_S   t4, 0(s3)
    .insn   i 0x0f, 0, x\rd, x\rs1, ((\v) - (((\v) & 0x800) << 1))
    mv      a4, x\rd
    REG_L   t6, 0(s3)
    TRAP_DISARM_R t4
    BX_LDC  t5, FE_BX_PAT
    BX_REPORT_AT .Lbxe_m\@
    .if \rd == 0
    mv      t5, zero
    .else
    BX_PV   t5, 2
    .endif
    mv      t6, a4
    BX_REPORT_AT .Lbxe_r\@
    BX_TRAP_FAILS .Lbxe_trap\@, .Lbxe_m\@, .Lbxe_r\@
.endm

/* =======================================================================
 *  Entry point
 * ======================================================================= */
tests_i_fence:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    jal     ra, test_fence_regs
    jal     ra, test_fence_mem
    jal     ra, test_fence_io
    jal     ra, test_fence_umode

    jal     ra, bitx_i_fence

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  No side effects: registers, next instruction, reserved fields
 * ======================================================================= */
test_fence_regs:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    T_FE_REGS str_fe_iorw,     1, 0, fence iorw,iorw
    T_FE_REGS str_fe_rw,       1, 0, fence rw,rw
    T_FE_REGS str_fe_r_r,      1, 0, fence r,r
    T_FE_REGS str_fe_w_w,      1, 0, fence w,w
    T_FE_REGS str_fe_r_rw,     1, 0, fence r,rw
    T_FE_REGS str_fe_rw_w,     1, 0, fence rw,w
    T_FE_REGS str_fe_w_r,      1, 0, fence w,r
    T_FE_REGS str_fe_i_i,      1, 0, fence i,i
    T_FE_REGS str_fe_o_o,      1, 0, fence o,o
    T_FE_REGS str_fe_i_o,      1, 0, fence i,o
    T_FE_REGS str_fe_o_i,      1, 0, fence o,i
    T_FE_REGS str_fe_tso,      1, 0, fence.tso
    /* PAUSE: pred = W, succ = 0 */
    T_FE_REGS str_fe_pause,    1, 0, .insn i 0x0f, 0, x0, x0, 0x010
    T_FE_REGS str_fe_zero,     1, 0, .insn i 0x0f, 0, x0, x0, 0
    /* reserved fields: rd = a3, rs1 = a4, fm = 1111 / 0001 */
    T_FE_REGS str_fe_rd,       1, 0, .insn i 0x0f, 0, a3, x0, 0x0ff
    T_FE_REGS str_fe_rs1,      1, 0, .insn i 0x0f, 0, x0, a4, 0x0ff
    T_FE_REGS str_fe_fm_f,     1, 0, .insn i 0x0f, 0, x0, x0, 0xf33 - 0x1000
    T_FE_REGS str_fe_fm_1,     1, 0, .insn i 0x0f, 0, x0, x0, 0x133
    T_FE_REGS str_fe_all_rsv,  1, 0, .insn i 0x0f, 0, t4, a5, -1
    T_FE_REGS str_fe_x4,       4, 0, fence rw,rw
    T_FE_REGS str_fe_align2,   1, 1, fence rw,rw

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  Memory accesses around a FENCE
 * ======================================================================= */
test_fence_mem:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    /* --- store, FENCE w,r, load: the load sees the store --- */
    TEST_BEGIN str_fe_mem_wr
    la      s3, fe_buf
    REG_S   zero, 0(s3)
    LIXT    t4, 0x8badf00dcafe1234
    TRAP_ARM .Lfe_trap_mem_wr
    REG_S   t4, 0(s3)
    fence   w,r
    REG_L   s1, 0(s3)
    TRAP_DISARM
    la      a0, str_fe_mem_wr
    LIXT    a1, 0x8badf00dcafe1234
    mv      a2, s1
    call    check
    TRAP_FAILS .Lfe_trap_mem_wr, str_fe_mem_wr

    /* --- four byte stores, FENCE rw,rw, one word load --- */
    TEST_BEGIN str_fe_mem_bytes
    la      s3, fe_buf
    REG_S   zero, 0(s3)
    li      t0, 0x11
    li      t1, 0x22
    li      t3, 0x33
    li      t4, 0x44
    TRAP_ARM .Lfe_trap_mem_bytes
    sb      t0, 0(s3)
    sb      t1, 1(s3)
    sb      t3, 2(s3)
    sb      t4, 3(s3)
    fence   rw,rw
    lw      s1, 0(s3)
    TRAP_DISARM
    FE_CHK  str_fe_mem_bytes, 0x44332211, s1
    TRAP_FAILS .Lfe_trap_mem_bytes, str_fe_mem_bytes

    /* --- load, FENCE r,w, store, then load again: the first load sees
     *     the old value, the second the new one --- */
    TEST_BEGIN str_fe_mem_old
    la      s3, fe_buf
    LIXT    t3, 0x1111111122222222
    LIXT    t4, 0x3333333344444444
    REG_S   t3, 0(s3)
    TRAP_ARM .Lfe_trap_mem_rw
    fence   w,r
    REG_L   s1, 0(s3)
    fence   r,w
    REG_S   t4, 0(s3)
    fence   w,r
    REG_L   s2, 0(s3)
    TRAP_DISARM
    la      a0, str_fe_mem_old
    LIXT    a1, 0x1111111122222222
    mv      a2, s1
    call    check
    TEST_BEGIN str_fe_mem_new
    la      a0, str_fe_mem_new
    LIXT    a1, 0x3333333344444444
    mv      a2, s2
    call    check
    TRAP_FAILS .Lfe_trap_mem_rw, str_fe_mem_old, str_fe_mem_new

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  Device I/O around a FENCE (the UART's line control register)
 *
 *  s3 = UART base throughout. FE_LCR_PUT waits for LSR.TEMT, so no
 *  character is on the wire when the framing changes, then writes LCR.
 *  Each case ends at an "out" label that both paths reach: the no-trap
 *  path falls into it after TRAP_DISARM, the armed trap resumes there.
 *  It puts 8N1 back before the check (or TRAP_FAILS) prints anything,
 *  and a trap_count delta picks the path.
 * ======================================================================= */

/* FE_LCR_PUT val -- wait until the UART transmitter is idle, then
 * LCR = \val. Uses s3 (UART base) and t0. */
.macro FE_LCR_PUT val
.Lfe_temt\@:
    lbu     t0, FE_UART_LSR(s3)
    andi    t0, t0, FE_LSR_TEMT
    beqz    t0, .Lfe_temt\@
    li      t0, \val
    sb      t0, FE_UART_LCR(s3)
.endm

test_fence_io:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)
    REG_S   s0, 8(sp)

    /* --- LCR write, FENCE o,i, LCR read --- */
    TEST_BEGIN str_fe_io_oi
    li      s3, FE_UART
    lw      s0, trap_count
    FE_LCR_PUT FE_LCR_8N1
    li      t4, FE_LCR_8N2
    TRAP_ARM .Lfe_io_oi_out
    sb      t4, FE_UART_LCR(s3)
    fence   o,i
    lbu     s1, FE_UART_LCR(s3)
    TRAP_DISARM
.Lfe_io_oi_out:
    FE_LCR_PUT FE_LCR_8N1
    lw      t0, trap_count
    bne     t0, s0, .Lfe_trap_io_oi
    FE_CHK  str_fe_io_oi, FE_LCR_8N2, s1
    TRAP_FAILS .Lfe_trap_io_oi, str_fe_io_oi

    /* --- two LCR writes across FENCE o,o: the later one wins --- */
    TEST_BEGIN str_fe_io_oo
    li      s3, FE_UART
    lw      s0, trap_count
    FE_LCR_PUT FE_LCR_8N1
    li      t3, FE_LCR_8E1
    li      t4, FE_LCR_8N2
    TRAP_ARM .Lfe_io_oo_out
    sb      t3, FE_UART_LCR(s3)
    fence   o,o
    sb      t4, FE_UART_LCR(s3)
    fence   o,i
    lbu     s1, FE_UART_LCR(s3)
    TRAP_DISARM
.Lfe_io_oo_out:
    FE_LCR_PUT FE_LCR_8N1
    lw      t0, trap_count
    bne     t0, s0, .Lfe_trap_io_oo
    FE_CHK  str_fe_io_oo, FE_LCR_8N2, s1
    TRAP_FAILS .Lfe_trap_io_oo, str_fe_io_oo

    REG_L   ra, 0(sp)
    REG_L   s0, 8(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  FENCE in U-mode
 *
 *  Enter U-mode (MPP = U, MPIE = 0, MRET) at a FENCE rw,rw and a
 *  FENCE.TSO followed by an ECALL. A working FENCE doesn't trap, so the
 *  armed handler sees the ECALL: mcause 8, mepc = the ECALL. A FENCE
 *  that traps shows up as another cause (2) and mepc; the mscratch read
 *  after the ECALL is a backstop that keeps execution from staying in
 *  U-mode. mie is 0 throughout (M-mode interrupts are enabled in U-mode
 *  whatever mstatus.MIE says).
 * ======================================================================= */
test_fence_umode:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)
    REG_S   s0, 8(sp)

    csrrw   s0, mie, zero

    TEST_BEGIN str_fe_u_mcause
    TRAP_ARM .Lfe_u_back
    li      t0, MSTATUS_MPP | MSTATUS_MPIE
    csrc    mstatus, t0
    la      t0, .Lfe_u_at
    csrw    mepc, t0
    mret
.Lfe_u_at:
    fence   rw,rw
    fence.tso
.Lfe_u_ecall:
    ecall
    csrr    t0, mscratch            /* backstop: illegal in U-mode */
.Lfe_u_back:
    TRAP_DISARM
    TRAP_LD s1, mcause
    TRAP_LD s2, mepc
    FE_CHK  str_fe_u_mcause, 8, s1
    TEST_BEGIN str_fe_u_mepc
    la      a0, str_fe_u_mepc
    la      a1, .Lfe_u_ecall
    mv      a2, s2
    call    check

    csrw    mie, s0
    REG_L   ra, 0(sp)
    REG_L   s0, 8(sp)
    addi    sp, sp, 16
    ret

/* Bit independence across fields -- see the file header, BX_C_FE and
 * bitx.inc. rd and rs1 are 5-bit register fields with background x0,
 * imm is the 12-bit fm/pred/succ field with background 0. Pool: the
 * stored pattern and the sentinel. */
bitx_i_fence:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    BX_POOL FE_BX_PAT, 0
    BX_E_RRI5 BX_C_FE, "FENCE", 0, 0, "0x1,0x2,0x4,0x8,0x10,0x20,0x40,0x80,0x100,0x200,0x400,0x800", 0

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

/* =======================================================================
 *  Strings
 * ======================================================================= */
    .section .rodata
str_fe_iorw:      .asciz "FENCE iorw,iorw: registers unchanged, next insn runs once"
str_fe_rw:        .asciz "FENCE rw,rw: registers unchanged, next insn runs once"
str_fe_r_r:       .asciz "FENCE r,r: registers unchanged, next insn runs once"
str_fe_w_w:       .asciz "FENCE w,w: registers unchanged, next insn runs once"
str_fe_r_rw:      .asciz "FENCE r,rw: registers unchanged, next insn runs once"
str_fe_rw_w:      .asciz "FENCE rw,w: registers unchanged, next insn runs once"
str_fe_w_r:       .asciz "FENCE w,r: registers unchanged, next insn runs once"
str_fe_i_i:       .asciz "FENCE i,i: registers unchanged, next insn runs once"
str_fe_o_o:       .asciz "FENCE o,o: registers unchanged, next insn runs once"
str_fe_i_o:       .asciz "FENCE i,o: registers unchanged, next insn runs once"
str_fe_o_i:       .asciz "FENCE o,i: registers unchanged, next insn runs once"
str_fe_tso:       .asciz "FENCE.TSO: registers unchanged, next insn runs once"
str_fe_pause:     .asciz "PAUSE (FENCE w,0): registers unchanged, next insn runs once"
str_fe_zero:      .asciz "FENCE 0,0: registers unchanged, next insn runs once"
str_fe_rd:        .asciz "FENCE reserved rd=a3: rd not written"
str_fe_rs1:       .asciz "FENCE reserved rs1=a4: ignored, registers unchanged"
str_fe_fm_f:      .asciz "FENCE reserved fm=1111: a normal fence"
str_fe_fm_1:      .asciz "FENCE reserved fm=0001: a normal fence"
str_fe_all_rsv:   .asciz "FENCE rd=t4 rs1=a5 imm=0xfff: all reserved bits ignored"
str_fe_x4:        .asciz "FENCE x4 back to back: next insn runs once"
str_fe_align2:    .asciz "FENCE at an address 2 mod 4: next insn runs once"
str_fe_mem_wr:    .asciz "FENCE w,r: load after store sees the store"
str_fe_mem_bytes: .asciz "FENCE rw,rw: four byte stores, then a word load"
str_fe_mem_old:   .asciz "FENCE r,w: load before it sees the old value"
str_fe_mem_new:   .asciz "FENCE r,w: store after it lands"
str_fe_io_oi:     .asciz "FENCE o,i: UART LCR read back after write"
str_fe_io_oo:     .asciz "FENCE o,o: second UART LCR write wins"
str_fe_u_mcause:  .asciz "FENCE in U-mode doesn't trap: ECALL's mcause == 8"
str_fe_u_mepc:    .asciz "FENCE in U-mode doesn't trap: mepc == the ECALL"

/* =======================================================================
 *  Data
 * ======================================================================= */
    .section .bss
    .balign 8
fe_buf:     .skip 8
