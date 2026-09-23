/* =====================================================================
 * xlen.inc  --  the RV64/RV32 switch, .include'd first by every source
 *               file.
 *
 * The same sources build two firmware images (see the Makefile): one for
 * RV64 (rv64imac, lp64) and one for RV32 (rv32imac, ilp32). The Makefile
 * passes --defsym XLEN=64 or --defsym XLEN=32, and everything that
 * depends on the register width goes through this file or an explicit
 * ".if XLEN == 64" block:
 *
 *   REG_BYTES          4 or 8
 *   REG_S / REG_L      sw/lw or sd/ld, for stack slots and other
 *                      register-sized data (8-byte slots are kept on
 *                      RV32 too, so frame layouts are unchanged)
 *   REG_DATA v         .word/.dword of v
 *   XLEN_MASK          0xffffffff or all ones
 *   INTX_MIN/INTX_MAX  the most negative / most positive XLEN-bit
 *                      signed value (INT64_MIN/MAX or INT32_MIN/MAX)
 *   LWUX rd, addr      zero-extending 32-bit load: LWU on RV64, LW on
 *                      RV32 (where a word already fills the register)
 *   LIX rd, value      li, but on RV32 refuses (assembly error) any
 *                      constant that doesn't fit in 32 bits
 *   LIXT rd, value     li of value truncated to XLEN bits, on purpose.
 *                      Only for (a) poison/fill patterns whose meaning
 *                      survives truncation (0xdeadbeefdeadbeef,
 *                      0xaaaaaaaaaaaaaaaa, ...), and (b) the operands AND
 *                      expected value of an operation whose low 32 bits
 *                      depend only on the operands' low 32 bits (copies,
 *                      add/sub, logic ops, left shifts), where
 *                      truncating every side keeps the test exact. Never
 *                      for a value whose meaning is its width (INT64_MAX
 *                      -- use INTX_MAX) or for right shifts / compares.
 *
 * WHY LIX. On RV32, GNU as's li silently truncates a 64-bit constant --
 * "li t3, 0x8000000000000000" assembles to "li t3, 0", no warning -- so
 * an RV64 test value like INT64_MIN would quietly turn into a
 * meaningless one. Every test constant goes through LIX instead. A
 * value that is a 32-bit number, signed or unsigned (including every
 * sign-extended form such as 0xffffffffffffff80), is accepted and
 * means the same thing on RV32; anything else stops the RV32 build, so
 * each such case has to be decided explicitly (an RV32 counterpart, or
 * an ".if XLEN == 64" guard).
 * ===================================================================== */

    .ifndef XLEN
    .error  "XLEN is not defined: assemble with --defsym XLEN=64 or --defsym XLEN=32"
    .endif

    .if XLEN == 64

    .equ    REG_BYTES, 8
    .equ    XLEN_MASK, 0xffffffffffffffff
    .equ    INTX_MIN,  0x8000000000000000
    .equ    INTX_MAX,  0x7fffffffffffffff

.macro REG_S r, addr
    sd      \r, \addr
.endm
.macro REG_L r, addr
    ld      \r, \addr
.endm
.macro REG_DATA v
    .dword  \v
.endm
.macro LIX rd, v
    li      \rd, \v
.endm
.macro LIXT rd, v
    li      \rd, \v
.endm
.macro LWUX rd, addr
    lwu     \rd, \addr
.endm

    .elseif XLEN == 32

    .equ    REG_BYTES, 4
    .equ    XLEN_MASK, 0xffffffff
    .equ    INTX_MIN,  0x80000000
    .equ    INTX_MAX,  0x7fffffff

.macro REG_S r, addr
    sw      \r, \addr
.endm
.macro REG_L r, addr
    lw      \r, \addr
.endm
.macro REG_DATA v
    .word   ((\v) & 0xffffffff)
.endm
.macro LIX rd, v
    .if ((\v) < -0x80000000) || ((\v) > 0xffffffff)
    .error  "LIX: constant does not fit in 32 bits on RV32 -- give this test an RV32 value or guard it with .if XLEN == 64"
    .endif
    li      \rd, \v
.endm
.macro LIXT rd, v
    li      \rd, ((\v) & 0xffffffff)
.endm
.macro LWUX rd, addr
    lw      \rd, \addr
.endm

    .else
    .error  "XLEN must be 64 or 32"
    .endif
