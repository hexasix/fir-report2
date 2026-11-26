IVERILOG ?= iverilog
VVP ?= vvp
VERILATOR ?= verilator
SEED ?= 48230002
RANDOM_SAMPLES ?= 10000
POWER_SAMPLES ?= 1000
RTL := rtl/fir_alu.v
TB := tb/tb_fir_alu.v
COMPILE_PROFILE ?= baseline
ifeq ($(COMPILE_PROFILE),pipeline)
RTL_FLAGS := -DFIR_ALU_PIPELINED
TB_FLAGS := -Ptb_fir_alu.LAST_GROUP_LATENCY=9
endif
SIM := build/alu_$(COMPILE_PROFILE)_$(RANDOM_SAMPLES).vvp

.PHONY: test vcd activity lint course

test: $(SIM)
	$(VVP) $(SIM) +SEED=$(SEED)

vcd: $(SIM)
	cd build && $(VVP) $(notdir $(SIM)) +SEED=$(SEED) +vcd

activity: $(SIM)
	mkdir -p build/activity
	cd build/activity && $(VVP) ../$(notdir $(SIM)) +SEED=$(SEED) +power +POWER_SAMPLES=$(POWER_SAMPLES)

course:
	bash flow/run_course.sh

lint:
	$(IVERILOG) -g2005 -Wall $(RTL_FLAGS) -t null -s fir_alu $(RTL)
	$(VERILATOR) --lint-only -Wall $(RTL_FLAGS) --language 1364-2005 --top-module fir_alu $(RTL)

$(SIM): $(RTL) $(TB)
	mkdir -p build
	$(IVERILOG) -g2012 -Wall $(RTL_FLAGS) $(TB_FLAGS) -s tb_fir_alu -Ptb_fir_alu.RANDOM_SAMPLES=$(RANDOM_SAMPLES) -o $@ $^
