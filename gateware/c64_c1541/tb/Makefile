TOPLEVEL_LANG = verilog

SIM ?= verilator

VERILOG_SOURCES += $(PWD)/../c1541_gcr.v
VERILOG_SOURCES += $(PWD)/c1541_gcr_tb_top.v

CUSTOM_COMPILE_DEPS += $(PWD)/../mem/gcr_lut.mem

TOPLEVEL = c1541_gcr_tb_top

MODULE = test_c1541_gcr

EXTRA_ARGS += --trace --trace-structs
EXTRA_ARGS += -Wno-fatal

include $(shell cocotb-config --makefiles)/Makefile.sim

clean::
	rm -rf __pycache__
	rm -rf results.xml
	rm -rf sim_build
	rm -f *.vcd
	rm -f *.fst
	rm -f dump.fst
