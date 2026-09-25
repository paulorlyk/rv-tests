/* =====================================================================
 * c/tests.S  --  RV64/RV32 "C" (compressed) instruction-set exerciser
 *                   (RVC suite orchestrator)
 *
 * The RVC test suite is split across four files:
 *   c/tests.S         - this file. Defines run_c_tests, the entry
 *                       point main_tests.S calls into, which prints
 *                       the banner and then calls each quadrant's
 *                       entry point in turn.
 *   c/quadrant0.S     - C.ADDI4SPN, C.LW, C.SW, C.LD, C.SD
 *   c/quadrant1.S     - C.NOP, C.ADDI, C.ADDIW, C.LI, C.ADDI16SP, C.LUI,
 *                       C.SRLI, C.SRAI, C.ANDI, C.SUB, C.XOR, C.OR,
 *                       C.AND, C.SUBW, C.ADDW, C.J, C.BEQZ, C.BNEZ
 *   c/quadrant2.S     - C.SLLI, C.LWSP, C.LDSP, C.JR, C.MV, C.EBREAK,
 *                       C.JALR, C.ADD, C.SWSP, C.SDSP
 * The quadrant grouping matches the RVC spec's own opcode layout (bits
 * [1:0] of the 16-bit instruction select the quadrant), and each file
 * only exposes one symbol (tests_c_quadrantN) to the others -- their
 * per-instruction test subroutines and macros stay local. All boot/
 * UART/reporting plumbing lives in common.S; every file here just uses
 * "check" (compare + report) and "uart_puts" from it.
 *
 * This is one of possibly several instruction-set suites main_tests.S
 * calls into (see i/tests.S for the RV64I base-ISA suite) -- see
 * that file's header for how a new suite plugs in.
 *
 * Every one of the 33 integer RVC instructions (RV64C, no D/F ext) is
 * executed explicitly, using the "c.xxx" mnemonics so the assembler is
 * forced to emit exactly that 16-bit encoding (and will error at build
 * time if the chosen operands don't fit the compressed format).
 *
 * Coverage philosophy: for each instruction we don't just run it once
 * with one convenient operand. Where the encoding restricts registers
 * (rd'/rs1'/rs2' limited to x8-x15) we sweep every legal register to
 * catch a wrong bit in the 3-bit field decode; where the immediate is
 * scrambled across non-adjacent instruction bits we walk every
 * individual bit plus boundary and mixed-bit-pattern values to catch
 * cross-wiring; and where the spec documents an invariant (e.g. "must
 * not modify sp", "pure read, does not touch memory") we check it
 * explicitly.
 *
 * Instructions NOT covered: C.FLD/C.FSD/C.FLDSP/C.FSDSP (require the D
 * extension) and C.FLW/C.FSW (RV32FC only, do not exist in RV64C).
 * C.JAL is RV32C-only (its encoding is C.ADDIW on RV64C, which IS
 * tested there); the RV32 image tests C.JAL instead. C.UNIMP is an intentionally-illegal all-zero pattern and is
 * not something you "execute".
 *
 * RV32 image (see xlen.inc and README "RV64 and RV32"): C.LD, C.SD,
 * C.LDSP, C.SDSP, C.ADDIW, C.SUBW and C.ADDW are RV64C-only and left
 * out (on RV32C the first four encodings are C.FLW/C.FSW/C.FLWSP/
 * C.FSWSP, out of scope as above); C.JAL is added (c/quadrant1.S);
 * the compressed shifts take a 5-bit shamt.
 * ===================================================================== */

    .include "xlen.inc"

    .option norvc

    .global run_c_tests

    .section .text

/* ----------------------------------------------------------------------
 * run_c_tests: RVC suite entry point, called once by main_tests.S.
 * tests_c_quadrant0/1/2 are each defined in their own file (see header).
 * -------------------------------------------------------------------- */
run_c_tests:
    addi    sp, sp, -16
    REG_S   ra, 0(sp)

    call    insn_close          /* end the previous suite's last group */
    la      a0, str_banner
    call    uart_puts

    call    tests_c_quadrant0
    call    tests_c_quadrant1
    call    tests_c_quadrant2

    REG_L   ra, 0(sp)
    addi    sp, sp, 16
    ret

    .section .rodata
    .if XLEN == 64
str_banner: .asciz "\r\n\r\n=== RV64C compressed-instruction test suite ===\r\n\r\n"
    .else
str_banner: .asciz "\r\n\r\n=== RV32C compressed-instruction test suite ===\r\n\r\n"
    .endif
