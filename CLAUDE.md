# CLAUDE.md

Bare-metal, M-mode RISC-V instruction-set exerciser written in GNU
assembly, built as two images from the same sources: RV64IMAC and
RV32IMAC. It boots at `0x80000000`, runs the test suites with deliberately
adversarial edge-case coverage, and prints OK/FAIL per case plus a summary
over an ns16550a UART at `0x10000000` (115200 8N1). `README.md` is the
detailed design doc; read the relevant section before extending a suite.

Never assume test results. Always assemble, link, disassemble, and run under
QEMU. Most of this project's real bugs (see "Named recurring bug classes")
were invisible until an actual QEMU run.

## Build / run

- `make`: builds both images, `build/rv64/rvc_test.{elf,bin}` and
  `build/rv32/rvc_test.{elf,bin}`. Toolchain prefix `CROSS ?=
  riscv64-linux-gnu-`. Every file is assembled with `--defsym XLEN=64|32`
  and `--fatal-warnings`; RV32 uses `-march=rv32imac_zicsr_zifencei_zicboz_zabha
  -mabi=ilp32` and `ld -m elf32lriscv`.
- `make disasm64` / `make disasm32`: `objdump -d -M no-aliases` piped to
  `less`. `no-aliases` is required to see the raw `c.*` mnemonics. In a
  non-interactive shell, run the `objdump` command directly.
- `make run` (both), `make run64`, `make run32`: QEMU `virt`, `-bios none`
  (`qemu-system-riscv64` / `qemu-system-riscv32`), `-cpu rv64,zabha=true`
  / `-cpu rv32,zabha=true`: QEMU leaves Zabha off by default, and
  without it the Zabha suite FAILs. After the summary the
  firmware parks in a `WFI` loop and never exits, so a non-interactive
  check needs a timeout (each run takes about a second), e.g.
  `timeout 30 qemu-system-riscv32 -M virt -bios none -cpu rv32,zabha=true -kernel build/rv32/rvc_test.elf -nographic -serial mon:stdio > build/rv32/run.log`,
  then confirm that `grep -c FAIL` on the log is 0, the summary line
  reports `fail_count = 0`, and there's no `UNEXPECTED TRAP`. Always check
  both widths. When touching `common.S`'s boot or trap code or the
  U-mode tests, also run each width with `-cpu rv64,zabha=true,pmp=false` /
  `-cpu rv32,zabha=true,pmp=false` (a hart without PMP, whose PMP CSRs trap): same
  totals, no failures. When touching the trap handler, `check_trap`,
  `SYNC_I`, or the A/Zicboz/Zabha/Zifencei tests, also run each width
  with the extension switched off (`-cpu rv64,a=false,zawrs=false`,
  `zicboz=false`, `zifencei=false`, each with `zabha=true` added; plain
  `-cpu rv64` for Zabha; and all at once): the run must
  reach its summary with the same totals, no `UNEXPECTED TRAP`, and
  exactly the failure counts in README "Unimplemented instructions
  fail, they don't hang".
- `make clean`: removes `build/`, which holds all outputs (gitignored).
- Inside the Claude container (`claude-container.Dockerfile`), the
  toolchain is `riscv64-unknown-elf-*` (it handles both widths) and
  `make` is not installed. Run the equivalent `as`/`ld`/`objcopy`
  commands from the `Makefile` by hand with that prefix (with `make`
  available, `make CROSS=riscv64-unknown-elf-` would do the same).
  `common.o` must come first on the `ld` line. Run from the repo root
  with `-I src` (the suite files `.include` `xlen.inc`/`harness.inc`/
  `bitx.inc` from `src/`), and give each object its source's path under
  `src/`
  (`src/c/tests.S` → `build/rv64/c/tests.o` etc.): the suites'
  `tests.S` files share a basename.

## Layout

All assembly sources and include files live under `src/`. Docs, the
`Makefile` and the container scripts stay in the repo root. Source paths
in this file are relative to `src/`.

