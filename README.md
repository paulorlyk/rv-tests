# RV64 instruction-set exerciser

A bare-metal, M-mode RISC-V test firmware that exercises RV64 and RV32
instructions and reports OK/FAIL for each case over an ns16550a
serial port. The same sources build two images, one for RV64IMAC and one
for RV32IMAC (see "RV64 and RV32" below). Nine instruction-set suites
are included so far — the C (compressed) extension, the I base ISA,
the M (integer multiply/divide) extension, the A extension's atomic
memory operations, the Zicsr CSR instructions, the Zifencei
instruction-fetch fence, the Zicboz cache-block zero, the Zabha byte
and halfword atomic memory operations and the privileged
architecture's `MRET`/`WFI` and M/U-mode separation — sharing one common
boot/UART/reporting harness and one running pass/fail total.

## Architecture

All sources are under `src/` (see "Files"); paths below are relative
to it.

- **`common.S`** — the reusable harness. Knows nothing about what's
  being tested. Provides: the reset vector / M-mode entry at
  `0x80000000`, `gp` setup, zeroing of all of `.bss` (it isn't in the
  flat `.bin`, so nothing may rely on the loader or on RAM contents at
  power-on), `sp`/`mtvec` setup (and a PMP entry that lets
  U-mode reach all memory), a probe of `FENCE.I` at reset, a minimal
  trap handler on a private stack (expects only `C.EBREAK` and reports
  and hangs on anything else, unless a test has armed it — see "Traps
  on purpose" below), the
  ns16550a UART driver (115200 8N1 init, `putc`/`puts`, hex/decimal
  printing), `test_begin`, which opens a test's instruction group
  before the test runs, the `check` pass/fail comparator (prints
  failures and a per-instruction `OK`/`FAIL`, tracks running
  `pass_count`/`fail_count` totals, and records the first 8
  failures; see "Output: one status per instruction" below), `check_trap`, which reports a check whose
  instruction trapped as a `FAIL` (see "Unimplemented instructions
  fail, they don't hang" below), and the final summary/halt, which lists those
  failures. It calls a single symbol, `run_tests`, and otherwise
  doesn't know or care how many suites exist or what they test.
- **`main_tests.S`** — the top-level dispatcher. Defines `run_tests`
  and just calls each suite's own entry point in turn
  (`run_c_tests`, `run_i_tests`, `run_m_tests`, `run_a_tests`,
  `run_zicsr_tests`, `run_zifencei_tests`, `run_zicboz_tests`,
  `run_zabha_tests`, `run_priv_tests`). This is the
  file you touch to
  add a new suite (see "Adding another test suite" below).
- **`c/tests.S`** + **`c/quadrant0/1/2.S`** — the RV64C suite. See
  "The RVC suite" below.
- **`i/tests.S`** + **`i/loads.S`** — the RV64I base-ISA suite.
  See "The base-ISA suite" below.
- **`m/tests.S`** + **`m/mul.S`**/**`m/div.S`** — the RV64M suite. See
  "The M suite" below.
- **`a/tests.S`** + **`a/amo.S`**/**`a/lrsc.S`** — the RV64A suite. See "The A
  suite" below.
- **`zicsr/tests.S`** + **`zicsr/reg.S`**/**`zicsr/imm.S`** — the Zicsr
  suite. See "The Zicsr suite" below.
- **`zifencei/tests.S`** + **`zifencei/fencei.S`** — the Zifencei
  suite. See "The Zifencei suite" below.
- **`zicboz/tests.S`** + **`zicboz/cbozero.S`** — the Zicboz suite. See
  "The Zicboz suite" below.
- **`zabha/tests.S`** + **`zabha/amo.S`** — the Zabha suite. See "The
  Zabha suite" below.
- **`priv/tests.S`** + **`priv/mret.S`**/**`priv/wfi.S`**/
  **`priv/csrpriv.S`**/**`priv/irqpriv.S`**/**`priv/mstatus.S`** — the
  privileged suite. See "The privileged suite" below.
- **`xlen.inc`** — the RV64/RV32 switch every file includes first; see
  "RV64 and RV32" below.
- **`harness.inc`** — `TEST_BEGIN`, the test side of the name-first
  reporting (see "Output: one status per instruction" below),
  `TRAP_ARM`/`TRAP_DISARM`/`TRAP_DISARM_R`/`TRAP_LD`, the test side of
  the armed trap mode (see "Traps on purpose" below),
  `TRAP_REPORT`/`TRAP_FAILS`, which turn a trap into `FAIL`s, and
  `SYNC_I`, a `FENCE.I` that is skipped on a hart without one.
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

Current totals, all passing on both widths:

| Image | Checks | Per-instruction | Bit-independence | UART output (at 115200 baud) |
|---|---|---|---|---|
| RV64 (`build/rv64/`) | **29375** | 3897 | 25478 | ~16 KB, ~1.4 s |
| RV32 (`build/rv32/`) | **23309** | 3238 | 20071 | ~13 KB, ~1.1 s |

(`AMOMIN`/`AMOMAX`/`AMOMINU`/`AMOMAXU` add 2348 checks on RV64, 2176 of
them bitx, and 1168 on RV32, 1088 of them bitx. `LR`/`SC` add 927 checks
on RV64, 808 of them bitx, and 494 on RV32, 404 of them bitx. `FENCE`
adds 491 on each width, 462 of them bitx, and `FENCE.I` 473, 462 of
them bitx. The six Zicsr instructions add
695 on each width, 540 of them bitx. `CBO.ZERO` adds 102 on each width,
20 of them bitx, plus 10 for `menvcfg`/`senvcfg.CBZE`. The 18 Zabha
AMOs add 5377 on each width, 4896 of them bitx. `ECALL`/`EBREAK` add 44
on each width, `MRET` 20 and `WFI` 18, none of them bitx: those four
have no variable field. The M/U separation files add 589
(`priv/csrpriv.S`), 24 (`priv/irqpriv.S`) and 16 on RV64 / 13 on RV32
(`priv/mstatus.S`), none of them bitx. The not-taken bitx series of the
six branches and of `C.BEQZ`/`C.BNEZ` add 1436 on each width.)

Under QEMU each run takes about a second.

If any check failed, the summary also lists the first 8 failures, in
the order they ran, with the values `check` compared, then how many more
there were:

```
--- Summary: pass_count = 19041, fail_count = 2 ---
Failed tests:
  WFI in U-mode with TW=1: mcause == 2 (illegal instruction) - expected 0x0000000000000002, got 0x0000000000000008
  WFI in U-mode with TW=1: mepc == the WFI itself - expected 0x00000000801d7de4, got 0x00000000801d7de8
ONE OR MORE TESTS FAILED
```

A check whose instruction trapped (see "Unimplemented instructions
fail, they don't hang") is listed with the trap instead:
`  AMOADD.W rd=ra(x1) (AMO format) - trapped, mcause=0x0000000000000002, mepc=0x000000008016ed00`.

`check` and `check_trap` record each failure (the name pointer, the two
values and whether it was a trap) in
`fail_log` in `common.S` while there's room; `FAIL_LOG_MAX` (8) sets the
size. More failures are still counted, and the list ends with
`  ... and N more`. The values are printed at register width, 16 hex
digits on RV64 and 8 on RV32. The list header says `Failed`, not
`FAIL`, so a passing run's output has no `FAIL` in it at all; a failing
one has a line per failed check, a ` FAIL` per failed instruction
group, and the final verdict line.

When the summary has been printed, the hart parks in a `WFI` loop.

## Output: one status per instruction

The UART reports results per instruction, not per check. The
instruction is the first word of a test's name (a trailing `:` or `,`
dropped), so every test name starts with the mnemonic it tests
(`ADD rd=ra(x1) (OP format)`, `SC.W in an LR.W/SC.W pair: ...`); the
interrupt tests of `priv/irqpriv.S`, which test no one instruction, are
grouped as `IRQ`. When a test's instruction differs from the one before
it, `common.S` ends the open group with ` OK` (every check passed) or
` FAIL`, then prints `<INSN>:` for the new one. A passing check prints
nothing; a failing one prints its full line inside its group:

```
ECALL:
 OK
WFI:
WFI in U-mode with TW=1: mcause == 2 (illegal instruction) - FAIL
WFI in U-mode with TW=1: mepc == the WFI itself - FAIL
 FAIL
```

Groups follow run order, so an instruction whose tests are spread over
several places (the branch sections, `CSRRS` in `zicsr/` and `priv/`,
`ECALL` in `i/` and `priv/`) gets a group for each run of them. Suite
banners and the summary close the open group first (`insn_close`); the
summary itself is unchanged.

Every test still announces itself before any of its code runs:
`TEST_BEGIN str_x` (`harness.inc`) calls `test_begin` in `common.S`,
which opens the name's group at once and remembers the name. A test
that hangs therefore leaves its instruction's group as the last line,
and one that traps has its name printed by the trap report:

```
ADD rd==rs1==rs2 (OP format, doubles) - 
!!! UNEXPECTED TRAP, mcause=0x0000000000000002
```

`TEST_BEGIN` is fully register-transparent (it saves `ra`/`a0` on the
stack, and `test_begin` preserves everything else), so it sits at the
top of each `T_*` macro and before each inline test's setup, above any
PC-reference label and before `sp`/`gp` are touched. A test with
several checks announces each one just before the code that computes
it. The bitx cases are announced by `BX_ENTER` itself, using the name
string their first `BX_REPORT` defines, so the case macros don't
change. A `check` whose name was never announced opens its group
itself, so a missing `TEST_BEGIN` costs only the early announcement,
never a result.

## Traps on purpose

Unarmed, `common.S`'s trap handler accepts only a breakpoint (the
`C.EBREAK` tests; it steps over a 2-byte instruction) and treats
anything else as `UNEXPECTED TRAP`. Tests that trap deliberately in any
other way — `ECALL`, the 4-byte `EBREAK`, an instruction that is
illegal in U-mode, an interrupt taken out of `WFI` — arm it first:
`TRAP_ARM label` (`harness.inc`) stores a resume address in
`trap_resume`. The next trap, of any cause and from any privilege mode,
then records `mcause`, `mepc`, `mtval` and `mstatus` as they were on
entry (`trap_mcause`/`trap_mepc`/`trap_mtval`/`trap_mstatus`, read back
with `TRAP_LD`), bumps `trap_count`, disarms itself, and returns with
`MRET` to `label` in M-mode (it sets `MPP` to M; for an interrupt it
also clears `mie` so the source can't fire again at once). The test
then checks the recorded cause itself, so a missing, wrong or extra
trap is a `FAIL` rather than a hang. `TRAP_DISARM` clears an arming
whose trap never came (`TRAP_DISARM_R reg` does the same without the
stack, for where `sp` may still be swept).

The handler runs on its own stack (`trap_stack` in `common.S`): on
entry it parks `t0` in `mscratch`, saves the interrupted `sp` at the
top of `trap_stack` and switches to it, and puts `sp` back on the way
out. A bitx case may be sweeping `sp` as an operand (holding a pool
value, or the address of the buffer under test) when its instruction
traps, and a handler that pushed onto that `sp` would fault inside
itself and loop forever. The cost is that every trap overwrites
`mscratch`; no test keeps a value there across a trap (the Zicsr tests
write it and read it back with nothing in between). The whole handler
is `norelax`, since `gp` may be swept too.

### Unimplemented instructions fail, they don't hang

The instructions of the A, Zicboz, Zabha and Zifencei suites may simply be
missing on a target, which raises an illegal-instruction trap (mcause
2); a misdecoded address can also raise an access fault. So every
instruction under test there runs armed. `TRAP_ARM` goes before it (or
before the first of a group, e.g. an `LR`/`SC` pair: the arming is
consumed only by a trap, so one covers the whole group, and no stack
store lands between an `LR` and its `SC`), and a disarm after it.
After the test's own checks, `TRAP_FAILS resume, name...` jumps over a
resume path at `resume` that calls `check_trap` once for every check
the test makes:

```
AMOADD.W rd=ra(x1) (AMO format) - FAIL (trap, mcause=0x0000000000000002, mepc=0x000000008016ed00)
```

So a trapping instruction costs one `FAIL` per check, and the number of
checks counted is the same as in a passing run. A test that sweeps
`sp`/`gp`/`tp` puts them back at its resume label before reporting
(`BX_TRAP_FAILS` in `bitx.inc` does it for the bitx cases, which name
their strings up front with `BX_NAME`/`BX_REPORT_AT` so the resume path
can report all of them). The unarmed handler is unchanged: a trap
nobody armed for is still `UNEXPECTED TRAP`.

`FENCE.I` is also test machinery: the bitx sled for the control-transfer
instructions (`bitx.S`, `BX_PLANT`/`BX_GO`) synchronises instruction
fetch with it. Reset runs one `FENCE.I` armed and sets `has_fencei`
from the outcome; the machinery uses `SYNC_I`, which skips the
`FENCE.I` when `has_fencei` is 0, and reset prints
`FENCE.I not implemented (it traps): instruction-fetch sync skipped`.
The Zifencei suite's own `FENCE.I`s are all armed, so there they fail.

Checked under QEMU by switching each extension off; each run reaches its
summary with unchanged totals, and the failures are exactly these
(RV64 / RV32). QEMU leaves Zabha off unless asked, so every row is
run with `zabha=true` added except where it says otherwise:

| `-cpu rv64,...` / `rv32,...` | `FAIL`s | where |
|---|---|---|
| `a=false,zawrs=false` | 6180 / 3138 | every A check, the two `CBO.ZERO`+`AMOADD.W` checks of the Zicboz suite, and the Zicsr `misa` check (QEMU keeps Zabha working, so the Zabha suite still passes) |
| `zicboz=false` | 106 / 106 | the Zicboz suite, except the six `CBZE` checks that expect `CBO.ZERO` to trap in U-mode (it still does) |
| `zabha=false` (the default) | 5377 / 5377 | the Zabha suite |
| `zifencei=false` | 473 / 473 | the Zifencei suite (the C/I control-transfer bitx cases still pass: QEMU keeps instruction fetch coherent without `FENCE.I`) |
| all of the above | 12134 / 9092 | the sum, counting the two `CBO.ZERO`+`AMOADD.W` checks once |

For U-mode tests, `common.S`'s reset also programs PMP entry 0 as a
NAPOT region over the whole address space with R/W/X, unlocked, so
U-mode code can run in place (M-mode is unaffected). A hart without PMP
needs no entry — U-mode then has full access — but may trap on the PMP
CSRs instead of ignoring the writes (older cores; QEMU with
`-cpu rv64,pmp=false`), so the two writes run with `mtvec` briefly
pointing at `pmp_skip`, which steps over a write that traps. Both
images pass unchanged with `pmp=false`.

## RV64 and RV32

`make` builds both images from the same sources: `build/rv64/rv_tests.{elf,bin}`
(`-march=rv64imac_zicsr_zifencei_zicboz_zabha -mabi=lp64`) and `build/rv32/rv_tests.{elf,bin}`
(`-march=rv32imac_zicsr_zifencei_zicboz_zabha -mabi=ilp32`). Each file gets
`--defsym XLEN=64` or `XLEN=32`, and everything width-dependent goes
through `xlen.inc` or an explicit `.if XLEN == 64` block:

- **Only on RV64** (guarded out of the RV32 image): `LD`, `SD`, `LWU`;
  `ADDIW`, `SLLIW`, `SRLIW`, `SRAIW`; `ADDW`, `SUBW`, `SLLW`, `SRLW`, `SRAW`;
  `MULW`, `DIVW`, `DIVUW`, `REMW`, `REMUW`; the nine `AMO*.D`;
  `C.LD`, `C.SD`, `C.LDSP`,
  `C.SDSP` (on RV32C those encodings are the floating-point
  `C.FLW`/`C.FSW`/`C.FLWSP`/`C.FSWSP`, out of scope as before),
  `C.ADDIW`, `C.SUBW`, `C.ADDW`; and the few tests that are about bits
  above 31 themselves (e.g. "SW discards the upper 32 bits of rs2",
  "SLTIU's immediate sign-extends to 64, not 32", "AMOADD.W ignores
  rs2[63:32]").
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
| `c/tests.S` | orchestrator; defines `run_c_tests`, prints the banner, calls each quadrant in turn |
| `c/quadrant0.S` | `C.ADDI4SPN`, `C.LW`, `C.LD`, `C.SW`, `C.SD` |
| `c/quadrant1.S` | `C.NOP`, `C.ADDI`, `C.ADDIW`, `C.LI`, `C.ADDI16SP`, `C.LUI`, `C.SRLI`, `C.SRAI`, `C.ANDI`, `C.SUB`, `C.XOR`, `C.OR`, `C.AND`, `C.SUBW`, `C.ADDW`, `C.J`, `C.BEQZ`, `C.BNEZ` |
| `c/quadrant2.S` | `C.SLLI`, `C.LWSP`, `C.LDSP`, `C.JR`, `C.MV`, `C.EBREAK`, `C.JALR`, `C.ADD`, `C.SWSP`, `C.SDSP` |

The quadrant grouping matches the RVC spec's own opcode layout (bits
`[1:0]` of the 16-bit instruction select the quadrant). Each quadrant
file exposes exactly one symbol, `tests_c_quadrantN`, to the outside —
its macros and per-instruction `test_c_*` subroutines stay local. All
three only depend on `check`/`uart_puts` from `common.S` (plus
`word_buf`, defined in `c/quadrant0.S` and used by one test in
`c/quadrant1.S` — the one cross-quadrant reference in the suite).

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
  see `test_c_addi4spn`'s header comment in `c/quadrant0.S` for the
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
- **`i/loads.S`**: `LB`, `LH`, `LW`, `LD`, `LBU`, `LHU`, `LWU`
- **`i/stores.S`**: `SB`, `SH`, `SW`, `SD`
- **`i/lui.S`**: `LUI`
- **`i/auipc.S`**: `AUIPC`
- **`i/jal.S`**: `JAL`
- **`i/jalr.S`**: `JALR`
- **`i/branches.S`**: `BEQ`, `BNE`, `BLT`, `BGE`, `BLTU`, `BGEU`
- **`i/op_alu.S`**: `ADD`, `SUB`, `SLL`, `SLT`, `SLTU`, `XOR`, `SRL`, `SRA`, `OR`, `AND`
- **`i/op_imm.S`**: `ADDI`, `SLTI`, `SLTIU`, `XORI`, `ORI`, `ANDI`, `SLLI`, `SRLI`, `SRAI`
- **`i/op_imm32.S`**: `ADDIW`, `SLLIW`, `SRLIW`, `SRAIW` (RV64 only)
- **`i/op_alu32.S`**: `ADDW`, `SUBW`, `SLLW`, `SRLW`, `SRAW` (RV64 only)
- **`i/system.S`**: `ECALL`, `EBREAK`
- **`i/fence.S`**: `FENCE` (with `FENCE.TSO` and `PAUSE`)

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
- **Every access is naturally aligned**, including the offset tests
  (`+2047`, `-4` for `LD`, ...): they move the base register instead
  (base = anchor − (offset mod width)), so the odd offsets are still
  encoded but the address is aligned, and a hart without
  misaligned-access support runs the suites unchanged. The offset tests
  also write (loads) or read back (stores) the target through an
  absolute address rather than through the same offset, so a misdecoded
  offset bit can't move both accesses together and pass.
- **No test can pass on what the previous one left behind.** Every
  store test first sets its target to a different value with another
  encoding (`rs2 = x0`, or the complement of the value under test), and
  every load test poisons its destination register first. (Before this,
  the `rs1`/`rs2` sweeps stored the same constant to the same address
  one after another, so a store that didn't happen passed on the
  previous test's value; and the `rd = t0` load cases loaded into the
  register that had just held the stored pattern.)
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
  encoding mechanism, just at a scale not worth the binary size (the
  bit-independence cases cover the full ±1 MiB). The filler is never
  inert: forward, every filler instruction is the poison, so a jump
  that lands anywhere short of the target fails; backward, every filler
  slot jumps on to the poison after the `JAL` (entered directly, not
  by running through the filler), so a short landing fails instead of
  running into the same `JAL` again and looping. `i/branches.S` and
  the RVC `C.J`/`C.JAL`/`C.BEQZ`/`C.BNEZ` offset tests are built the
  same way.
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
  immediate instead (an even base plus an odd immediate, summing to
  `label + 1`). And `rd == rs1` is a genuine hazard — the old
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
- **`i/op_alu.S`'s ten R-type ALU instructions share one encoding**
  and differ only in the operation, so — the same idea as the branch
  file — the register fields (`rd`/`rs1`/`rs2` and every aliasing
  combination) are swept *once*, through `ADD`, rather than ten times
  over; the real per-instruction depth goes into each operation's own
  correctness. `SLL`/`SRL`/`SRA` get a specific, easy-to-get-wrong
  check: only the low 6 bits of `rs2` select the shift amount, so
  `rs2=64` must behave identically to `rs2=0`, and `rs2=65` to `rs2=1`
  — tested directly rather than assumed. `SLT`/`SLTU` get the same
  signed/unsigned divergence pairs used for `BLT`/`BLTU`, for the same
  reason. `x0` gets its own cases through the idioms that rely on it:
  `ADD rd=x0` (discarded), `ADD rs2=x0` (`MV`), `SUB rs1=x0` (`NEG`),
  `SLTU rs1=x0` (`SNEZ`) and `SLT rs2=x0` (`SLTZ`), each with a nonzero
  value in the other source so reading `x0` as anything but zero shows
  (the bit-independence register candidates never include `x0`).
  `.option norvc` matters here too — several of these have
  direct compressed equivalents among `x8`-`x15` registers that the
  assembler would otherwise substitute.
- **`i/op_imm.S`'s nine OP-IMM instructions** follow the same
  pattern as `i/op_alu.S`: `rd`/`rs1` (plus `rd==rs1`, `rd=x0` and
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
- **`i/op_imm32.S`'s four OP-IMM-32 instructions** (RV64 only; on
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
- **`i/op_alu32.S`'s five OP-32 instructions** (RV64 only; on RV32
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
- **`i/system.S`** (`ECALL`, `EBREAK`): each has exactly one encoding,
  so there is no operand to sweep, and every trap goes through the
  armed handler (see "Traps on purpose"). For each instruction: it
  traps exactly once and execution comes back where the handler sends
  it; `mcause` is 11 (`ECALL` from M-mode) or 3 (`EBREAK`); `mepc` is the
  instruction itself, not the next one; `mtval` is 0 (`ECALL`), or 0 or
  the instruction's address (`EBREAK`, either is allowed); on entry
  `MPP` = 3, `MIE` = 0 and `MPIE` = the previous `MIE`, run with `MIE`
  both 0 and 1 (with `mie` = 0), and `MIE` is back after the `MRET`;
  `a0`–`a7`, `t2`–`t6` and `s6`–`s11` survive; three in a row each
  trap once; at an address that is 2 mod 4 `mepc` is still exact; and
  from U-mode (entered with `MRET`) `ECALL`'s cause becomes 8 while
  `EBREAK`'s stays 3, with `MPP` = 0 recorded (an `mscratch` read after
  the instruction traps back to M-mode if it doesn't). `.option norvc` also
  keeps `ebreak` from being assembled as `c.ebreak`.
- **`i/fence.S`** (`FENCE`): on one hart with nothing else on the bus
  the ordering itself isn't observable, so what's checked is that
  `FENCE` has no other effect and that a decoder accepts every form.
  For iorw,iorw, rw,rw, r,r, w,w, r,rw, rw,w, w,r, i,i, o,o, i,o, o,i,
  `FENCE.TSO`, `PAUSE` (w,0, a HINT) and 0,0: five patterned
  registers are unchanged and the next instruction runs exactly once.
  The reserved fields are ignored: `rd` = `a3` isn't written, `rs1` =
  `a4` has no effect, `fm` = 1111 and 0001 act as a normal fence, and
  all of them at once (imm = 0xfff). Four back to back, and one at an
  address that is 2 mod 4. Memory: a load after a store across
  `FENCE w,r` sees the store; four byte stores then `FENCE rw,rw` then
  a word load; a load before `FENCE r,w` sees the old value and the
  store after it lands. Device I/O: the UART's line control register
  (LCR) read back across `FENCE o,i`, and the second of two writes
  across `FENCE o,o` wins (the transmitter is drained first, and 8N1 is
  restored before anything more is printed). From U-mode (entered with `MRET`) `FENCE` and
  `FENCE.TSO` don't trap: the `ECALL` after them does, with `mcause` 8
  and `mepc` at the `ECALL`. Every `FENCE` runs armed, so one that traps
  is a `FAIL`, not a hang. Bit independence covers all 22 bits of
  `rd`, `rs1` and `fm`/`pred`/`succ` (background 0), checking `rd` and a
  store read back across the fence.
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

- In `i/loads.S`'s `*_RS1` macro family (sweeps the base register
  while storing a fixed test value first), the scratch value register
  was originally `t0` — but `t0` is also one of the swept `basereg`
  candidates. When `basereg == t0`, loading the test value into `t0`
  destroyed the address just computed there, and the store faulted
  (`mcause 7`, store/AMO access fault). Fixed by moving the scratch to
  `t1` (not in the sweep list).
- In `i/stores.S`'s `*_RS2` macro family (sweeps the value register
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

They all use the same R-type encoding as `i/op_alu.S` (`funct7=0000001`),
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

## The A suite

The atomic memory operations of RV64A: all 18 AMOs (the RV32 image: the
9 `.W` forms), in **`a/amo.S`**: `AMOSWAP`, `AMOADD`, `AMOXOR`,
`AMOAND`, `AMOOR`, `AMOMIN`, `AMOMAX`, `AMOMINU`, `AMOMAXU`, each as
`.W` and `.D`; and `LR`/`SC` (`.W` and `.D`) in **`a/lrsc.S`**, below.

An AMO returns the *old* memory value in `rd` and writes
`op(old, rs2)` back to the address in `rs1`, so every value test checks
two results: `rd` and the memory word/doubleword. They all share one
encoding (`funct5` picks the operation, `funct3` the width, plus the
`aq`/`rl` bits), so `rd`/`rs1`/`rs2` and the aliasing combinations are
swept once, through `AMOADD.W`, and each instruction gets its own
value coverage:

- **Old value vs. new value.** Each instruction's first case (and most
  others) has an old value and a result that differ, so returning the
  new value, or swapping `rd` and memory, fails.
- **`.W` sign-extends the old word into `rd`** (old words with bit 31
  set), and **writes exactly 4 bytes**: after every instruction, at
  both word offsets of a doubleword, the words just below and above
  the target are checked. The `rs2` in those cases is chosen per
  operation so that the same operation done 64 bits wide would change
  the neighbouring word (e.g. `AMOADD.W`'s carry out of bit 31). `.D`
  gets the same neighbour check.
- **The same operand pairs for `MIN`/`MAX`/`MINU`/`MAXU`**, where the
  signed and unsigned readings diverge (`(1, -1)`, `(INT_MIN, INT_MAX)`
  in both orders), so a swapped signed/unsigned or min/max decode fails
  visibly, and the result comes from memory in one order and from
  `rs2` in the other.
- **Width of the compare.** On RV64 the `.W` forms get garbage in
  `rs2[63:32]` (must be ignored), and `0x80000000` loaded with its upper
  half zero must still compare as negative. The `.D` forms get pairs
  like `(2^32, 1)` and `(0xffffffff, 0)` that a 32-bit compare gets wrong.
- **`rd=x0`** still updates memory. **`rs2=x0`**: `AMOSWAP` stores 0,
  and `AMOOR` returns the old value and leaves memory alone (the atomic
  load idiom).
- **Aliasing**: `rd==rs2` (`AMOSWAP` swaps a register with memory),
  `rd==rs1` (the address must be read before `rd` is written),
  `rs1==rs2` (the address is the operand), `rd==rs1==rs2`, and `rs1=sp`.
  Sources are checked unmodified.
- **`aq`/`rl`** must not change the result: every instruction also runs
  as `.aq`, `.rl` and `.aqrl`. The ordering itself can't be observed on
  a single hart and isn't tested.

Every AMO under test runs armed, so a missing or trapping one gives a
`FAIL` per check (see "Unimplemented instructions fail, they don't
hang"). Misaligned AMOs (which must trap) are not tested.

**`a/lrsc.S`** covers `LR.W`/`SC.W` and (RV64) `LR.D`/`SC.D`. `LR` loads
(`.W` sign-extended) and registers a reservation; `SC` stores `rs2` only
while that reservation holds, and returns 0 in `rd` on success, nonzero
on failure. Either way it drops the reservation:

- **Values and width**: `LR`'s `rd` (sign extension for `.W`, none from
  bit 31 for `.D`), `SC`'s `rd` and the stored value at both word
  offsets of a doubleword, and on RV64 an `SC.W` whose `rs2` has garbage
  above bit 31. `LR` leaves the target and its neighbours alone; `SC`
  writes exactly its width.
- **The failure rules the spec requires**: a second `SC` after one `LR`
  fails, an `SC` outside the reservation fails, an `SC` right after a
  failed one fails too, and an `SC` to an earlier `LR`'s address fails
  once a later `LR` has reserved somewhere else (the `SC` to the later
  address succeeds). A failed `SC` stores nothing. Failure is checked as
  `rd != 0`, since the spec only requires "nonzero".
- **`rd=x0`** for `SC` still stores. The standard retry loop (an atomic
  increment, `SC` with `rd==rs2`) runs three times.
- **Register fields** swept through `LR.W`/`SC.W`, and **aliasing**:
  `LR` `rd==rs1` (its reservation must be on the address it read), `SC`
  `rd==rs2`, `rd==rs1`, `rs1==rs2` (stores its own address),
  `rd==rs1==rs2`, `rs1=sp`, and sources unmodified.
- **`aq`/`rl`** on either side of a pair must not change the result.

Two assumptions go beyond what the spec strictly promises. First, an
`LR` followed directly by its `SC` (with only ALU instructions between
them, the spec's "constrained" shape) succeeds on the first try on a
single hart. The spec allows an `SC` to fail spuriously, but none of
these cases gives a single-hart implementation a reason to. Second, the
reservation set is smaller than 4 KiB: the "other address" is 4096
bytes away. Some cases are left out because the spec leaves their
outcome open: mixed-width pairs, a plain store by the same hart between
`LR` and `SC`, and whether a trap drops the reservation. Every `LR`/`SC`
group runs armed, with one arming across the group so nothing is stored
between `LR` and `SC`: a missing or trapping one gives a `FAIL` per
check.

## The Zicsr suite

The six CSR instructions of Zicsr, identical on both widths:
- **`zicsr/reg.S`**: `CSRRW`, `CSRRS`, `CSRRC`
- **`zicsr/imm.S`**: `CSRRWI`, `CSRRSI`, `CSRRCI`

Each reads the old CSR value into `rd` and writes a new one: `rs1` (or
the uimm), `old | rs1`, or `old & ~rs1`. So every value test checks
two results, `rd` and the CSR. The CSR under test is `mscratch`: it is
the one M-mode CSR the spec makes fully read/write at XLEN bits with no
side effects, and nothing else in the firmware uses it.

- **`rd` is the old value, the CSR gets the new one**, with full-width
  patterns, all ones and zero, and the top bit set or cleared alone.
  `CSRRS`/`CSRRC` whose (non-`x0`) `rs1` holds 0 leave the CSR unchanged.
- **Register fields** are swept once, through `CSRRW` (`rd`, `rs1`), plus
  `rd=x0` for each instruction (the write still happens) and `rs1=x0`
  (`CSRRW` writes 0, `CSRRS`/`CSRRC` write nothing). `rd==rs1` for each:
  `rs1` must be read before `rd` is written. `rs1` is left unmodified.
- **The uimm is zero-extended and is not a register.** Every uimm bit is
  walked for each immediate form, plus 0 and 31: `CSRRWI 31` writes
  `0x1f`, and `CSRRSI`/`CSRRCI 31` change only the low five bits of an
  old value whose upper bits would show a sign extension. Each also runs
  with the register numbered uimm holding a value that would give a
  different answer if it were read instead.
- **Back-to-back**: a CSR access in the very next instruction sees the
  write before it (`CSRRW`/`CSRRW`, `CSRRS`/`CSRRC`), and the `rd` of a CSR
  instruction is usable in the next one.
- **The csr field**: `mscratch` (0x340) and `mepc` (0x341) differ only in
  bit 0, and each keeps its own value when the other is written. `misa`
  reports MXL = XLEN and the I, M, A and C extensions.
- **No write means no trap.** `CSRRS`/`CSRRC` with `rs1=x0` and
  `CSRRSI`/`CSRRCI` with uimm 0 read the read-only `mhartid`,
  `mvendorid`, `marchid` and `mimpid` and must agree with each other.
  If one of them attempted a write, the illegal-instruction exception
  would hang the run with `UNEXPECTED TRAP`.

- **A write does trap, in M-mode too.** `CSRRW` (with `rd` and with
  `x0`), `CSRRS`/`CSRRC` with a non-`x0` `rs1` register that holds 0,
  `CSRRWI` (uimm 0: it writes anyway) and `CSRRSI`/`CSRRCI` with a
  nonzero uimm, on `mvendorid`/`marchid`/`mimpid`/`mhartid`, each raise
  an illegal-instruction exception: exactly one trap, mcause 2, `mepc`
  on the instruction, `mtval` 0 or its bits, `rd` unwritten. They run
  armed, so a write that goes through is a `FAIL`, not a hang.

Not tested: an access to an unimplemented CSR address (no address is
guaranteed unimplemented on every hart); and `mepc[0]` reading as 0.
QEMU 10.0 keeps that bit as written and clears it only on `MRET`.

For bit independence the variable fields are `rd` and `rs1`/uimm, 45
cases per instruction, each checking `rd` and `mscratch` against
assemble-time constants. The 12-bit csr field is held at `mscratch`
like an opcode: setting two arbitrary bits of it names a different,
mostly nonexistent CSR, which would trap. Because uimm bits are data
bits, the old value differs per instruction: `CSRRSI`'s has the low
five bits clear and `CSRRCI`'s has them set, so every set or clear is
visible.

## The Zifencei suite

Zifencei is a single instruction, `FENCE.I`, but it is its own extension
rather than part of RV64I/RV32I, so like every extension it has its own
suite directory. Identical on both widths:
- **`zifencei/fencei.S`**: `FENCE.I`

`FENCE.I` can only be tested with self-modifying code: write an
instruction, `FENCE.I`, execute it, and check that the new instruction
ran and not a stale copy. Every rewritten location has run with its old
contents first, so a stale copy exists. The tested routine is `addi t6, zero, K` plus a return,
copied from assembled templates, and the checks cover:
- a buffer in `.bss`, rewritten four times in a row;
- the new instruction written with byte stores, and a compressed
  `c.li`/`c.jr` pair written with halfword stores;
- the instruction immediately after a `FENCE.I` inside the code being
  modified (the buffer stores into its own next-but-one slot, fences,
  and runs into it);
- a routine in `.text` patched in place and patched back;
- no register side effects.

The spec reserves the `rd`, `rs1` and `imm` fields for finer-grained
fences and says implementations must ignore them, so all 22 of those
bits are the variable fields for bit independence (background: the
all-zero standard encoding, generated with `.insn`). Each of the 231
cases must still fence and must leave `rd` unchanged. Under QEMU,
self-modifying code is detected even without a fence, so these tests
only become a real check of the fence on hardware with an instruction
cache. The tests also assume that `.text` and `.bss` are writable and
executable from M-mode. Every `FENCE.I` here runs armed, including the
one in `FI_BUF_INIT` and the one inside the buffer of the "next
instruction" test. Without Zifencei, or if a hart traps on the reserved
fields the spec says it must ignore, each affected check is a `FAIL`
(the in-place `.text` patch is undone on the way out).

## The Zicboz suite

Zicboz is a single instruction, `CBO.ZERO`, and like every extension it
has its own suite directory. Identical on both widths:
- **`zicboz/cbozero.S`**: `CBO.ZERO`

`CBO.ZERO rs1` stores zeros to the whole cache block containing the
address in `rs1`: the address is aligned down to the block size, and
nothing outside the block is written. It has no offset and no `rd`. The
block size can't be read from M-mode, so it is the assemble-time
constant `CBOZ_BLOCK_BYTES` in `zicboz/cbozero.S` (64, QEMU's default;
see "Porting").

Every test fills a four-block, block-aligned buffer with a pattern that
has no zero byte, runs `CBO.ZERO` on the second or third block, and
scans the buffer. The scan reports the first and last byte that changed
and how many bytes in between are not zero, as one value, so a block of
the wrong size or alignment, a zero that starts at the address instead
of the block start, a touched neighbour or a missed byte all fail. The
checks cover:
- the zeroed extent is exactly `CBOZ_BLOCK_BYTES`, and an aligned
  address zeroes exactly its own block;
- unaligned addresses: each address bit below the block size set on
  its own, the last byte of a block, the middle of a block;
- two adjacent blocks back to back, and the same block twice;
- loads of every width read 0 afterwards;
- ordering with the hart's own accesses: a store just before it is
  overwritten, a store just after it lands (the rest of the block stays
  zero), and an `AMOADD.W` just after it reads 0;
- `rs1` = every register `x1`–`x31`, including `sp`/`gp`/`tp` (saved to
  memory around the case): the block is zeroed and `rs1` is unchanged.
  `rs1` = `x0` (address 0) is skipped, since there is no RAM there;
- no other register is written.

For bit independence the only variable field is `rs1`: `rd` must be 0
and the imm field holds funct12 = 4, which selects the operation, so
both are opcode bits (like the csr field in the Zicsr suite). That
gives 10 cases (the two-bit `rs1` registers), each checking the scan
and that `rs1` is unchanged. Every `CBO.ZERO` runs armed, so without
Zicboz each check is a `FAIL` (the `rs1` sweep and the bitx cases put
back `sp`/`gp`/`tp` first). The `CBO.ZERO`-then-`AMOADD.W` case also
needs A.

Below M-mode, `CBO.ZERO` is gated by `menvcfg.CBZE` and, when the hart
has S-mode, `senvcfg.CBZE`. From U-mode (entered with `MRET`, an `ECALL`
after the `CBO.ZERO`): with both set it doesn't trap (the `ECALL` does,
mcause 8) and zeroes its block; with `menvcfg.CBZE` clear it is illegal
(mcause 2, `mepc` on it, memory untouched); with only `senvcfg.CBZE`
clear it is illegal if `misa` has S, and works otherwise. In M-mode it
works with both clear. `menvcfg`/`senvcfg` are put back afterwards.
QEMU 10.0 checks `senvcfg` even on a hart without S-mode
(`-cpu ...,s=false,h=false`), so there the six checks that expect a
working `CBO.ZERO` in U-mode fail. Not tested: `CBO.ZERO` to a
non-writable address.

## The Zabha suite

Zabha adds byte and halfword forms of the nine AMOs: `AMOSWAP`,
`AMOADD`, `AMOXOR`, `AMOAND`, `AMOOR`, `AMOMIN`, `AMOMAX`, `AMOMINU`,
`AMOMAXU`, each as `.B` and `.H`. It is its own extension, so it has its
own suite directory, and all 18 exist on both widths:
- **`zabha/amo.S`**: the 18 AMOs

They work like the A suite's AMOs, only narrower: `rd` gets the old
byte/halfword **sign-extended** (for `AMOMINU`/`AMOMAXU` too), only the
low 8/16 bits of `rs2` take part, and exactly 1 or 2 bytes are
written. So the tests follow `a/amo.S` (register sweeps and aliasing
through `AMOADD.B`, value tables per instruction, `aq`/`rl`), with
these additions:

- **Every lane.** The value cases walk the target through all eight
  byte offsets (`.B`) and all four halfword offsets (`.H`) of a
  doubleword, so a fault in lane selection or in the shift on the load
  or store side fails.
- **Exactly 1 or 2 bytes written.** Every instruction runs at every
  lane, and afterwards all 24 bytes of the buffer except the target
  must still hold their fill. `rs2` is chosen per operation so that the
  same operation done wider would change a neighbour (a carry out of
  bit 7/15 for `AMOADD`, zeros above the lane for `AMOAND`, ...).
- **`rs2` above the lane is ignored**: one case per instruction and
  width has garbage there (on RV32 too). `MIN`/`MAX`/`MINU`/`MAXU` get
  `(1, 0x100)` / `(1, 0x10000)`, where a register-wide compare picks
  the other operand, and `(1, 0xff)` / `(1, 0xffff)` with the upper
  bits clear, which must still compare as -1.
- **Signed vs. unsigned** through the same pairs as the A suite, at 8
  and 16 bits. `.H` also gets `(0x00ff, 0x0100)`, which a compare on
  the low byte alone gets wrong, and `AMOADD.H 0x00ff+1`, whose carry
  must reach the upper byte.
- **Aliasing**: `rd==rs2` (`AMOSWAP.H`, and through `AMOADD.B`),
  `rd==rs1`, `rs1==rs2` (`AMOSWAP.B` stores the address's low byte,
  `AMOADD.H` adds its low halfword), `rd==rs1==rs2` (`AMOSWAP.H`),
  `rs1=sp`, `rd=x0`, `rs2=x0` (`AMOSWAP.B` stores 0, `AMOOR.B` is an
  atomic byte load). Sources are checked unmodified.

The value, `aq`/`rl` and neighbour tables name their cases inline (the
macro builds `"<description>: rd = old value"` / `": memory"` /
`": neighbouring bytes untouched"`), so only the hand-written register
tests have a string table.

Bit independence: 136 cases per instruction (`rd`/`rs1`/`rs2` and
`aq`/`rl`), each checking `rd` and the register-sized slot around the
target, as in the A suite (`BX_C_ZB`). `AMOMIN` and `AMOMAXU` use the
operand pair the other way round from the rest: with the shared pair
they would keep the old value, and a case that ignored `rs2` would still
pass.

Every AMO runs armed. QEMU 10 leaves Zabha off by default (`-cpu
rv64,zabha=true` turns it on; `make run` does), and without it each
check is a `FAIL` with mcause 2. Not tested: misaligned `.H` (it traps,
or with Zama16B may succeed within 16 bytes, so the outcome depends on
the implementation), and `AMOCAS.B`/`AMOCAS.H`, which need Zacas as
well.

## The privileged suite

`MRET` and `WFI` come from the privileged architecture's machine-level
ISA rather than from RV64I or an unprivileged extension, so they have a
suite of their own (the base ISA's own SYSTEM instructions, `ECALL` and
`EBREAK`, are in `i/system.S`). The same suite checks the separation
between M-mode and U-mode. Identical on both widths apart from the
CLINT access and the RV64-only `UXL` checks:
- **`priv/mret.S`**: `MRET`
- **`priv/wfi.S`**: `WFI`
- **`priv/csrpriv.S`**: M-mode CSRs accessed from U-mode
- **`priv/irqpriv.S`**: M-mode interrupts while in U-mode, and in
  M-mode: vectored `mtvec`, priority
- **`priv/mstatus.S`**: `mstatus.MPP`/`UXL` legality, `misa.U`, the
  interrupt-enable stack on a trap from U-mode

`MRET` and `WFI` have a single fixed encoding, so there is nothing for
bit independence to pair. The other three files test no new
instruction (the CSR instructions' bitx cases are in the Zicsr suite).
Traps caused on purpose go through the armed handler (see "Traps on
purpose"), and the U-mode parts rely on the PMP entry `common.S` sets
up. Every U-mode sequence ends in a backstop (an `ECALL`, or an
`mscratch` read), so an instruction that wrongly doesn't trap comes back
through the handler as a `FAIL`.

- **`priv/mret.S`**: every `MRET` is executed directly by test code with
  `mepc` and `mstatus` set up by hand, so each of its effects is checked
  on its own. The jump: it lands on `mepc`, including a compressed
  instruction at an address that is 2 mod 4, and leaves `mepc`
  unchanged. The interrupt-enable stack: `MIE` ← `MPIE` in both
  directions, `MPIE` = 1 afterwards, and `MPP` becomes U if `misa` has
  U, else M. The privilege change: with `MPP` = M an M-mode CSR read
  after it doesn't trap; with `MPP` = U the same read traps as illegal
  (mcause 2, `MPP` = 0 recorded, `mepc` on the read). `MPRV` is cleared
  by an `MRET` to U-mode and kept by one to M-mode. `MRET` in U-mode is
  illegal. That test can't simply point `mepc` at the `MRET`: one that
  wrongly works would jump back to itself forever. Instead U-mode is
  entered a few instructions earlier, the entry code counts its passes,
  and a second pass (or a fall-through) runs into an `ECALL` that the
  armed handler catches. Registers are unchanged. Because `MRET` copies
  `MPIE` into `MIE` and leaves `MPIE` = 1, each test clears `MPIE` first
  unless it sets it on purpose; otherwise `MIE` would quietly be turned
  on. Not tested: that `mepc[0]` reads as 0 after a write of 1. The spec
  requires it, but QEMU 10.0 keeps the bit (and `MRET` then jumps to the
  odd address), so the test would fail on the reference platform.
- **`priv/wfi.S`**: `WFI` may be a NOP, so the tests only check what
  happens around the wait, never its length. The wake-up source is the
  machine timer (`mtimecmp` in the CLINT). With the interrupt already
  pending and `MIE` = 0, `WFI` completes and execution goes on at the
  next instruction with no trap. The canonical `while (!MTIP) wfi;` loop
  against a timer `WFI_DELAY` ticks in the future ends with no trap.
  With `MIE` = 1 the interrupt is taken exactly once: `mcause` =
  interrupt bit | 7, `mepc` = the instruction after the `WFI` (a
  jump-to-self, so a `WFI` that doesn't wait gives the same `mepc`),
  `MIE` = 0, `MPIE` = 1 and `MPP` = M on entry, and `MIE` = 1 after the
  `MRET`. `mstatus.TW` = 1 changes nothing in M-mode. In U-mode with
  `TW` = 1 and nothing pending, `WFI` is illegal (mcause 2, `mepc` on
  the `WFI`, `MPP` = 0). The spec lets a `WFI` that completes within a
  bounded time not trap, and with nothing pending only a NOP-`WFI`
  completes, so this case pins down the usual (and QEMU's) behaviour.
  Neither alternative hangs: an `ECALL` after it catches a `WFI` that
  completes, and a timer interrupt set `WFI_DELAY` ticks ahead ends one
  that really waits, both as a clean `FAIL`. Registers are unchanged. On
  RV32, `mtime`/`mtimecmp` are read and written as two halves without
  ever passing through a value in the past.
- **`priv/csrpriv.S`**: a CSR's privilege is in its number (bits 9:8),
  and an access from a lower mode is illegal even when it writes
  nothing. Each of 13 M-mode CSRs is accessed once from U-mode per
  form. The read-only `mvendorid`, `marchid`, `mimpid` and `mhartid`
  get the four forms that don't write (`CSRRS`/`CSRRC` with `rs1` =
  `x0`, `CSRRSI`/`CSRRCI` with uimm 0). The writable `mstatus`, `misa`,
  `mie`, `mtvec`, `mscratch`, `mepc`, `mcause`, `mtval` and `mip`
  also get the seven that do (`CSRRW` with `rd` and with
  `x0`, `CSRRS`/`CSRRC` with a nonzero `rs1`, `CSRRWI`/`CSRRSI`/
  `CSRRCI` with a nonzero uimm; no `CSRRWI` for `misa` and `mtvec`).
  Each case checks that it traps exactly once, with mcause 2, `mepc` on
  the instruction and `mtval` 0 or the instruction's bits, and that
  `rd` keeps its preset value, so no M-mode value leaks into U-mode.
  The write forms also check, back in M-mode, that the CSR still holds
  its value. The written bit is chosen to be harmless if the write goes
  through: `TW`/`SIE` for `mstatus`, `MSIE`, vectored `MODE` for
  `mtvec`, `SSIP`. `misa` gets writes of values it already has,
  so a leak can't switch an extension off; that makes its write cases
  trap-only checks, as are those of `mscratch`, `mepc`, `mcause` and
  `mtval`, which the trap itself overwrites. `mcounteren`, `mcycle`,
  `minstret` and the PMP CSRs are not covered.
- **`priv/irqpriv.S`**: `mstatus.MIE` only gates interrupts in M-mode;
  in U-mode, M-mode interrupts are always enabled. For the machine
  software interrupt (the CLINT's `msip`) and the machine timer
  (`mtimecmp` = 0), each enabled in `mie`: in M-mode with `MIE` = 0 it
  is pending in `mip` but not taken. In U-mode entered with `MIE` = 0
  it is taken exactly once, with `mcause` = interrupt bit | 3 or 7,
  `MPP` = U, `MPIE` = 0 (U-mode's `MIE`), and `mepc` inside the U-mode
  code (a bounded spin, then an `ECALL`: the spec doesn't say how soon
  after the `MRET` the interrupt must be taken). In U-mode with the
  source pending but not enabled in `mie`, it is not taken: the `ECALL`
  traps (mcause 8). In M-mode with `MIE` = 1 the software interrupt is
  taken, once, with mcause = interrupt bit | 3. With `mtvec` in vectored
  mode an interrupt enters at BASE + 4 × cause (software +12, timer
  +28) and an exception (`ECALL`) at BASE; with both pending and
  enabled, the software interrupt (higher priority) is taken first. The
  vector table is 16 `addi s4, s4, 1` slots followed by a stub, so the
  count says exactly which slot was entered; a hart without vectored
  mode lands everything at BASE, which fails the interrupt cases, and
  one that ignores the `mtvec` write altogether sends the trap to the
  still-armed common handler: a `FAIL`, not a hang.
- **`priv/mstatus.S`**: `MPP` is WARL and must only hold modes the hart
  has: written 3 it reads 3, written 0 it reads 0, written 1 (S) it
  reads 1 with S-mode and 0 or 3 without, written 2 (reserved) it reads
  a legal mode. `misa.U` = 1. On RV64 `mstatus.UXL` = 2, and after
  writing 0 or 3 (128-bit) it still reads 1 or 2. An `ECALL` from
  U-mode entered with `MIE` = 0 and with `MIE` = 1 (`mie` = 0, so
  nothing can interrupt) traps exactly once with `MPIE` = U-mode's
  `MIE`, `MIE` = 0 and `MPP` = U on entry.

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
  105 per R-type (`rd`/`rs1`/`rs2`), 231 per I-type, load, store or
  JALR, 231 per branch run twice (once taken, once not taken), 300 for
  LUI/AUIPC/JAL, 136 per AMO or SC (`rd`/`rs1`/`rs2`
  plus the `aq`/`rl` bits), 66 per LR, 231 for FENCE (`fm`/`pred`/`succ`
  and its reserved `rd`/`rs1`) and for FENCE.I (its reserved
  `rd`/`rs1`/`imm` fields, which must be ignored), 45 per CSR
  instruction (`rd` plus `rs1`/uimm; the csr field is held at
  `mscratch`), 10 for CBO.ZERO (`rs1` only), 55 for most RVC formats
  (`C.BEQZ`/`C.BNEZ` twice, taken and not taken). An LR
  case also checks that a following SC succeeds, i.e. that the
  reservation landed on the address under test.
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
  caught. An AMO case is two checks, `rd` and the memory slot, both
  against the background encoding run on a second slot.
- **Control transfers** (JAL with its full ±1 MiB reach, JALR, the six
  branches, `C.J`, `C.BEQZ`, `C.BNEZ`, `C.JR`, `C.JALR`) land in a
  counting sled that `bitx.S` builds at run time in ~1 MiB of `.bss`:
  a run of `c.addi s5, 1` slots ending in a return. Each case's
  instruction is assembled into `.rodata`, copied onto a site in or next
  to the sled, and executed after `FENCE.I`; the number of slots counted
  identifies the landing address exactly. This avoids megabytes of
  filler. Forward offsets are planted inside the sled, so every correct
  landing counts only a few slots. The branches run every case twice,
  with operands that take the branch and with operands that don't
  (names ending `not taken`), so a bit pair that forces the condition
  either way fails, not only one that corrupts the offset.
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
                #   build/rv64/rv_tests.{elf,bin}   RV64IMAC
                #   build/rv32/rv_tests.{elf,bin}   RV32IMAC
```

or manually (one width shown; the other uses `rv32imac_zicsr_zifencei_zicboz_zabha`,
`ilp32`, `XLEN=32` and `elf32lriscv`):

```sh
SRCS="common.S main_tests.S \
      c/tests.S c/quadrant0.S c/quadrant1.S c/quadrant2.S \
      i/tests.S i/loads.S i/stores.S i/lui.S i/auipc.S i/jal.S \
      i/jalr.S i/branches.S i/op_alu.S i/op_imm.S i/op_imm32.S \
      i/op_alu32.S i/system.S i/fence.S m/tests.S m/mul.S m/div.S a/tests.S a/amo.S a/lrsc.S \
      zicsr/tests.S zicsr/reg.S zicsr/imm.S zifencei/tests.S zifencei/fencei.S \
      zicboz/tests.S zicboz/cbozero.S zabha/tests.S zabha/amo.S \
      priv/tests.S priv/mret.S priv/wfi.S priv/csrpriv.S \
      priv/irqpriv.S priv/mstatus.S bitx.S"
for f in $SRCS; do
  mkdir -p build/rv64/$(dirname $f)
  riscv64-linux-gnu-as -march=rv64imac_zicsr_zifencei_zicboz_zabha -mabi=lp64 --defsym XLEN=64 \
      --fatal-warnings -I src -o build/rv64/${f%.S}.o src/$f
done
riscv64-linux-gnu-ld -m elf64lriscv -Ttext=0x80000000 --no-dynamic-linker -nostdlib \
    -o rv_tests.elf $(for f in $SRCS; do echo build/rv64/${f%.S}.o; done)
riscv64-linux-gnu-objcopy -O binary rv_tests.elf rv_tests.bin
```

Run it from the repo root. The source paths are relative to `src/`. The
files in `src/c/`, `src/i/`, `src/m/`, `src/a/`, `src/zicsr/`,
`src/zifencei/`, `src/zicboz/`, `src/zabha/` and `src/priv/` `.include` `xlen.inc`, `harness.inc` and `bitx.inc` from
`src/` (`-I src`). Each object keeps its
source's subdirectory under `build/rv64/`, because the suites' `tests.S`
files share a basename.

`common.o` must be listed first at link time — it contains `_start`,
and needs to land at the very base of `.text` so the entry point ends
up at the `0x80000000` load address. The rest can be in any order
relative to each other.

`rv_tests.bin` is the flat binary — load it into RAM at `0x80000000`
and reset the hart with `pc = 0x80000000`, `mode = M`.

## Running under QEMU (for a quick check)

```sh
make run        # RV64 then RV32; or make run64 / make run32
# or:
qemu-system-riscv64 -M virt -bios none -cpu rv64,zabha=true \
    -kernel build/rv64/rv_tests.elf -nographic -serial mon:stdio
qemu-system-riscv32 -M virt -bios none -cpu rv32,zabha=true \
    -kernel build/rv32/rv_tests.elf -nographic -serial mon:stdio
```
(`zabha=true` because QEMU's `rv64`/`rv32` CPUs leave Zabha off by
default; without it every Zabha check is a `FAIL`.)
(`Ctrl-A X` to exit QEMU; the firmware parks in `WFI` after the summary
and never exits on its own.) `-kernel` with an ELF works fine here since
QEMU just loads the ELF's segments and jumps to its entry point, which
is the same `0x80000000` load address as the flat `.bin`.

To check that a missing extension fails cleanly instead of hanging,
switch it off with `-cpu`, e.g. `-cpu rv64,a=false,zawrs=false`,
`-cpu rv32,zicboz=false`, `-cpu rv64,zifencei=false`, or plain `-cpu
rv64` for Zabha (QEMU refuses `a=false` while Zawrs is on). The expected failure
counts are in "Unimplemented instructions fail, they don't hang".

## Adding another test suite

`common.S` doesn't know or care what it's testing — it just calls
`run_tests` (in `main_tests.S`) and reads `pass_count`/`fail_count`
afterward. `main_tests.S` in turn just calls each suite's own entry
point. To add a new suite (say, the `F` extension):

1. Create a directory for the suite (e.g. `f/`) and write its
   top-level file, `f/tests.S`, with `.global run_f_tests`, printing its
   own banner and calling into one or more category files in the same
   directory (e.g. `f/load_store.S`, `f/arith.S`, with no `f_` prefix: the
   directory already says which suite a file belongs to). This is the same
   way `c/tests.S` calls into `c/quadrant0/1/2.S`, `i/tests.S`
   into `i/*.S`, `m/tests.S` into `m/mul.S`/`m/div.S`, `a/tests.S`
   into `a/amo.S`/`a/lrsc.S`, `zicsr/tests.S` into
   `zicsr/reg.S`/`zicsr/imm.S`, `zifencei/tests.S` into
   `zifencei/fencei.S`, `zicboz/tests.S` into `zicboz/cbozero.S`,
   `zabha/tests.S` into `zabha/amo.S`, and
   `priv/tests.S` into `priv/mret.S`/`priv/wfi.S`/`priv/csrpriv.S`/
   `priv/irqpriv.S`/`priv/mstatus.S`.
   Every extension gets its own directory, even a single-instruction one
   like Zifencei or Zicboz.
   Use `check`/`uart_puts` from `common.S` the same way the existing
   suites do, and start every test with `TEST_BEGIN <name>` (`.include
   "harness.inc"` after `xlen.inc`) so its name is out before it runs. Split it into multiple files if it's large enough to
   benefit — each category file should expose exactly one entry symbol
   and keep its macros/subroutines local.
2. Add one line to `main_tests.S`: `call run_f_tests`.
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
filler instructions (`.rept`-generated, sized to hit a specific byte
count; each one a poison or an escape to the poison, so a short
landing fails) rather than passing a numeric immediate directly.
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

Additionally:

4. **No assumptions about RAM contents or alignment support.** Reset
   zeroes all of `.bss` (the flat `.bin` doesn't contain it, so on
   hardware it holds whatever RAM held at power-on), and every load and
   store under test is naturally aligned, so a hart that traps on
   misaligned accesses runs the base-ISA suites unchanged.

And for the bit-independence tests (see "Bit independence across
fields"):

5. **RAM beyond the image.** The flat binary is ~5.3 MB (RV64) or
   ~4.1 MB (RV32), and the run-time counting sled adds ~1 MiB of
   `.bss` after it — about 6.1 MiB (RV64) or 5 MiB (RV32) from
   `0x80000000` in all.
6. **CSRs.** The Zicsr suite assumes `mscratch` is fully read/write,
   `mepc` holds even values as written, and `misa` is implemented (not
   read as 0) and reports I, M, A and C.
7. **Executing freshly written code.** The control-transfer cases copy
   an instruction into RAM and run it after `FENCE.I` (hence Zifencei in
   `-march`). The target must allow instruction fetch from RAM that was
   just written, with `FENCE.I` as the only synchronisation. On a hart
   without Zifencei (reset's probe traps) the `FENCE.I` is skipped: the
   run still completes, and the Zifencei suite fails, but these cases
   are then only right if instruction fetch is coherent anyway (QEMU's
   is). A stale fetch runs an earlier planted instruction whose target
   is still inside the sled, so it should show as a wrong count rather
   than a runaway; that has not been tried on such hardware. The
   bit-independence loads and stores, unlike the per-field ones above,
   are always naturally aligned.
8. **Zicboz and its block size.** The Zicboz suite needs `CBO.ZERO`
   implemented (QEMU enables it by default) and assumes a 64-byte cache
   block. Set `CBOZ_BLOCK_BYTES` in `zicboz/cbozero.S` to your platform's
   block size (the device tree's `riscv,cboz-block-size`; a power of two
   from 8 to 256). A wrong value shows up as failing "zeroes exactly"
   cases, not a trap. Without Zicboz, every Zicboz check is a `FAIL`
   with mcause 2; likewise every A check without A (see
   "Unimplemented instructions fail, they don't hang").
9. **Zabha.** The Zabha suite needs the byte/halfword AMOs, which
   QEMU's `rv64`/`rv32` CPUs leave off unless given `zabha=true` (the
   `Makefile`'s run targets pass it). Without Zabha every Zabha check
   is a `FAIL` with mcause 2, and the run completes.
10. **U-mode, PMP and the CLINT.** The U-mode cases of `i/system.S`,
   `i/fence.S`,
   `zicboz/cbozero.S` and the `priv/` files need U-mode, and PMP, if
   implemented, must accept `common.S`'s all-memory entry 0 (a hart
   with no PMP at all is fine, whether its PMP CSRs read as zero or
   trap). `zicboz/cbozero.S` needs `menvcfg` (and `senvcfg` with
   S-mode), which every hart with U-mode and Zicboz has.
   `priv/csrpriv.S` sets `mtvec` to vectored mode for a few cases, at
   `trap_handler`'s 16-byte alignment; exceptions still go to `BASE`.
   `priv/wfi.S` and `priv/irqpriv.S` need a
   CLINT/ACLINT at `CLINT_BASE` (default `0x02000000`, QEMU virt's, set
   in each file; hart 0's `msip` at `+0`, `mtimecmp` at `+0x4000`,
   `mtime` at `+0xbff8`) and, for `priv/wfi.S`, a timer
   for which `WFI_DELAY` (10000 ticks, 1 ms at QEMU's 10 MHz) is short
   to wait but longer than the few instructions between arming the
   timer and the `WFI`. A `WFI` that never wakes hangs with its
   instruction group (`WFI:`) as the last line printed.
11. **The UART line control register.** `i/fence.S`'s I/O-ordering
   cases write and read back the ns16550a's LCR (offset 3, changing only
   parity/stop bits, after LSR.TEMT, offset 5 bit 6, shows the
   transmitter idle), then restore 8N1. The optional scratch register
   (SCR) is not used. A UART whose LCR doesn't read back fails those
   two checks rather than hanging.

## Files

All assembly sources and include files live under `src/`. The
documentation, the `Makefile` and the container scripts stay in the repo
root. Inside `src/`, the shared harness and include files sit at the top
level. Each suite has its own subdirectory holding its orchestrator
(`tests.S`) and its category files: `src/c/`, `src/i/`, `src/m/`,
`src/a/`, `src/zicsr/`, `src/zifencei/`, `src/zicboz/`, `src/zabha/`,
`src/priv/`.
Source paths elsewhere in this document are relative to `src/`.

- `common.S` — reusable boot/UART/reporter harness (suite-agnostic).
- `main_tests.S` — top-level dispatcher (defines `run_tests`).
- `c/tests.S` — RVC suite orchestrator (defines `run_c_tests`).
- `c/quadrant0.S` / `c/quadrant1.S` / `c/quadrant2.S` — the RVC
  per-instruction test bodies, one file per RVC opcode quadrant.
- `i/tests.S` — base-ISA suite orchestrator (defines `run_i_tests`).
- `i/loads.S` — the base-ISA load instruction test bodies.
- `i/stores.S` — the base-ISA store instruction test bodies.
- `i/lui.S` — the `LUI` test body.
- `i/auipc.S` — the `AUIPC` test body.
- `i/jal.S` — the `JAL` test body.
- `i/jalr.S` — the `JALR` test body.
- `i/branches.S` — the conditional-branch test bodies.
- `i/op_alu.S` — the R-type ALU test bodies.
- `i/op_imm.S` — the OP-IMM (I-type ALU) test bodies.
- `i/op_imm32.S` — the OP-IMM-32 (RV64 word-width I-type ALU) test
  bodies.
- `i/op_alu32.S` — the OP-32 (RV64 word-width R-type ALU) test
  bodies.
- `i/system.S` — the `ECALL`/`EBREAK` test bodies.
- `i/fence.S` — the `FENCE` test bodies.
- `m/tests.S` — M suite orchestrator (defines `run_m_tests`).
- `m/mul.S` — the multiply test bodies.
- `m/div.S` — the divide/remainder test bodies.
- `a/tests.S` — A suite orchestrator (defines `run_a_tests`).
- `a/amo.S` — the atomic memory operation (AMO) test bodies.
- `a/lrsc.S` — the load-reserved/store-conditional test bodies.
- `zicsr/tests.S` — Zicsr suite orchestrator (defines `run_zicsr_tests`).
- `zicsr/reg.S` — the `CSRRW`/`CSRRS`/`CSRRC` test bodies.
- `zicsr/imm.S` — the `CSRRWI`/`CSRRSI`/`CSRRCI` test bodies.
- `zifencei/tests.S` — Zifencei suite orchestrator (defines
  `run_zifencei_tests`).
- `zifencei/fencei.S` — the `FENCE.I` test bodies.
- `zicboz/tests.S` — Zicboz suite orchestrator (defines
  `run_zicboz_tests`).
- `zicboz/cbozero.S` — the `CBO.ZERO` test bodies.
- `zabha/tests.S` — Zabha suite orchestrator (defines
  `run_zabha_tests`).
- `zabha/amo.S` — the byte/halfword AMO test bodies.
- `priv/tests.S` — privileged suite orchestrator (defines
  `run_priv_tests`).
- `priv/mret.S` — the `MRET` test bodies.
- `priv/wfi.S` — the `WFI` test bodies.
- `priv/csrpriv.S` — M-mode CSR access from U-mode.
- `priv/irqpriv.S` — M-mode interrupts taken in U-mode; in M-mode,
  vectored `mtvec` and interrupt priority.
- `priv/mstatus.S` — `mstatus` privilege fields and the trap-entry
  stack from U-mode.
- `bitx.inc` — macros shared by every file's bit-independence tests
  (included, not linked).
- `bitx.S` — the run-time counting sled for the control-transfer
  bit-independence tests.
- `harness.inc` — `TEST_BEGIN`, which announces a test before it
  runs, and the `TRAP_*` macros for tests that trap on purpose
  (included, not linked).
- `xlen.inc` — the RV64/RV32 switch (`REG_S`/`REG_L`, `LIX`/`LIXT`,
  `LWUX`, `INTX_MIN`/`INTX_MAX`, ...), included first by every file.
- `Makefile` — build/run/disasm/clean targets, for both widths.
- `build/rv64/rv_tests.bin`, `build/rv32/rv_tests.bin` — the flat
  binaries, ready to load at `0x80000000`.
- `build/rv64/rv_tests.elf`, `build/rv32/rv_tests.elf` — the linked ELFs
  (handy for `objdump -d` / debugging with gdb; not themselves loadable
  as the flat images).
