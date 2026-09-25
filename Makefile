# Makefile for the RVC test firmware
#
# Requires a riscv64 GNU binutils/gcc toolchain. On Debian/Ubuntu:
#   sudo apt-get install binutils-riscv64-linux-gnu
# (a bare-metal riscv64-unknown-elf- toolchain works too; just adjust
# CROSS below)
#
# Builds two images from the same sources: build/rv64/rv_tests.{elf,bin}
# (RV64IMAC) and build/rv32/rv_tests.{elf,bin} (RV32IMAC). All build
# outputs (object files, the linked ELFs, and the flat binaries) are
# placed under BUILD_DIR (default: build/), which is created
# automatically if it doesn't exist; object files mirror the source tree
# (src/c/tests.S -> build/rv64/c/tests.o, ...). All sources live
# under SRC_DIR (default: src/): the shared harness and include files
# directly in it, and each suite's files in its own subdirectory
# (c/, i/, m/, a/, zicsr/, zifencei/, zicboz/, zabha/, priv/).
# The paths below are relative to src/.
#
# Source layout (under src/):
#   common.S         - reusable boot/UART/reporter harness, suite-agnostic.
#                       Provides _start and expects a "run_tests" symbol
#                       from whichever test-suite object is linked in.
#   main_tests.S      - top-level dispatcher; defines run_tests, calls
#                       each suite's own entry point in turn.
#   c/tests.S         - RVC suite orchestrator; defines run_c_tests,
#                       calls tests_c_quadrant0/1/2.
#   c/quadrant0.S     - C.ADDI4SPN, C.LW, C.SW, C.LD, C.SD
#   c/quadrant1.S     - C.NOP, C.ADDI, C.ADDIW, C.LI, C.ADDI16SP, C.LUI,
#                       C.SRLI, C.SRAI, C.ANDI, C.SUB, C.XOR, C.OR,
#                       C.AND, C.SUBW, C.ADDW, C.J, C.BEQZ, C.BNEZ
#   c/quadrant2.S     - C.SLLI, C.LWSP, C.LDSP, C.JR, C.MV, C.EBREAK,
#                       C.JALR, C.ADD, C.SWSP, C.SDSP
#   i/tests.S         - RV64I base-ISA suite orchestrator; defines
#                       run_i_tests, calls each i/*.S file's
#                       tests_i_* entry point.
#   i/loads.S         - LB, LH, LW, LD, LBU, LHU, LWU
#   i/stores.S        - SB, SH, SW, SD
#   i/lui.S           - LUI
#   i/auipc.S         - AUIPC
#   i/jal.S           - JAL
#   i/jalr.S          - JALR
#   i/branches.S      - BEQ, BNE, BLT, BGE, BLTU, BGEU
#   i/op_alu.S        - ADD, SUB, SLL, SLT, SLTU, XOR, SRL, SRA, OR, AND
#   i/op_imm.S        - ADDI, SLTI, SLTIU, XORI, ORI, ANDI, SLLI, SRLI, SRAI
#   i/op_imm32.S      - ADDIW, SLLIW, SRLIW, SRAIW (RV64-only)
#   i/op_alu32.S      - ADDW, SUBW, SLLW, SRLW, SRAW (RV64-only)
#   i/system.S        - ECALL, EBREAK
#   i/fence.S         - FENCE (incl. FENCE.TSO, PAUSE)
#   m/tests.S         - RV64M suite orchestrator; defines run_m_tests,
#                       calls tests_m_mul/tests_m_div
#   m/mul.S           - MUL, MULH, MULHSU, MULHU, MULW
#   m/div.S           - DIV, DIVU, REM, REMU, DIVW, DIVUW, REMW, REMUW
#   a/tests.S         - RV64A suite orchestrator; defines run_a_tests,
#                       calls tests_a_amo/tests_a_lrsc
#   a/amo.S           - AMOSWAP, AMOADD, AMOXOR, AMOAND, AMOOR, AMOMIN,
#                       AMOMAX, AMOMINU, AMOMAXU (.W and .D)
#   a/lrsc.S          - LR, SC (.W and .D)
#   zicsr/tests.S     - Zicsr suite orchestrator; defines
#                       run_zicsr_tests, calls tests_zicsr_reg/
#                       tests_zicsr_imm
#   zicsr/reg.S       - CSRRW, CSRRS, CSRRC
#   zicsr/imm.S       - CSRRWI, CSRRSI, CSRRCI
#   zifencei/tests.S  - Zifencei suite orchestrator; defines
#                       run_zifencei_tests, calls tests_zifencei_fencei
#   zifencei/fencei.S - FENCE.I
#   zicboz/tests.S    - Zicboz suite orchestrator; defines
#                       run_zicboz_tests, calls tests_zicboz_cbozero
#   zicboz/cbozero.S  - CBO.ZERO
#   zabha/tests.S     - Zabha suite orchestrator; defines
#                       run_zabha_tests, calls tests_zabha_amo
#   zabha/amo.S       - AMOSWAP, AMOADD, AMOXOR, AMOAND, AMOOR, AMOMIN,
#                       AMOMAX, AMOMINU, AMOMAXU (.B and .H)
#   priv/tests.S      - privileged suite orchestrator; defines
#                       run_priv_tests, calls tests_priv_mret/
#                       tests_priv_wfi/tests_priv_csrpriv/
#                       tests_priv_irqpriv/tests_priv_mstatus
#   priv/mret.S       - MRET
#   priv/wfi.S        - WFI
#   priv/csrpriv.S    - M-mode CSRs accessed from U-mode
#   priv/irqpriv.S    - M-mode interrupts while in U-mode; vectored
#                       mtvec, interrupt priority
#   priv/mstatus.S    - mstatus MPP/UXL legality, misa.U, trap-entry
#                       stack from U-mode
#   xlen.inc          - the RV64/RV32 switch every file includes first
#   harness.inc       - TEST_BEGIN, which prints a test's name before it
#                       runs, and the TRAP_* macros for tests that trap
#                       on purpose; .include'd by every category file
#   bitx.S            - run-time counting sled for the control-transfer
#                       bit-independence tests (not a suite itself)
#   bitx.inc          - macros for the bit-independence tests every
#                       category file .include's (hence a prerequisite of
#                       every suite object below)
#
# Future instruction-set suites (e.g. the F extension) can be added as
# their own file(s) defining run_yyy_tests, with one new line
# in main_tests.S to call it and its object file(s) added to
# SUITE_SRCS below -- see README.md.

