# Makefile for the RVC test firmware
#
# Requires a riscv64 GNU binutils/gcc toolchain. On Debian/Ubuntu:
#   sudo apt-get install binutils-riscv64-linux-gnu
# (a bare-metal riscv64-unknown-elf- toolchain works too; just adjust
# CROSS below)
#
# Builds two images from the same sources: build/rv64/rvc_test.{elf,bin}
# (RV64IMAC) and build/rv32/rvc_test.{elf,bin} (RV32IMAC). All build
# outputs (object files, the linked ELFs, and the flat binaries) are
# placed under BUILD_DIR (default: build/), which is created
# automatically if it doesn't exist; object files mirror the source tree
# (src/rvc/tests.S -> build/rv64/rvc/tests.o, ...). All sources live
# under SRC_DIR (default: src/): the shared harness and include files
# directly in it, and each suite's files in its own subdirectory
# (rvc/, base/, m/). The paths below are relative to src/.
#
# Source layout (under src/):
#   common.S         - reusable boot/UART/reporter harness, suite-agnostic.
#                       Provides _start and expects a "run_tests" symbol
#                       from whichever test-suite object is linked in.
#   main_tests.S      - top-level dispatcher; defines run_tests, calls
#                       each suite's own entry point in turn.
#   rvc/tests.S       - RVC suite orchestrator; defines run_rvc_tests,
#                       calls tests_quadrant0/1/2.
#   rvc/quadrant0.S   - C.ADDI4SPN, C.LW, C.SW, C.LD, C.SD
#   rvc/quadrant1.S   - C.NOP, C.ADDI, C.ADDIW, C.LI, C.ADDI16SP, C.LUI,
#                       C.SRLI, C.SRAI, C.ANDI, C.SUB, C.XOR, C.OR,
#                       C.AND, C.SUBW, C.ADDW, C.J, C.BEQZ, C.BNEZ
#   rvc/quadrant2.S   - C.SLLI, C.LWSP, C.LDSP, C.JR, C.MV, C.EBREAK,
#                       C.JALR, C.ADD, C.SWSP, C.SDSP
#   base/tests.S      - RV64I base-ISA suite orchestrator; defines
#                       run_base_tests, calls each base/*.S file's
#                       tests_base_* entry point.
#   base/loads.S      - LB, LH, LW, LD, LBU, LHU, LWU
#   base/stores.S     - SB, SH, SW, SD
#   base/lui.S        - LUI
#   base/auipc.S      - AUIPC
#   base/jal.S        - JAL
#   base/jalr.S       - JALR
#   base/branches.S   - BEQ, BNE, BLT, BGE, BLTU, BGEU
#   base/op_alu.S     - ADD, SUB, SLL, SLT, SLTU, XOR, SRL, SRA, OR, AND
#   base/op_imm.S     - ADDI, SLTI, SLTIU, XORI, ORI, ANDI, SLLI, SRLI, SRAI
#   base/op_imm32.S   - ADDIW, SLLIW, SRLIW, SRAIW (RV64-only)
#   base/op_alu32.S   - ADDW, SUBW, SLLW, SRLW, SRAW (RV64-only)
#   m/tests.S         - RV64M suite orchestrator; defines run_m_tests,
#                       calls tests_m_mul/tests_m_div
#   m/mul.S           - MUL, MULH, MULHSU, MULHU, MULW
#   m/div.S           - DIV, DIVU, REM, REMU, DIVW, DIVUW, REMW, REMUW
#   xlen.inc          - the RV64/RV32 switch every file includes first
#   bitx.S            - run-time counting sled for the control-transfer
#                       bit-independence tests (not a suite itself)
#   bitx.inc          - macros for the bit-independence tests every
#                       category file .include's (hence a prerequisite of
#                       every suite object below)
#
# Future instruction-set suites (e.g. an "A" extension test) can be
# added as their own file(s) defining run_yyy_tests, with one new line
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
ARCH64  = rv64imac_zicsr_zifencei
ABI64   = lp64
EMU64   = elf64lriscv
QEMU64  = qemu-system-riscv64
ARCH32  = rv32imac_zicsr_zifencei
ABI32   = ilp32
EMU32   = elf32lriscv
QEMU32  = qemu-system-riscv32
# All sources live under SRC_DIR. -I $(SRC_DIR): the category files sit
# in subdirectories (rvc/, base/, m/) but .include the shared
# xlen.inc/bitx.inc from SRC_DIR itself.
SRC_DIR = src
ASFLAGS = --fatal-warnings -I $(SRC_DIR)

BUILD_DIR   = build

# Source paths below are relative to SRC_DIR.
# common.S must stay first: it goes first on the link line so _start
# lands at the very base of .text, i.e. at the 0x80000000 load address.
COMMON_SRC  = common.S
SUITE_SRCS  = main_tests.S rvc/tests.S rvc/quadrant0.S rvc/quadrant1.S rvc/quadrant2.S \
              base/tests.S base/loads.S base/stores.S base/lui.S base/auipc.S base/jal.S base/jalr.S base/branches.S base/op_alu.S base/op_imm.S base/op_imm32.S base/op_alu32.S \
              m/tests.S m/mul.S m/div.S \
              bitx.S
SRCS        = $(COMMON_SRC) $(SUITE_SRCS)
INCS        = $(addprefix $(SRC_DIR)/,xlen.inc bitx.inc)

OBJS64      = $(addprefix $(BUILD_DIR)/rv64/,$(SRCS:.S=.o))
OBJS32      = $(addprefix $(BUILD_DIR)/rv32/,$(SRCS:.S=.o))
OUT64       = $(BUILD_DIR)/rv64/rvc_test
OUT32       = $(BUILD_DIR)/rv32/rvc_test

all: $(OUT64).bin $(OUT32).bin

# Objects mirror the tree under SRC_DIR (src/rvc/tests.S ->
# build/rv64/rvc/tests.o, ...), so the
# three suites' same-named files (tests.S) don't collide; each rule
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
	$(QEMU64) -M virt -bios none -kernel $< -nographic -serial mon:stdio
run32: $(OUT32).elf
	$(QEMU32) -M virt -bios none -kernel $< -nographic -serial mon:stdio

clean:
	rm -rf $(BUILD_DIR)

.PHONY: all run run64 run32 disasm disasm64 disasm32 clean