- `common.S`: suite-agnostic harness (boot, PMP setup for U-mode, trap
  handler, UART, the `check` comparator, `pass_count`/`fail_count`,
  summary/halt). It calls `run_tests`. It must be first on the link line so that `_start` lands
  at `0x80000000`.
- `main_tests.S`: defines `run_tests` and calls each suite entry point.
- Suites: one directory each, holding an orchestrator (`tests.S`) plus
  category files, with no suite prefix in the file names.
  - RVC: `c/tests.S` → `c/quadrant0/1/2.S`
  - RV64I: `i/tests.S` → `i/*.S`
  - RV64M: `m/tests.S` → `m/mul.S`, `m/div.S` (all 13 RV64M instructions,
    including the `W` forms)
  - RV64A: `a/tests.S` → `a/amo.S` (all 18 AMOs, `.W` and `.D`),
    `a/lrsc.S` (LR/SC, `.W` and `.D`)
  - Zicsr: `zicsr/tests.S` → `zicsr/reg.S` (CSRRW/CSRRS/CSRRC),
    `zicsr/imm.S` (CSRRWI/CSRRSI/CSRRCI); the CSR under test is
    `mscratch`, and the csr field is held fixed in the bitx cases
  - Zifencei: `zifencei/tests.S` → `zifencei/fencei.S` (FENCE.I)
  - Zicboz: `zicboz/tests.S` → `zicboz/cbozero.S` (CBO.ZERO); results
    are measured by scanning a four-block buffer (`cz_fill`/`cz_scan`)
  - Zabha: `zabha/tests.S` → `zabha/amo.S` (all 18 byte/halfword AMOs,
    `.B` and `.H`, on both widths); its value/neighbour tables name
    their cases inline (`T_ZB_VAL`/`T_ZB_NEIGH` take a description)
  - Privileged: `priv/tests.S` → `priv/mret.S` (MRET), `priv/wfi.S`
    (WFI, woken by the CLINT machine timer). ECALL/EBREAK are RV32I
    proper and live in `i/system.S`.
- Every extension gets its own suite directory, even a single-instruction
  one like Zifencei; `i/` holds only RV32I/RV64I proper.
- `xlen.inc`: the RV64/RV32 switch, `.include`d first by every file (see
  "RV64 and RV32" below).
- `harness.inc`: `TEST_BEGIN`, the `TRAP_ARM`/`TRAP_DISARM`/
  `TRAP_DISARM_R`/`TRAP_LD` macros, `TRAP_REPORT`/`TRAP_FAILS` (trap →
  `check_trap` FAILs), `SYNC_I` plus `MSTATUS_*` bits, `.include`d by
  every category file (and `bitx.S`) right after `xlen.inc`.
- `bitx.inc` (macros, `.include`d by every category file) and `bitx.S`
  (a run-time counting sled): the bit-independence machinery; see below.
- Each category file exposes exactly one global entry symbol
  (`tests_xxx`) and keeps its macros, subroutines, and data local.

## Core conventions

- **Encoding control is required, not a style choice.** Base-ISA and M
  files use `.option norvc` throughout. Without it, the assembler silently
  swaps in compressed encodings: `BEQ`/`BNE` against `x0` with an x8–x15
  register become `C.BEQZ`/`C.BNEZ`, and `JALR` with imm=0 becomes
  `C.JR`/`C.JALR`. RVC tests write explicit `c.*` mnemonics wrapped in
  `.option rvc`/`.option norvc`. Always check the encoding width in
  `objdump -d -M no-aliases` output; the directive alone isn't proof.
- **`check(a0=name_ptr, a1=expected, a2=actual)`** in `common.S` is the
  universal reporter. It prints `"<name> - OK"` or `"- FAIL"` and
  bumps `pass_count`/`fail_count`. It clobbers `t0`–`t6` and `a0`–`a2`.
  Every case goes through it so it counts toward the shared totals.
  It also records the first `FAIL_LOG_MAX` (8) failures (name
  pointer, expected, actual), so the summary can list them with their
  values. The name must therefore be a `.rodata` string, never one
  built at run time.