CROSS   ?= riscv64-linux-gnu-
AS      = $(CROSS)as
LD      = $(CROSS)ld
OBJCOPY = $(CROSS)objcopy
OBJDUMP = $(CROSS)objdump

# Two images from the same sources, both built by default: RV64 and RV32.
# XLEN is passed to every file with --defsym; see xlen.inc for what
# depends on it. --fatal-warnings because an assembler truncation warning
# means a test value silently changed meaning.
ARCH64  = rv64imac_zicsr_zifencei_zicboz_zabha
ABI64   = lp64
EMU64   = elf64lriscv
QEMU64  = qemu-system-riscv64
ARCH32  = rv32imac_zicsr_zifencei_zicboz_zabha
ABI32   = ilp32
EMU32   = elf32lriscv
QEMU32  = qemu-system-riscv32
# QEMU's rv64/rv32 CPUs leave Zabha off by default; without it every
# Zabha check FAILs (it traps; see README
# "Unimplemented instructions fail, they don't hang").
QCPU64  = rv64,zabha=true
QCPU32  = rv32,zabha=true
# All sources live under SRC_DIR. -I $(SRC_DIR): the category files sit
# in subdirectories (c/, i/, m/, a/, zicsr/, zifencei/, zicboz/, zabha/,
# priv/) but .include the shared xlen.inc/harness.inc/bitx.inc
# from SRC_DIR itself.
SRC_DIR = src
ASFLAGS = --fatal-warnings -I $(SRC_DIR)

BUILD_DIR   = build

