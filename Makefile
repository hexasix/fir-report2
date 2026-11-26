IVERILOG ?= iverilog
VVP ?= vvp
VERILATOR ?= verilator
SEED ?= 48230002
RANDOM_SAMPLES ?= 10000
POWER_SAMPLES ?= 1000
RTL := rtl/fir_alu.v
TB := tb/tb_fir_alu.v
SIM := build/alu_$(RANDOM_SAMPLES).vvp

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
	$(IVERILOG) -g2005 -Wall -t null -s fir_alu $(RTL)
	$(VERILATOR) --lint-only -Wall --language 1364-2005 --top-module fir_alu $(RTL)

$(SIM): $(RTL) $(TB)
	mkdir -p build
	$(IVERILOG) -g2012 -Wall -s tb_fir_alu -Ptb_fir_alu.RANDOM_SAMPLES=$(RANDOM_SAMPLES) -o $@ $^