- **Name first: `TEST_BEGIN <name>` starts every test**, before any of
  its setup, so a test that traps or hangs has its name as the last
  UART line (`"<name> - "` then `UNEXPECTED TRAP`). It calls
  `test_begin` in `common.S`; the `check` with the same name then
  prints only the verdict. It is register-transparent, but place it
  above any PC-reference label (e.g. `.Lauipc_sp:`, `.Lebreak_pc_marker:`),
  never between a label and the instruction it marks, and before
  `sp`/`gp` are swept. A test with several checks gets one `TEST_BEGIN`
  per check, each just before the code for that check. bitx cases need
  nothing: `BX_ENTER` announces the name of the case's first
  `BX_REPORT`. A passing run's log must stay free of lines ending in
  `" - "` (a dangling announcement means a `TEST_BEGIN` name doesn't
  match its `check`).
- **Capture before reuse.** If a macro sweeps a register that might be
  `a0`/`a1`/`a2` or `t0`–`t6`, copy the result into a safe scratch register
  right after the instruction under test. Use `t2` by convention, or an
  `s` register if the value must survive several `check` calls. Do this
  before loading `a0`/`a1`/`a2`.
- **Macro-based test generation.** Tests come from small per-instruction
  macros named `T_<INSN>_REG`/`_RS1`/`_RS2`/`_OFF`/`_VAL`/`_ALIAS`/
  `_CROSS`/`_PAIR`, parameterized by register, immediate, expected value,
  and name string. GNU `as` macro parameters are plain text substitution,
  so mnemonics can be passed as arguments (e.g. `T_M_VAL insn, ...` or
  `T_CI_RI insn, ...` shared by `c.addi`/`c.addiw`).
- **String-table consistency.** Every `str_*` label used at a call site
  needs a matching `.asciz` definition, and there should be no orphaned
  definitions. Grep both directions after writing or editing a file. A
  malformed comment block once caused about 80 missing definitions and 4
  orphaned ones.
- **PC-relative instructions** (`AUIPC`, `JAL`, `C.J`, branches) need
  expected values computed at runtime from local labels via `la`. Literals
  are wrong because the answer depends on link-time addresses.
- **Boundary and offset tests are verified in the disassembly** by
  computing target minus branch. Never trust `.rept` counts or
  source-level byte counting (see bug class 3).
- **Sign vs. zero extension** comes up again and again. Push the same bit
  pattern through both the signed and unsigned variants (`LB`/`LBU`, and
  so on) so a decoder that mixes them up fails. This has also bitten the
  test code itself, e.g. reading back a stored value with `lw` instead of
  `lwu`.
- **Signed vs. unsigned comparisons** (`SLT`/`SLTU`, `BLT`/`BLTU`,
  `BGE`/`BGEU`) need operand pairs whose signed and unsigned readings
  diverge (`-1` vs `1`, `INT64_MIN` vs `INT64_MAX`). `i/branches.S` and
  `i/op_alu.S` share the same truth table.
- Match the existing heavy, explanatory header and block comment style.

- **Traps on purpose go through the armed handler.** `TRAP_ARM label`
  makes the next trap (any cause, any privilege mode) record
  `trap_mcause`/`_mepc`/`_mtval`/`_mstatus`, bump `trap_count`, disarm
  and `MRET` to `label` in M-mode (clearing `mie` for an interrupt).
  Check the recorded cause and the `trap_count` delta; `TRAP_DISARM`
  after the resume label covers the no-trap path. Never add causes to
  the unarmed handler. The handler runs on its own stack
  (`trap_stack`), so a trap while `sp` is swept is safe, and it
  clobbers `mscratch` (via `t0`) on every trap: never keep a value in
  `mscratch` across a trap.