# Source paths below are relative to SRC_DIR.
# common.S must stay first: it goes first on the link line so _start
# lands at the very base of .text, i.e. at the 0x80000000 load address.
COMMON_SRC  = common.S
SUITE_SRCS  = main_tests.S c/tests.S c/quadrant0.S c/quadrant1.S c/quadrant2.S \
              i/tests.S i/loads.S i/stores.S i/lui.S i/auipc.S i/jal.S i/jalr.S i/branches.S i/op_alu.S i/op_imm.S i/op_imm32.S i/op_alu32.S i/system.S i/fence.S \
              m/tests.S m/mul.S m/div.S \
              a/tests.S a/amo.S a/lrsc.S \
              zicsr/tests.S zicsr/reg.S zicsr/imm.S \
              zifencei/tests.S zifencei/fencei.S \
              zicboz/tests.S zicboz/cbozero.S \
              zabha/tests.S zabha/amo.S \
              priv/tests.S priv/mret.S priv/wfi.S priv/csrpriv.S priv/irqpriv.S priv/mstatus.S \
              bitx.S
SRCS        = $(COMMON_SRC) $(SUITE_SRCS)
INCS        = $(addprefix $(SRC_DIR)/,xlen.inc harness.inc bitx.inc)

OBJS64      = $(addprefix $(BUILD_DIR)/rv64/,$(SRCS:.S=.o))
OBJS32      = $(addprefix $(BUILD_DIR)/rv32/,$(SRCS:.S=.o))
OUT64       = $(BUILD_DIR)/rv64/rv_tests
OUT32       = $(BUILD_DIR)/rv32/rv_tests

all: $(OUT64).bin $(OUT32).bin

# Objects mirror the tree under SRC_DIR (src/c/tests.S ->
# build/rv64/c/tests.o, ...), so the
# suites' same-named files (tests.S) don't collide; each rule
# creates its object's directory first.
$(BUILD_DIR)/rv64/%.o: $(SRC_DIR)/%.S $(INCS)
	@mkdir -p $(@D)
	$(AS) -march=$(ARCH64) -mabi=$(ABI64) --defsym XLEN=64 $(ASFLAGS) -o $@ $<

$(BUILD_DIR)/rv32/%.o: $(SRC_DIR)/%.S $(INCS)
	@mkdir -p $(@D)
	$(AS) -march=$(ARCH32) -mabi=$(ABI32) --defsym XLEN=32 $(ASFLAGS) -o $@ $<

$(OUT64).elf: $(OBJS64)
	$(LD) -m $(EMU64) -Ttext=0x80000000 --no-dynamic-linker -nostdlib -o $@ $(OBJS64)

$(OUT32).elf: $(OBJS32)
	$(LD) -m $(EMU32) -Ttext=0x80000000 --no-dynamic-linker -nostdlib -o $@ $(OBJS32)

$(OUT64).bin: $(OUT64).elf
	$(OBJCOPY) -O binary $< $@

$(OUT32).bin: $(OUT32).elf
	$(OBJCOPY) -O binary $< $@

disasm: disasm64
disasm64: $(OUT64).elf
	$(OBJDUMP) -d -M no-aliases $< | less
disasm32: $(OUT32).elf
	$(OBJDUMP) -d -M no-aliases $< | less

# Run under QEMU's virt machine, which happens to match the memory map
# this program assumes on both widths: RAM at 0x80000000, ns16550a UART
# at 0x10000000, and -bios none boots straight into M-mode at
# 0x80000000. "run" runs RV64 then RV32 (Ctrl-A X leaves each).
run: run64 run32
run64: $(OUT64).elf
	$(QEMU64) -M virt -bios none -cpu $(QCPU64) -kernel $< -nographic -serial mon:stdio
run32: $(OUT32).elf
	$(QEMU32) -M virt -bios none -cpu $(QCPU32) -kernel $< -nographic -serial mon:stdio

clean:
	rm -rf $(BUILD_DIR)

.PHONY: all run run64 run32 disasm disasm64 disasm32 clean
