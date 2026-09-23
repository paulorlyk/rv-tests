# RV64 instruction-set exerciser

A bare-metal, M-mode RISC-V test firmware that exercises RV64 and RV32
instructions and reports OK/FAIL for each case over an ns16550a
serial port. The same sources build two images, one for RV64IMAC and one
for RV32IMAC (see "RV64 and RV32" below). Three instruction-set suites
are included so far — the C (compressed) extension, the I base ISA,
and the M (integer multiply/divide) extension — sharing one common
boot/UART/reporting harness and one running pass/fail total.

## Architecture

All sources are under `src/` (see "Files"); paths below are relative
to it.

- **`common.S`** — the reusable harness. Knows nothing about what's
  being tested. Provides: the reset vector / M-mode entry at
  `0x80000000`, `gp`/`sp`/`mtvec` setup, a minimal trap handler
  (expects only `EBREAK`, reports and hangs on anything else), the
  ns16550a UART driver (9600 8N1 init, `putc`/`puts`, hex/decimal
  printing), the `check` pass/fail comparator (prints a verdict and
  tracks running `pass_count`/`fail_count` totals), and the final
  summary/halt. It calls a single symbol, `run_tests`, and otherwise
  doesn't know or care how many suites exist or what they test.
- **`main_tests.S`** — the top-level dispatcher. Defines `run_tests`
  and just calls each suite's own entry point in turn
  (`run_rvc_tests`, `run_base_tests`, `run_m_tests`). This is the file you touch to
  add a new suite (see "Adding another test suite" below).
- **`rvc/tests.S`** + **`rvc/quadrant0/1/2.S`** — the RV64C suite. See
  "The RVC suite" below.
- **`base/tests.S`** + **`base/loads.S`** — the RV64I base-ISA suite.
  See "The base-ISA suite" below.