- **An instruction under test that may be unimplemented runs armed,
  and a trap becomes `FAIL`s, never an `UNEXPECTED TRAP` hang.** This
  covers every instruction of the A, Zicboz, Zabha and Zifencei suites, and
  every future extension. `TRAP_ARM resume` before it (one arming
  covers a group, e.g. an `LR`/`SC` pair, with nothing stored between
  `LR` and `SC`), `TRAP_DISARM` after it (`TRAP_DISARM_R reg` while
  `sp` may still be swept), and after the test's checks `TRAP_FAILS
  resume, name...` naming *every* check the test makes, so line counts
  don't change. A test that sweeps `sp`/`gp`/`tp` restores them at its
  resume label first; bitx cases use `BX_NAME`/`BX_ENTER label`/
  `BX_REPORT_AT`/`BX_TRAP_FAILS` (see `BX_C_AMO_` in `a/amo.S`). A
  test that patches `.text` undoes it on the resume path too.
  Mutation-test it: replace the instruction with `.word 0` in a scratch
  copy (including a bitx case that sweeps `sp`) and confirm only its
  checks FAIL, with mcause 2.
- **`FENCE.I` used as test machinery goes through `SYNC_I tmp`**
  (skipped when reset's probe found no Zifencei, `has_fencei` = 0);
  a `FENCE.I` under test is armed instead.
- **Every hand-written `MRET` clears `MPIE` first** unless the test sets
  it on purpose: `MRET` copies `MPIE` into `MIE` and leaves `MPIE` = 1,
  so the next `MRET` (or a U-mode round trip through the handler)
  silently turns `MIE` on, and the next test that enables an `mie` bit
  takes an unarmed interrupt. Files that touch `MIE` clear it on exit.
  Entering U-mode: clear `MPP` and `MPIE`, `csrw mepc`, `mret`.
- **A misbehaving instruction must give a FAIL, never a hang.** For
  every test that expects a trap, walk each wrong path (falls through,
  jumps back to `mepc`, stays in U-mode, waits forever) and give it a
  backstop into the still-armed handler: an `mscratch` read or `ECALL`
  in U-mode, a pass counter that sends a second pass to an escape
  `ECALL` (MRET in U-mode: `mepc` is the U-mode entry point, so a
  working `MRET` would loop), a timer interrupt that ends a wait.
  Then simulate each wrong path in a scratch copy (`nop`, jump to
  `mepc`, jump-to-self) and confirm the run still reaches its summary.
  Only documented platform assumptions may hang (a timer interrupt
  that never arrives).

## RV64 and RV32

Every test must build and pass on both widths. Mechanics (`xlen.inc`):
- **`LIX`, never plain `li`, for test constants.** On RV32 GNU `as`
  silently truncates 64-bit `li` constants (`li t3, 0x8000000000000000` →
  `li t3, 0`, no warning). `LIX` is `li` on RV64 and an assembly error on
  RV32 for anything that isn't a 32-bit value, so every such case gets
  decided explicitly. `LIXT` truncates deliberately, and only for fill
  patterns or for the operands *and* expected value of ops whose low 32
  bits depend only on the operands' low 32 bits (copies, add/sub, logic,
  left shifts). Never use it for right shifts, compares or width-meaningful
  values.
- `REG_S`/`REG_L`/`REG_BYTES`/`REG_DATA` for register-sized memory (stack
  slots keep 8-byte spacing on both), `LWUX` for a zero-extending 32-bit
  read-back (`lwu`/`lw`), `INTX_MIN`/`INTX_MAX`/`XLEN_MASK` for
  width-dependent values.
- Instructions or tests that exist on one width only go under `.if XLEN
  == 64` (RV64-only: LD/SD/LWU, the OP-IMM-32 and OP-32 `W` forms, the
  M `W` forms, the `AMO*.D` forms, C.LD/C.SD/C.LDSP/C.SDSP,
  C.ADDIW/C.SUBW/C.ADDW, tests about bits above 31) or `.if XLEN == 32`
  (C.JAL). Shift amounts are 5 bits on RV32.
- A test name that states a width gets a width-conditional `.asciz`
  (same label, two texts).
- Assemble-time expected values in bitx case macros are truncated by
  `BX_LDC`, which is right only for truncation-safe ops. Right shifts
  must be written in terms of `XLEN`/`XLEN_MASK` (see `BX_C_CI` in
  `c/quadrant1.S`).

## Named recurring bug classes (check all new test code for these)

1. **A fixed helper register collides with the swept register list.** A
   macro sweeps register `X` across a list while using a fixed register `Y`
   as scratch or as the base address. If `Y` is ever in `X`'s list, the
   macro corrupts its own inputs. This happened twice:
   - `i/loads.S` `T_LB8_RS1` family: the scratch register `t0` was also
     swept as `basereg`. Fixed by moving the scratch to `t1`.
   - `i/stores.S` `T_S*_RS2` family: the base register `s0` was also
     swept as `rs2reg`. Fixed by moving the base to `s1`.

   Neither was caught by code review. Both only showed up as a trap in QEMU
   (mcause 7, store/AMO access fault). Check explicitly that the fixed
   register is outside every swept list.
2. **Skipping capture-before-reuse.** This hit `T_SRLI_REG`, `T_SRAI_REG`,
   `T_ANDI_REG`, and an early `C.NOP` test.
3. **GNU `as` branch relaxation is unstable at exact compressibility
   boundaries.** A `.rept`-padded boundary test can assemble correctly in
   isolation but silently widen when it sits inside a bigger file, with no
   warning. The fix is to back off one filler instruction from the
   theoretical maximum and label the test honestly (`+252` rather than
   `+254` for `C.BEQZ`/`C.BNEZ`, `+2044` rather than `+2046` for `C.J`).

## Other GNU `as` quirks

- `c.lui` takes its immediate in the full 20-bit `lui` operand space
  (`imm & 0xfffff`), not the compact −32..31 range.
- `c.srli`/`c.srai`/`c.slli` reject `shamt=0`, so the smallest tested
  shamt is 1. This is an assembler restriction, not a hardware one.
- `C.ADDI16SP` can only encode deltas from −512 to +496, so undoing a −512
  test delta takes two steps.
- `gp` must be initialized before the first data access, or it faults
  (mcause 7). Initialize it with `la gp, __global_pointer$` under
  `.option norelax`. Relaxed `la` depends on `gp` already being set, so
  without `norelax` the setup is circular.

## Bit independence across fields

**Standing requirement: every tested instruction gets bit-independence
coverage, including every instruction added in the future.** Per-field
sweeps can't catch a decoder fault where one bit misbehaves only together
with another bit, so for every pair of bits among an instruction's
variable fields (within one field or across two) there is a case with
exactly those two bits set and the other fields at a background. That is
C(N,2) cases for N variable bits, per instruction, not per format.
`C.ADDI4SPN` (`T_A4SPN_CROSS`/`T_A4SPN_PAIR`) was the original worked
example; everything else is generated by `bitx.inc`. Its header documents
the method, the register candidates (x1/x2/x4/x8/x16 and the two-bit
numbers, including sp/gp/tp), the reserved registers and the
reference-value rules. README "Bit independence across fields" has the
overview.

To cover a new instruction:
- Write a case macro in its file, `BX_C_<X> <fixed args>, <field values>`,
  starting with `BX_ENTER` and ending with `BX_REPORT "<NAME> bitx ..."`
  (expected value in `t5`, actual in `t6`).
- Call the matching enumerator (`BX_E_RRR5`, `BX_E_RRRI5`, `BX_E_RRI5`,
  `BX_E_RI5`, `BX_E_RI3`, `BX_E_RR3`, `BX_E_I`, ...) from the file's `bitx_*`
  subroutine.
- The expected value must never come from an encoding carrying the bits
  under test. Use the `t2`/`t3`/`t4` background encoding only when there
  is no immediate; otherwise use an assemble-time constant or the
  register-register twin with the immediate loaded from the pool.
- Load constants with `BX_LDC`/`BX_POOL` (never `li`, never anything
  gp-relative).
- Control transfers go through the sled (`BX_PLANT`/`BX_GO`/`BX_COUNT`,
  after `call bx_sled_init`).
- Mutation-test the new case macro in a scratch copy of the tree: break
  the instruction's operand or expected value and confirm the cases fail.

Other notes:
- The image is now well over 1 MiB, beyond JAL's ±1 MiB reach. **Every
  call to a symbol in another file uses `call` (AUIPC+JALR), never
  `jal`**: `check`, `uart_puts`, `bx_sled_init`, and the `tests_*`/
  `run_*` entry points. Each new file pushes the later ones further
  away, so a `jal` that links today can break with the next addition
  (`relocation truncated to fit: R_RISCV_JAL`). Plain `jal ra, ...`
  stays only for subroutines in the same file (`test_c_*`, `bitx_*`,
  `common.S`'s own UART helpers) and for the JAL/C.JAL instructions
  under test. `call` is 8 bytes rather than 4, so after converting
  sites inside code that contains boundary tests, check in the
  disassembly that no branch/jump offset changed.
- Documented skips: +2 offsets from 4-byte JAL/branches (they land in
  the instruction's own upper half), `C.LUI rd=x2` (that encoding is
  `C.ADDI16SP`), and `mepc[0]` reading as 0 after a write of 1 (the spec
  requires it; QEMU 10.0 keeps the bit).
- Instructions with a single fixed encoding (C.EBREAK, ECALL, EBREAK,
  MRET, WFI) have no variable bits, so no bitx cases: C(0,2) = 0.

## When adding or changing tests

1. For a new category file: put it in its suite's directory, named
   without a suite prefix (`i/op_alu32.S`, not `i_op_alu32.S`),
   add it to `SUITE_SRCS` in the `Makefile` and call its entry point
   from the suite orchestrator. For a new suite: create a new directory
   with its own `tests.S` orchestrator, and also add `call
   run_xxx_tests` to `main_tests.S`.
2. Keep the duplicated file and instruction lists in sync. They appear in
   the `Makefile` header comment, the orchestrator's header comment
   (e.g. `i/tests.S`), and `README.md` (Architecture, suite sections,
   "Adding another test suite", Files).
3. Add bit-independence coverage for every new instruction (see above).
   Then run the string-table consistency check (bitx names are inline and
   exempt).
4. Clean rebuild of both images, run both under QEMU, and confirm zero
   failures and no unexpected traps on each. Spot-check encodings and
   operands in the disassembly.
5. Update the totals table (both widths, with the per-instruction/bitx
   split) in `README.md`, and add a coverage bullet
   for the new file in the style of the existing ones.

## Scope notes

- RVC floating-point loads and stores are out of scope (see README).

## Porting to other hardware/simulators

- The Zicboz cache-block size is `CBOZ_BLOCK_BYTES` in
  `zicboz/cbozero.S` (default 64, QEMU's `cboz_blocksize`).
- The UART clock is `UART_CLK_HZ` in `common.S` (default `1843200`). The
  115200-baud divisor is computed from it at assemble time.
- The code assumes the standard ns16550a register layout with 1-byte
  stride (RBR/THR/DLL @0, IER/DLM @1, FCR @2, LCR @3, MCR @4, LSR @5).
- The bitx control-transfer tests need about 1 MiB of RAM after the
  image (about 5.5 MiB from `0x80000000` in total on RV64, 4.5 MiB on
  RV32). They also need instruction fetch from freshly written RAM,
  synchronised by `FENCE.I` (`SYNC_I`; skipped without Zifencei, in
  which case fetch must be coherent on its own).
- Zabha must be switched on explicitly in QEMU (`zabha=true`); the
  `Makefile`'s `QCPU64`/`QCPU32` pass it to `make run`.
- The trap handler, unarmed, only expects `mcause == 3` (breakpoint).
  Anything else prints `UNEXPECTED TRAP` with the mcause and hangs. On a
  different platform, early failures therefore show up as that hang, not
  as a silent wrong answer. That's by design. The exception is the A,
  Zicboz, Zabha and Zifencei instructions, which run armed: without those
  extensions their checks FAIL with the trap's mcause and the run
  completes.
- The U-mode cases (`i/system.S`, `priv/`) need U-mode and, if PMP is
  implemented, one that accepts `common.S`'s all-memory entry 0. No PMP
  at all is fine: reset's PMP writes run under a temporary `mtvec`
  (`pmp_skip`) that steps over them if they trap. `priv/wfi.S` needs a
  CLINT at `CLINT_BASE` (default `0x02000000`) and a timer for which
  `WFI_DELAY` (10000 ticks) is short.