- **`m/tests.S`** + **`m/mul.S`**/**`m/div.S`** — the RV64M suite. See
  "The M suite" below.
- **`xlen.inc`** — the RV64/RV32 switch every file includes first; see
  "RV64 and RV32" below.
- **`bitx.inc`** + **`bitx.S`** — shared machinery for the
  bit-independence tests every instruction gets on top of its own
  per-field coverage. See "Bit independence across fields" below.

It has been built and run for real (not just hand-checked) with:
- `binutils-riscv64-linux-gnu` (assembler/linker/objdump) to confirm
  every RVC instruction assembles to its real 2-byte encoding, and
  every base-ISA instruction stays a genuine 4-byte encoding (not
  silently substituted for a compressed form — see "The base-ISA
  suite" below for why that's a real risk worth guarding against).
- `qemu-system-riscv64 -M virt -bios none` to actually execute it — the
  QEMU `virt` machine happens to match this program's assumed memory
  map almost exactly (RAM at `0x80000000`, ns16550a at `0x10000000`,
  boots straight into M-mode when `-bios none` is passed), so it's a
  convenient way to sanity-check the binary before trying it on real
  hardware or another simulator.

Current totals, all passing:

| Image | Result lines | Per-instruction | Bit-independence | UART output (at 9600 baud) |
|---|---|---|---|---|
| RV64 (`build/rv64/`) | **13903** | 1945 | 11958 | ~529 KB, ~9 min |
| RV32 (`build/rv32/`) | **10882** | 1479 | 9403 | ~415 KB, ~7 min |

Under QEMU each run takes about a second.

When the summary has been printed, the hart parks in a `WFI` loop.

## RV64 and RV32

`make` builds both images from the same sources: `build/rv64/rvc_test.{elf,bin}`
(`-march=rv64imac_zicsr_zifencei -mabi=lp64`) and `build/rv32/rvc_test.{elf,bin}`
(`-march=rv32imac_zicsr_zifencei -mabi=ilp32`). Each file gets
`--defsym XLEN=64` or `XLEN=32`, and everything width-dependent goes
through `xlen.inc` or an explicit `.if XLEN == 64` block:

- **Only on RV64** (guarded out of the RV32 image): `LD`, `SD`, `LWU`;
  `ADDIW`, `SLLIW`, `SRLIW`, `SRAIW`; `ADDW`, `SUBW`, `SLLW`, `SRLW`, `SRAW`;
  `MULW`, `DIVW`, `DIVUW`, `REMW`, `REMUW`; `C.LD`, `C.SD`, `C.LDSP`,
  `C.SDSP` (on RV32C those encodings are the floating-point
  `C.FLW`/`C.FSW`/`C.FLWSP`/`C.FSWSP`, out of scope as before),
  `C.ADDIW`, `C.SUBW`, `C.ADDW`; and the few tests that are about bits
  above 31 themselves (e.g. "SW discards the upper 32 bits of rs2",
  "SLTIU's immediate sign-extends to 64, not 32").
- **Only on RV32:** `C.JAL`, which reuses `C.ADDIW`'s encoding. It gets
  the same coverage as `C.J` — every offset bit forward and backward,
  with the same one-slot margin at the boundary — plus a check that
  `ra` = its address + 2, and its own bit-independence cases.
- **Shift amounts are 5 bits on RV32** (`SLLI`/`SRLI`/`SRAI`, the
  compressed shifts, and the `rs2[4:0]` masking of `SLL`/`SRL`/`SRA`), so
  those tests use shamt 31 as the maximum and `rs2=32` as the masking
  boundary. A set shamt[5] is reserved on RV32 and isn't executed.
- **Width-specific values** are either written once in terms of
  `INTX_MIN`/`INTX_MAX` (`INT64_*` or `INT32_*`) or given an RV32 block
  of their own; test names that mention a width are conditional too.
  The M-extension RV32 tables were generated from a Python reference
  model that first reproduces every RV64 expected value in the files.

**How a 64-bit value can't slip into an RV32 test unnoticed.** On RV32,
GNU `as` silently truncates `li` constants — `li t3, 0x8000000000000000`
assembles to `li t3, 0` with no warning. So every test constant goes
through `LIX`, which is plain `li` on RV64 but on RV32 stops the build
with an error for any value that isn't a 32-bit number. Each such case
had to be decided explicitly. `LIXT` truncates on purpose and is kept for
fill patterns and for the operands and expected value of operations
whose low 32 bits depend only on the operands' low 32 bits (copies,
add/sub, logic, left shifts). Both images are also assembled with
`--fatal-warnings`, and QEMU's RV32 model served as the oracle for
everything else.

## The RVC suite

All 33 RV64C integer instructions (RV32 image: the 27 that exist in
RV32C, plus `C.JAL` — see "RV64 and RV32" above), split across four
files:

| File | Instructions |
|---|---|
| `rvc/tests.S` | orchestrator; defines `run_rvc_tests`, prints the banner, calls each quadrant in turn |
| `rvc/quadrant0.S` | `C.ADDI4SPN`, `C.LW`, `C.LD`, `C.SW`, `C.SD` |
| `rvc/quadrant1.S` | `C.NOP`, `C.ADDI`, `C.ADDIW`, `C.LI`, `C.ADDI16SP`, `C.LUI`, `C.SRLI`, `C.SRAI`, `C.ANDI`, `C.SUB`, `C.XOR`, `C.OR`, `C.AND`, `C.SUBW`, `C.ADDW`, `C.J`, `C.BEQZ`, `C.BNEZ` |
| `rvc/quadrant2.S` | `C.SLLI`, `C.LWSP`, `C.LDSP`, `C.JR`, `C.MV`, `C.EBREAK`, `C.JALR`, `C.ADD`, `C.SWSP`, `C.SDSP` |

The quadrant grouping matches the RVC spec's own opcode layout (bits
`[1:0]` of the 16-bit instruction select the quadrant). Each quadrant
file exposes exactly one symbol, `tests_quadrantN`, to the outside —
its macros and per-instruction `test_c_*` subroutines stay local. All
three only depend on `check`/`uart_puts` from `common.S` (plus
`word_buf`, defined in `rvc/quadrant0.S` and used by one test in
`rvc/quadrant1.S` — the one cross-quadrant reference in the suite).

**Not covered:** `C.FLD`/`C.FSD`/`C.FLDSP`/`C.FSDSP` (require the `D`
floating-point extension) and `C.FLW`/`C.FSW` (RV32FC-only, don't
exist in RV64C). `C.JAL` is RV32C-only — on RV64C that encoding is
`C.ADDIW`, which *is* tested there; the RV32 image tests `C.JAL`
instead. `C.UNIMP` is an intentionally-illegal
all-zero bit pattern, not an instruction to execute.

Every instruction gets comprehensive, edge-case-driven coverage:

- **Every legal register** in each restricted field, to catch a wrong
  bit in the 3-bit register decode — including register-aliasing cases
  (e.g. `rd'==rs1'` for loads, `rs1'==rs2'` for stores, `rd'==rs2'` for
  the CA-format ALU ops) with their own, often distinct, expected-value
  logic rather than being skipped.
- **Every individual bit** of the (often non-contiguous/scrambled)
  immediate field in isolation, plus the min/max boundary values and a
  couple of alternating-bit patterns, to catch cross-wiring between
  encoding fields that a single "round number" test would miss.
- **Data-pattern sweeps**, to verify sign extension is applied exactly
  when it should be and not otherwise (`C.LW`, `C.ADDIW`, `C.SUBW`,
  `C.ADDW` all sign-extend a 32-bit result; `C.LD`/`C.SD` don't need
  to, since they're already 64-bit end to end).
- **Garbage-upper-bits handling** for the `W`-suffixed 32-bit ops —
  a register pre-loaded with a nonzero, distinctive upper 32 bits,
  confirming the result depends only on the low 32 bits of each
  operand, not on what else was sitting in the register.
- **Bit independence across fields, not just within one.** Sweeping
  one field while holding another fixed (the two bullets above) is
  enough to catch a bug confined to a single field, but is blind to a
  decoder fault where a bit's effect depends on what some *other*
  field currently holds -- e.g. a wiring fault where one immediate bit
  leaks into the logic that also selects the destination register,
  which could easily be masked for whichever one register an
  independent immediate sweep happens to use, while still being wrong
  for every other one. `C.ADDI4SPN` is the current worked example: on
  top of its independent register and immediate sweeps, it also gets a
  genuine cross-product (every individual `nzuimm` bit crossed against
  every legal `rd'`, 8 x 11 = 88 cases) and a within-field pairwise
  sweep (every pair of individual bits set together, 28 cases, since
  neither a single-bit sweep nor an "all bits" boundary case is
  guaranteed to exercise a two-bit coupling). This is the general
  defense against "any bit of any variable part of the instruction can
  be corrupt [and only show up in combination with some other bit]" --
  see `test_c_addi4spn`'s header comment in `rvc/quadrant0.S` for the
  full reasoning. Every other instruction in every suite now gets the
  generalised form of this — see "Bit independence across fields"
  below.
- **Documented invariants**, e.g. "`C.ADDI4SPN` must not modify `sp`
  itself", "`C.LW`/`C.LD` are pure reads — memory and the base register
  are both unchanged afterward", or "`C.SW`/`C.SD` touch exactly the
  target word/doubleword and nothing adjacent."
- **Control-flow correctness**, for the branch/jump instructions
  (`C.J`, `C.BEQZ`, `C.BNEZ`, `C.JR`, `C.JALR`): since their "immediate"
  is a code distance rather than a literal value, coverage means
  walking individual offset-field bits via deliberately constructed
  jump distances (built with `.rept`-generated filler instructions,
  every one confirmed correct via `objdump` rather than trusted from
  hand arithmetic — see the note on assembler relaxation below), plus
  instruction-specific invariants like `C.JR` not linking `ra` (the
  one property that actually distinguishes it from `C.JALR`) and
  `C.JALR`'s link address landing on exactly the right byte.

Each instruction's test subroutine (`test_c_addi4spn`, `test_c_lw`,
etc.) is built from a small set of reusable macros local to that
subroutine (`T_A4SPN_REG`/`T_A4SPN_IMM`, `T_LW_RD`/`T_LW_RS1`/
`T_LW_OFF`/`T_LW_VAL`, and so on) — the template to follow when
expanding an instruction that doesn't have this treatment yet. A few
macros are shared across related instructions within the same
quadrant file where the arithmetic genuinely overlaps (e.g. `T_CI_RI`
for `C.ADDI`/`C.ADDIW`, `T_CA_RS1`/`T_CA_RS2`/`T_CA_ALIAS` for
`C.SUB`/`C.SUBW`/`C.ADDW`), passing the instruction mnemonic itself as
a macro argument — GNU `as` macro parameters are plain text
substitution, so this works even though it's substituting an opcode,
not just a register or immediate.

Every `c.*` mnemonic is written explicitly (wrapped in
`.option rvc` / `.option norvc`) so the assembler is forced to emit
exactly that compressed encoding, and will fail the build if the
chosen registers/immediate don't fit the format.

## The base-ISA suite

RV64I's load and store instructions:
- **`base/loads.S`**: `LB`, `LH`, `LW`, `LD`, `LBU`, `LHU`, `LWU`
- **`base/stores.S`**: `SB`, `SH`, `SW`, `SD`
- **`base/lui.S`**: `LUI`
- **`base/auipc.S`**: `AUIPC`
- **`base/jal.S`**: `JAL`
- **`base/jalr.S`**: `JALR`
- **`base/branches.S`**: `BEQ`, `BNE`, `BLT`, `BGE`, `BLTU`, `BGEU`
- **`base/op_alu.S`**: `ADD`, `SUB`, `SLL`, `SLT`, `SLTU`, `XOR`, `SRL`, `SRA`, `OR`, `AND`
- **`base/op_imm.S`**: `ADDI`, `SLTI`, `SLTIU`, `XORI`, `ORI`, `ANDI`, `SLLI`, `SRLI`, `SRAI`
- **`base/op_imm32.S`**: `ADDIW`, `SLLIW`, `SRLIW`, `SRAIW` (RV64 only)
- **`base/op_alu32.S`**: `ADDW`, `SUBW`, `SLLW`, `SRLW`, `SRAW` (RV64 only)

Base-ISA instructions have a genuinely different risk profile than
RVC ones, which shapes the coverage differently:

- **No restricted register fields** — `rd`/`rs1`/`rs2` are each a full,
  independent 5-bit field, so there's no 3-bit-field decode risk, but
  a wrong bit in a 5-bit field is still possible, so each register
  operand still gets an independent sweep across a representative
  sample of registers (not exhaustively all 32 — the same
  "representative sample, not full sweep" approach used for RVC's
  full-5-bit fields like `C.ADDI`/`C.MV`/`C.JALR`).
- **No scrambled immediate** — the 12-bit offset is one contiguous
  field, so it only needs boundary values (`+2047`/`-2048`) and a
  couple of representative in-between ones, not an exhaustive per-bit
  sweep the way RVC's scattered encodings needed.
- **Sign vs. zero extension (loads) / discarded upper bits (stores)
  is where the real bugs live.** This project's own test-writing
  history includes more than one sign/zero mixup (`lw` vs `lwu` used
  to verify a store, twice), so `LB`/`LH`/`LW` and their `U`-suffixed
  counterparts are tested with the *exact same* underlying byte
  patterns, so an accidental swap between sign- and zero-extension is
  immediately visible as a mismatched expected value rather than
  something that could quietly pass. Stores have a direct analog even
  though there's no sign-extension question for a *write*: `SB`/`SH`/
  `SW` must use only the low 8/16/32 bits of `rs2` and discard
  whatever garbage is sitting above that, which each gets an explicit
  test for (a source register loaded with distinctive nonzero upper
  bits, confirming only the intended low bits land in memory).
- **`rd=x0` (loads) / `rs2=x0` (stores) is tested once per
  instruction** — for loads, confirms it doesn't fault and genuinely
  discards the loaded value; for stores, confirms storing the
  always-zero register (a common real pattern) actually writes zero.
- **`rs1=x0` is deliberately not tested** — address `0` is unmapped in
  this memory map (RAM starts at `0x80000000`) and there's no
  access-fault handler, so it would hang rather than usefully fail.
- **Offsets are not constrained to natural alignment** for the width
  being loaded/stored. The RISC-V base ISA permits (without mandating
  hardware support for) misaligned accesses, and QEMU's TCG emulation
  handles them transparently — this is not guaranteed portable to all
  real hardware; see "Porting" below.
- **Stores additionally get an adjacent-memory-untouched invariant**
  (sentinel doublewords on both sides of the target, confirming the
  store touches exactly its width and nothing else) and `rs1`/`rs2`
  preservation checks (a store never writes back to either operand
  register) — the same treatment `C.SW`/`C.SD` got in the RVC suite.
- **`LUI` is the one place `rd=sp` gets tested**, since that's the
  actual behavioral difference between it and its compressed cousin
  `C.LUI` (which reserves `rd=x2`/`sp` for `C.ADDI16SP` instead — LUI
  has no such restriction). Handled carefully so `sp` never holds a
  non-stack-pointer value across a subroutine call: poison, execute,
  capture the result, restore the real `sp`, and only then call into
  `check()`. `LUI`'s 20-bit immediate is also a plain, non-scrambled
  field like the load/store offsets, so it gets the same "boundary
  values plus a representative sample" treatment rather than an
  exhaustive per-bit sweep — including both sides of the sign bit
  (bit 19 of the 20-bit field), which determines whether the result
  sign-extends.
- **`AUIPC` shares `LUI`'s immediate encoding exactly, but the result
  is PC-relative** (`rd = pc + sign_extend(imm20 << 12)`, where `pc`
  is the AUIPC instruction's own address) — which means, unlike every
  other instruction in this suite, the expected value for a given test
  case isn't known until the code is actually linked. Every AUIPC test
  computes its own expectation at *runtime* instead of hardcoding one:
  a local label placed exactly at the AUIPC instruction gives its true
  address via `la`, and the immediate's contribution (the same
  sign-extended delta `LUI` would produce for the same value) is added
  to that. There's also a test that doesn't depend on knowing any
  absolute address at all: two AUIPCs with the *same* immediate at two
  different code locations must differ by exactly the byte distance
  between them, since the immediate's contribution cancels out — this
  is the one test that would actually catch an implementation that
  computed AUIPC as if it were LUI, ignoring `pc` entirely (both
  results would come out identical instead of differing by the
  inter-instruction distance).
- **`JAL` combines two dimensions the RVC suite tested separately**: a
  PC-relative jump offset (like `C.J`) and a link register (like
  `C.JALR`, except `JAL`'s `rd` is a full 5-bit field — any register,
  not fixed to `ra`). Each register in the `rd` sweep is checked two
  ways independently: did execution land at the target, and does `rd`
  hold exactly this `JAL`'s own address + 4. `rd=x0` — the standard
  "plain unconditional jump" idiom — is tested as a first-class case
  rather than a degenerate one. Unlike the RVC branch/jump
  instructions, there's no assembler-relaxation boundary to worry
  about here: `JAL` has no RV64 compressed form at all (`C.JAL` is
  RV32C-only; RV64C reuses that opcode slot for `C.ADDIW`), so every
  `JAL` is unconditionally 4 bytes with nothing smaller the assembler
  could have substituted.

  **Scope note:** `JAL`'s 20-bit offset spans roughly ±1MB. Walking
  every bit of it exhaustively — the treatment `C.J` got — would mean
  constructing filler runs up to ~512KB for the top bit alone, a bad
  trade for a test binary meant to build and run quickly. So this file
  sweeps every bit of the low 12 (magnitudes 4–4096 forward, 8–4096
  backward; backward's bookkeeping overhead means `-4` isn't
  constructible the way `+4` is), plus one dedicated test for the
  low-order bit a run of 4-byte fillers can never reach on its own
  (offset ≡ 2 mod 4, needing a single inert 2-byte `c.nop` as padding
  — not under test itself). The higher-order bits use the identical
  encoding mechanism, just at a scale not worth the binary size.
- **`JALR` is register-relative, not PC-relative**, which changes the
  coverage in three ways that make it more than a copy of `JAL`'s
  structure. Its 12-bit immediate is a plain contiguous field and the
  target is computed from a register, so the *full* −2048..+2047 range
  is cheap to sweep at the boundaries — no enormous filler runs needed
  (each case computes its base as `target − imm` at runtime, so the
  jump lands on the label whatever the immediate). The low bit of the
  computed target is **cleared** (`& ~1`), not preserved, which is easy
  to get wrong and is tested directly from both directions: a base
  register set to `(label | 1)`, and an odd bit arriving via the
  immediate instead. And `rd == rs1` is a genuine hazard — the old
  `rs1` must be read as the target *before* `rd` is overwritten with
  the link address, or the jump goes to the link address instead — so
  that aliasing case gets its own landed-and-link pair of checks.
  There's also a real call/return round trip using `JALR` in both
  roles. `.option norvc` is genuinely load-bearing in this file rather
  than just conventional: `JALR` *does* have compressed forms
  (`C.JR`/`C.JALR`) that the assembler would otherwise substitute for
  the `imm=0` cases, silently testing the RVC instruction instead of
  this one — verified by disassembly that zero compressed forms leaked
  in. The three-operand `jalr rd, rs1, imm` form is used throughout
  rather than the `ret`/`jr` pseudo-instructions, so what's under test
  is unambiguous.
- **The six branches share one B-type encoding** and differ only in
  the comparison in `funct3`, so the coverage is organised around what
  actually distinguishes them rather than repeating an identical
  offset sweep six times. All six are run against the *same* set of
  operand pairs with the expected taken/not-taken outcome spelled out
  for each, so a decoder that swaps two of them (`BLT` for `BGE`, or
  `BLTU` for `BLT`) produces a visible mismatch instead of quietly
  passing. The headline cases are the **signed/unsigned divergences**:
  `BLT`/`BGE` compare as signed, `BLTU`/`BGEU` compare the same bits
  as unsigned, so operands like `rs1=-1, rs2=1` give opposite answers
  — signed, `-1 < 1` so `BLT` is taken; unsigned, `0xffff...f > 1` so
  `BLTU` is *not*. `INT64_MIN` vs `INT64_MAX` and `-1` vs `0` are the
  other such pairs. These are precisely what catches a signed/unsigned
  mixup, the bug class that has bitten this project's own test code
  more than once. Equal operands are covered for all six too, since
  that's where the strict/non-strict split shows up (`BLT` not taken
  vs `BGE` taken on `x == x`). The B-type offset field is identical
  across all six, so it's swept once through `BEQ` rather than six
  times over. `.option norvc` is load-bearing here as well: `BEQ`/`BNE`
  against `x0` with an `x8`-`x15` register would otherwise be
  substituted with `C.BEQZ`/`C.BNEZ` — verified by disassembly that
  zero compressed forms leaked in.
- **`base/op_alu.S`'s ten R-type ALU instructions share one encoding**
  and differ only in the operation, so — the same idea as the branch
  file — the register fields (`rd`/`rs1`/`rs2` and every aliasing
  combination) are swept *once*, through `ADD`, rather than ten times
  over; the real per-instruction depth goes into each operation's own
  correctness. `SLL`/`SRL`/`SRA` get a specific, easy-to-get-wrong
  check: only the low 6 bits of `rs2` select the shift amount, so
  `rs2=64` must behave identically to `rs2=0`, and `rs2=65` to `rs2=1`
  — tested directly rather than assumed. `SLT`/`SLTU` get the same
  signed/unsigned divergence pairs used for `BLT`/`BLTU`, for the same
  reason. `.option norvc` matters here too — several of these have
  direct compressed equivalents among `x8`-`x15` registers that the
  assembler would otherwise substitute.
- **`base/op_imm.S`'s nine OP-IMM instructions** follow the same
  pattern as `base/op_alu.S`: `rd`/`rs1` (plus `rd==rs1`, `rd=x0` and
  `rs1=x0`) are swept once, through `ADDI`. Most of the depth goes into
  the immediate. It is **sign-extended to 64 bits before the
  operation for all six non-shift ops**, including the logical ops and
  `SLTIU`, where that is easy to forget. So `XORI rd, rs1, -1` is a full
  64-bit NOT, `ANDI` with `-2048` clears only the low 11 bits, and
  `SLTIU rs1, -1` compares against `0xff..ff`. Each op gets both a
  positive and a negative immediate, so zero-extending in bits 63:12
  shows up as a mismatch. `SLTIU rs1, 1` (the `SEQZ` idiom) is tested
  too. For `SLLI`/`SRLI`/`SRAI` the 6-bit shamt is part of the encoding,
  so every shamt bit is walked individually (1, 2, 4, 8, 16, 32 — bit 5
  exists only on RV64), plus 0 and 63. The same inputs go through both
  `SRLI` and `SRAI`, since the two differ by a single immediate bit.
  Shift amounts ≥ 64 can't be encoded (the assembler rejects them), so
  there is no counterpart to `SLL`'s `rs2=64` masking test.
  `SLTI`/`SLTIU` reuse the `SLT`/`SLTU` signed/unsigned divergence
  pairs. `.option norvc` is load-bearing here: most of these have
  compressed forms (`c.addi`, `c.li`, `c.andi`, `c.slli`, `c.srli`,
  `c.srai`, …). Disassembly confirmed that no compressed forms leaked in.
- **`base/op_imm32.S`'s four OP-IMM-32 instructions** (RV64 only; on
  RV32 the entry point is an empty stub) operate on the low 32 bits of
  `rs1` and **sign-extend the 32-bit result from bit 31**. The tests are
  chosen so that the 64-bit twin would give a different answer. Sources
  carry garbage in `rs1[63:32]`, with and without bit 63 set, and it
  must not affect the result. `ADDIW` wraps at 32 bits
  (`0x7fffffff + 1` → `0xffffffff80000000`, `0xffffffff + 1` → `0` with no
  carry into bit 32), and `ADDIW rd, rs1, 0` is tested as the `SEXT.W`
  idiom in both directions. The shifts take a 5-bit shamt: every shamt
  bit is walked, plus 0 and 31. shamt ≥ 32 is reserved and the assembler
  rejects it. `SLLIW` drops bits shifted past bit 31. `SRLIW`
  zero-fills from bit 31 downward. `SRAIW` fills from bit 31, not
  bit 63, which is checked with bit 31 set and bit 63 clear and the
  other way round. Even shamt 0 must replace the upper word. The same
  inputs go through `SRLIW` and `SRAIW`. `rd`/`rs1` (plus `rd==rs1`,
  `rd=x0` and `rs1=x0`) are swept through `ADDIW`, since OP-IMM-32 has
  its own major opcode. `.option norvc` keeps `ADDIW` from becoming
  `c.addiw`. The bit-independence references are assemble-time
  constants computed from the pool value, not the OP-32 twins, so the
  two files check each other rather than sharing a reference.
- **`base/op_alu32.S`'s five OP-32 instructions** (RV64 only; on RV32
  the entry point is an empty stub) are the register-register twins of
  the above, with the same rules: only the low 32 bits of each source
  count, and the 32-bit result is sign-extended from bit 31. `ADDW` and
  `SUBW` wrap at 32 bits (`INT32_MAX + 1`, `INT32_MIN - 1`,
  `0 - INT32_MIN`, `2^31 + 2^31 = 0`), and garbage in the upper word of
  either source has no effect. For `SLLW`/`SRLW`/`SRAW` only `rs2[4:0]`
  is the shift amount: `rs2[5]` is ignored too, unlike `SLL`, so
  `rs2=32` behaves like 0, `rs2=33` like 1, and an `rs2` with garbage above
  bit 4 still shifts by its low five bits. The fill rules and the paired
  `SRLW`/`SRAW` inputs are the same as for the immediate forms.
  `rd`/`rs1`/`rs2`, `x0` in each position and every aliasing combination
  are swept through `ADDW`. `.option norvc` keeps `ADDW`/`SUBW` from
  becoming `c.addw`/`c.subw`. Bit independence uses the shared R-type
  case (reference = the same instruction in the `t2`/`t3`/`t4`
  encoding). The shift pool value has `rs2[5]` set, so a shift that
  honours it gets a different amount.

Every mnemonic in this suite is written with `.option norvc` active
for the entire file — not just style, but a functional requirement:
without it, the assembler would happily substitute a compressed
encoding whenever the operand choice happens to allow one (e.g.
`lw s0, 0(s1)` → `c.lw`), silently testing the wrong instruction. This
was verified empirically (an `lw`/`ld` pair with compressible operands
confirmed to stay 4 bytes wide under `.option norvc`) before relying
on it throughout the suite.

Two real bugs turned up while building this suite, both the same
underlying mistake in different clothes, worth knowing about if you
extend it further: a macro that sweeps register X while using a fixed
*other* register Y as scratch is broken if Y ever appears as one of
the values X is swept across.

- In `base/loads.S`'s `*_RS1` macro family (sweeps the base register
  while storing a fixed test value first), the scratch value register
  was originally `t0` — but `t0` is also one of the swept `basereg`
  candidates. When `basereg == t0`, loading the test value into `t0`
  destroyed the address just computed there, and the store faulted
  (`mcause 7`, store/AMO access fault). Fixed by moving the scratch to
  `t1` (not in the sweep list).
- In `base/stores.S`'s `*_RS2` macro family (sweeps the value register
  while using a fixed base address), the fixed base was originally
  `s0` — but `s0` is also one of the swept `rs2reg` candidates. Same
  fault, same fix shape: moved the fixed base to `s1` (not in the
  sweep list).

Both were caught the same way: an actual QEMU run hit an unexpected
trap, not a code review. If you write a similar sweep-plus-fixed-helper
macro, double check the helper register never collides with anything
in the corresponding call sites' register list — this class of bug has
now shown up three times across this project (the third instance, with
`a0`/`a1`/`a2` colliding with swept registers, is documented in the
RVC suite's own history in earlier revisions of this file).

## The M suite

All 13 RV64M instructions (the RV32 image: the 8 that exist in RV32M),
split across two files:
- **`m/mul.S`**: `MUL`, `MULH`, `MULHSU`, `MULHU`, `MULW`
- **`m/div.S`**: `DIV`, `DIVU`, `REM`, `REMU`, `DIVW`, `DIVUW`, `REMW`, `REMUW`

They all use the same R-type encoding as `base/op_alu.S` (`funct7=0000001`),
so the same idea applies: `rd`/`rs1`/`rs2` and every aliasing combination
are swept once, through `MUL`, and each instruction gets its own
arithmetic coverage:

- **The same operand pairs for each signedness variant.** `MUL`/`MULH`/
  `MULHSU`/`MULHU` all see the same pairs, so together they give the full
  128-bit product under each signed/unsigned interpretation. `-1 * -1`
  has a high half of `0` (signed), `0xff..fe` (unsigned) or `0xff..ff`
  (signed×unsigned). `DIV`/`DIVU`/`REM`/`REMU` share pairs in the same
  way. A decoder that swaps two of them fails visibly.
- **`MULHSU` is asymmetric** (`rs1` signed, `rs2` unsigned), so both
  orders of `(-1, 1)` are tested.
- **Division never traps.** Divide-by-zero (quotient all ones,
  remainder = dividend) and signed overflow (`INT_MIN / -1` → quotient
  `INT_MIN`, remainder `0`) are checked for every variant. A trap would
  be reported by `common.S`'s handler, and then the run hangs.
- **Truncation toward zero, remainder takes the dividend's sign**:
  all four sign combinations of `±20 / ±6`.
- **`W` forms** use only the low 32 bits of each operand and
  sign-extend the 32-bit result, *including* `DIVUW`/`REMUW`. Tests
  include garbage in the upper bits and dividends that are sign- and
  zero-extended. One divisor, `0xffffffff00000000`, is nonzero as a
  64-bit value but is a divide-by-zero for the `W` forms.
- **Aliasing hazards for multi-cycle units**: `rd==rs1`/`rd==rs2` for
  `MULH`/`MULHU`/`DIV`/`REM`. `rd=x0` on a divide-by-zero must not trap.
- **The spec's recommended fused sequences** (`MULH`+`MUL`, `DIV`+`REM`,
  `DIVU`+`REMU` on the same sources) are tested as pairs, along with
  the identity `q*d + r == dividend`.

## Bit independence across fields

The per-field sweeps in every suite vary one field of an encoding while
holding the others fixed. That catches a fault confined to one field,
but not a decoder fault where a bit misbehaves only when some *other*
bit is set too — a bit of `rs1` leaking into the logic that selects
`rd`, an immediate bit coupled to a funct bit. `C.ADDI4SPN` was the
first instruction to get the defence (see the RVC suite above); every
other instruction with variable fields now has it as well, generated by
the macros in `bitx.inc`:

- **For every pair of bits among all of an instruction's variable
  fields** — both in one field, or one each in two fields — there is a
  case with exactly those two bits set in those fields, and every other
  field at a fixed background. That's C(N,2) cases for N variable bits:
  105 per R-type (`rd`/`rs1`/`rs2`), 231 per I-type, load, store, JALR or
  branch, 300 for LUI/AUIPC/JAL, 55 for most RVC formats.
- **Every instruction separately**, not once per format, since a
  coupling can just as well involve that instruction's own
  opcode/funct bits.
- **Register bits are set through the register number**: the one-bit
  candidates are x1, x2, x4, x8, x16 and the two-bit ones x3, x5, x6, x9,
  x10, x12, x17, x18, x20, x24 — including `sp`, `gp` and `tp`, which each
  case saves first and restores before touching memory or the harness.
  Compressed 3-bit fields use x9/x10/x12 and x11/x13/x14 over a
  background of x8.
- **Expected values never come from an encoding carrying the bits under
  test.** Without an immediate, the reference is the same instruction
  through the `t2`/`t3`/`t4` encoding the per-instruction `T_*_VAL` tests
  already pin down against literals. With one, it's an assemble-time
  constant or the register-register twin (e.g. `ADDI` checked against
  `ADD`) with the immediate fetched from a constant pool. `rd` is
  poisoned with a sentinel first; stores read back the whole doubleword
  around the target, so writes that are too wide or misplaced are
  caught.
- **Control transfers** (JAL with its full ±1 MiB reach, JALR, the six
  branches, `C.J`, `C.BEQZ`, `C.BNEZ`, `C.JR`, `C.JALR`) land in a
  counting sled that `bitx.S` builds at run time in ~1 MiB of `.bss`:
  a run of `c.addi s5, 1` slots ending in a return. Each case's
  instruction is assembled into `.rodata`, copied onto a site in or next
  to the sled, and executed after `FENCE.I`; the number of slots counted
  identifies the landing address exactly. This avoids megabytes of
  filler. Forward offsets are planted inside the sled, so every correct
  landing counts only a few slots.
- **Skipped, by necessity:** an offset of exactly +2 from a 4-byte JAL or
  branch (it lands in the instruction's own upper half) — 5 cases for
  JAL, 10 per branch — and `C.LUI` with `rd = x2` (that encoding is
  `C.ADDI16SP`, tested separately). `C.NOP` and `C.EBREAK` have no
  variable fields. A branch offset of +4 (and `C.J`/`C.BEQZ`/`C.BNEZ` +2)
  is included, but taken and not-taken are indistinguishable there by
  definition.

Each case is named after its instruction and field values, e.g. `ADD
bitx rd=x3 rs1=x28 rs2=x29`, and the name string sits next to its case,
so there is no separate string table to keep in sync. Each category
file calls its `bitx_*` subroutine at the end of its entry point.

## Building

```sh
make            # builds both images:
                #   build/rv64/rvc_test.{elf,bin}   RV64IMAC
                #   build/rv32/rvc_test.{elf,bin}   RV32IMAC
```

or manually (one width shown; the other uses `rv32imac_zicsr_zifencei`,
`ilp32`, `XLEN=32` and `elf32lriscv`):

```sh
SRCS="common.S main_tests.S \
      rvc/tests.S rvc/quadrant0.S rvc/quadrant1.S rvc/quadrant2.S \
      base/tests.S base/loads.S base/stores.S base/lui.S base/auipc.S base/jal.S \
      base/jalr.S base/branches.S base/op_alu.S base/op_imm.S base/op_imm32.S \
      base/op_alu32.S m/tests.S m/mul.S m/div.S bitx.S"
for f in $SRCS; do
  mkdir -p build/rv64/$(dirname $f)
  riscv64-linux-gnu-as -march=rv64imac_zicsr_zifencei -mabi=lp64 --defsym XLEN=64 \
      --fatal-warnings -I src -o build/rv64/${f%.S}.o src/$f
done
riscv64-linux-gnu-ld -m elf64lriscv -Ttext=0x80000000 --no-dynamic-linker -nostdlib \
    -o rvc_test.elf $(for f in $SRCS; do echo build/rv64/${f%.S}.o; done)
riscv64-linux-gnu-objcopy -O binary rvc_test.elf rvc_test.bin
```

Run it from the repo root. The source paths are relative to `src/`. The
files in `src/rvc/`, `src/base/` and `src/m/` `.include` `xlen.inc` and
`bitx.inc` from `src/` (`-I src`). Each object keeps its source's
subdirectory under `build/rv64/`, because the three suites' `tests.S` files
share a basename.

`common.o` must be listed first at link time — it contains `_start`,
and needs to land at the very base of `.text` so the entry point ends
up at the `0x80000000` load address. The rest can be in any order
relative to each other.

`rvc_test.bin` is the flat binary — load it into RAM at `0x80000000`
and reset the hart with `pc = 0x80000000`, `mode = M`.

## Running under QEMU (for a quick check)

```sh
make run        # RV64 then RV32; or make run64 / make run32
# or:
qemu-system-riscv64 -M virt -bios none -kernel build/rv64/rvc_test.elf \
    -nographic -serial mon:stdio
qemu-system-riscv32 -M virt -bios none -kernel build/rv32/rvc_test.elf \
    -nographic -serial mon:stdio
```
(`Ctrl-A X` to exit QEMU; the firmware parks in `WFI` after the summary
and never exits on its own.) `-kernel` with an ELF works fine here since
QEMU just loads the ELF's segments and jumps to its entry point, which
is the same `0x80000000` load address as the flat `.bin`.

## Adding another test suite

`common.S` doesn't know or care what it's testing — it just calls
`run_tests` (in `main_tests.S`) and reads `pass_count`/`fail_count`
afterward. `main_tests.S` in turn just calls each suite's own entry
point. To add a new suite (say, the `A` extension):

1. Create a directory for the suite (e.g. `a/`) and write its
   top-level file, `a/tests.S`, with `.global run_a_tests`, printing its
   own banner and calling into one or more category files in the same
   directory (e.g. `a/lrsc.S`, `a/amo.S`, with no `a_` prefix: the
   directory already says which suite a file belongs to). This is the same
   way `rvc/tests.S` calls into `rvc/quadrant0/1/2.S`, `base/tests.S`
   into `base/*.S`, and `m/tests.S` into `m/mul.S`/`m/div.S`.
   Use `check`/`uart_puts` from `common.S` the same way the existing
   suites do. Split it into multiple files if it's large enough to
   benefit — each category file should expose exactly one entry symbol
   and keep its macros/subroutines local.
2. Add one line to `main_tests.S`: `call run_a_tests`.
3. Add your new file(s) to `SUITE_SRCS` in the `Makefile`.
4. Give every new instruction bit-independence coverage: `.include
   "bitx.inc"`, write a `BX_C_*` case macro and call the matching
   `BX_E_*` enumerator from a `bitx_*` subroutine at the end of the
   entry point (see "Bit independence across fields").
5. Make it build and pass for both widths: `.include "xlen.inc"` first,
   load every test constant with `LIX` (never plain `li`), use
   `REG_S`/`REG_L` for register-sized memory, and guard anything that
   exists on only one width with `.if XLEN == 64` (see "RV64 and RV32").

Everything else — boot, UART init, trap handling, pass/fail reporting,
the final summary line — is reused as-is.

## A note on branch/jump boundary tests and assembler relaxation

`C.J`/`C.BEQZ`/`C.BNEZ`'s near-maximum offset test cases are built by
padding the distance between the branch/jump and its target with
filler instructions (`.rept`-generated `c.nop`s, sized to hit a
specific byte count) rather than passing a numeric immediate directly.
This turned out to have a real sharp edge: at the *exact* boundary of
the compressible offset range, GNU `as`'s branch relaxation can
converge to the wrong fixed point in some contexts (confirmed via an
isolated minimal reproduction that assembled correctly, while the same
instruction sequence embedded deeper in a larger function silently
widened to a 4-byte `beq`/`bne` instead of the intended 2-byte
`c.beqz`/`c.bnez` — caught only by disassembling and counting
occurrences, not by anything the assembler warned about). The fix used
throughout is a one-`c.nop` safety margin off the true boundary
(`+252` instead of the theoretical max `+254` for `C.BEQZ`/`C.BNEZ`,
`+2044` instead of `+2046` for `C.J`), with every single offset in
these tests double-checked by disassembling and computing
`target − branch` in Python, not trusted from the `.rept` count alone.
If you add more boundary-offset tests, verify them the same way.

## Porting to other hardware/simulators

Two assumptions are baked into `common.S` and worth checking against
your target:

1. **UART reference clock.** `UART_CLK_HZ` (default `1843200`, the
   classic PC/16550 clock) determines the baud-rate divisor. If your
   UART is driven by a different input clock (many SoCs feed it from
   the peripheral bus clock instead), change that one `.equ` and the
   divisor, `UART_DIV_LO`/`UART_DIV_HI` all update automatically at
   assemble time. If the resulting effective baud rate is visibly
   wrong on a real terminal, this is almost always the reason.
2. **UART register stride is 1 byte.** Some ns16550a integrations use
   a 4-byte stride (word-addressed registers). If yours does, change
   the register offset macros (`UART_IER`, `UART_LCR`, etc.) to be
   multiplied by 4, or add a stride constant.
3. **`gp` (global pointer) is initialized at startup** via
   `la gp, __global_pointer$` before anything else runs. This is
   required because the linker's default relaxation turns nearby
   `la reg, symbol` sequences into a single gp-relative `addi`, and
   `gp` is *not* set by hardware at reset — skipping this step is a
   classic bare-metal bug (it was actually caught during testing here:
   without it, the very first data access faults with a store/AMO
   access fault, mcause 7).

Additionally, for the base-ISA load suite specifically:

4. **Misaligned loads/stores are assumed not to trap.** `base/loads.S`
   and `base/stores.S` test offsets like `+4`/`-4` against 8-byte
   `LD`/`SD` accesses, which QEMU handles transparently but real
   hardware may legitimately fault on (the RISC-V base ISA permits,
   but does not require, misaligned-access support). There's no
   misaligned-access-fault handler here, so on hardware that traps,
   these specific cases would hang rather than fail cleanly.

And for the bit-independence tests (see "Bit independence across
fields"):

5. **RAM beyond the image.** The flat binary is ~1.6 MB (RV64) or
   ~1.35 MB (RV32), and the run-time counting sled adds ~1 MiB of
   `.bss` after it — about 2.5 MiB from `0x80000000` in all.
6. **Executing freshly written code.** The control-transfer cases copy
   an instruction into RAM and run it after `FENCE.I` (hence Zifencei in
   `-march`). The target must allow instruction fetch from RAM that was
   just written, with `FENCE.I` as the only synchronisation. The
   bit-independence loads and stores, unlike the per-field ones above,
   are always naturally aligned.

## Files

All assembly sources and include files live under `src/`. The
documentation, the `Makefile` and the container scripts stay in the repo
root. Inside `src/`, the shared harness and include files sit at the top
level. Each suite has its own subdirectory holding its orchestrator
(`tests.S`) and its category files: `src/rvc/`, `src/base/`, `src/m/`.
Source paths elsewhere in this document are relative to `src/`.

- `common.S` — reusable boot/UART/reporter harness (suite-agnostic).
- `main_tests.S` — top-level dispatcher (defines `run_tests`).
- `rvc/tests.S` — RVC suite orchestrator (defines `run_rvc_tests`).
- `rvc/quadrant0.S` / `rvc/quadrant1.S` / `rvc/quadrant2.S` — the RVC
  per-instruction test bodies, one file per RVC opcode quadrant.
- `base/tests.S` — base-ISA suite orchestrator (defines `run_base_tests`).
- `base/loads.S` — the base-ISA load instruction test bodies.
- `base/stores.S` — the base-ISA store instruction test bodies.
- `base/lui.S` — the `LUI` test body.
- `base/auipc.S` — the `AUIPC` test body.
- `base/jal.S` — the `JAL` test body.
- `base/jalr.S` — the `JALR` test body.
- `base/branches.S` — the conditional-branch test bodies.
- `base/op_alu.S` — the R-type ALU test bodies.
- `base/op_imm.S` — the OP-IMM (I-type ALU) test bodies.
- `base/op_imm32.S` — the OP-IMM-32 (RV64 word-width I-type ALU) test
  bodies.
- `base/op_alu32.S` — the OP-32 (RV64 word-width R-type ALU) test
  bodies.
- `m/tests.S` — M suite orchestrator (defines `run_m_tests`).
- `m/mul.S` — the multiply test bodies.
- `m/div.S` — the divide/remainder test bodies.
- `bitx.inc` — macros shared by every file's bit-independence tests
  (included, not linked).
- `bitx.S` — the run-time counting sled for the control-transfer
  bit-independence tests.
- `xlen.inc` — the RV64/RV32 switch (`REG_S`/`REG_L`, `LIX`/`LIXT`,
  `LWUX`, `INTX_MIN`/`INTX_MAX`, ...), included first by every file.
- `Makefile` — build/run/disasm/clean targets, for both widths.
- `build/rv64/rvc_test.bin`, `build/rv32/rvc_test.bin` — the flat
  binaries, ready to load at `0x80000000`.
- `build/rv64/rvc_test.elf`, `build/rv32/rvc_test.elf` — the linked ELFs
  (handy for `objdump -d` / debugging with gdb; not themselves loadable
  as the flat images).
