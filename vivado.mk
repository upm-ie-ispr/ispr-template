PRJ_DIR?=project
TUT_DIR?=$(shell dirname $(PWD))
FPGA_TOP?=$(shell basename $(TUT_DIR))
TOP_NAME?=system_wrapper

PLATFORM_NAME=system_wrapper
OS_NAME?=standalone
CPU_NAME?=ps7_cortexa9_0
DOMAIN_NAME=$(OS_NAME)_$(CPU_NAME)
APP_NAME=$(FPGA_TOP)

.PHONY: clean prj bit xsa app
bit: $(FPGA_TOP).bit
prj: create_project.tcl
	if test ! -r "$(PRJ_DIR)/$(FPGA_TOP).xpr"; then \
		vivado -nojournal -nolog -mode batch -source create_project.tcl -tclargs --project_name $(FPGA_TOP); \
	fi
	
xsa: $(FPGA_TOP).bit $(FPGA_TOP).xsa

clean:
	rm -rf $(PRJ_DIR)
	rm -rf .Xil
	rm -rf workspace
	rm -rf NA/
	rm -rf *.bit *.log *.jou *.str
	rm -rf run_synth.tcl run_impl.tcl generate_bit.tcl generate_xsa.tcl

$(PRJ_DIR)/$(FPGA_TOP).xpr: create_project.tcl
	vivado -nojournal -nolog -mode batch -source create_project.tcl -tclargs --project_name $(FPGA_TOP)

#run_synth.tcl: $(PRJ_DIR)/$(FPGA_TOP).xpr
run_synth.tcl:
	echo "open_project $(PRJ_DIR)/$(FPGA_TOP).xpr" > $@
	echo "reset_run synth_1" >> $@
	echo "launch_runs -jobs 4 synth_1" >> $@
	echo "wait_on_run synth_1" >> $@

# synthesis run
$(PRJ_DIR)/$(FPGA_TOP).runs/synth_1/$(TOP_NAME).dcp: create_project.tcl run_synth.tcl
	if test ! -r "$(PRJ_DIR)/$(FPGA_TOP).xpr"; then \
		vivado -nojournal -nolog -mode batch -source create_project.tcl -tclargs --project_name $(FPGA_TOP); \
	fi
	vivado -nojournal -nolog -mode batch -source run_synth.tcl

run_impl.tcl: 
	echo "open_project $(PRJ_DIR)/$(FPGA_TOP).xpr" > $@
	echo "reset_run impl_1" >> $@
	echo "launch_runs -jobs 4 impl_1" >> $@
	echo "wait_on_run impl_1" >> $@

# implementation run
$(PRJ_DIR)/$(FPGA_TOP).runs/impl_1/$(TOP_NAME)_routed.dcp: $(PRJ_DIR)/$(FPGA_TOP).runs/synth_1/$(TOP_NAME).dcp run_impl.tcl
	vivado -nojournal -nolog -mode batch -source run_impl.tcl

generate_bit.tcl: 
	echo "open_project $(PRJ_DIR)/$(FPGA_TOP).xpr" > $@
	echo "open_run impl_1" >> $@
	echo "write_bitstream -force $(PRJ_DIR)/$(FPGA_TOP).runs/impl_1/$(TOP_NAME).bit" >> $@

# bit file
$(PRJ_DIR)/$(FPGA_TOP).runs/impl_1/$(TOP_NAME).bit: $(PRJ_DIR)/$(FPGA_TOP).runs/impl_1/$(TOP_NAME)_routed.dcp generate_bit.tcl
	vivado -nojournal -nolog -mode batch -source generate_bit.tcl

$(FPGA_TOP).bit: $(PRJ_DIR)/$(FPGA_TOP).runs/impl_1/$(TOP_NAME).bit
	cp $< $@
	mkdir -p rev
	EXT=bit; COUNT=100; \
	while [ -e rev/$*_rev$$COUNT.$$EXT ]; \
	do COUNT=$$((COUNT+1)); done; \
	cp $@ rev/$(FPGA_TOP)_rev$$COUNT.$$EXT; \
	echo "Output: rev/$(FPGA_TOP)_rev$$COUNT.$$EXT";

generate_xsa.tcl: 
	echo "open_project $(PRJ_DIR)/$(FPGA_TOP).xpr" > $@
	echo "write_hw_platform -fixed -include_bit -force -file $(FPGA_TOP).xsa" >> $@

#xsa file
$(FPGA_TOP).xsa: $(FPGA_TOP).bit generate_xsa.tcl
	vivado -nojournal -nolog -mode batch -source generate_xsa.tcl

../hw/$(FPGA_TOP).xsa: 
	make -C ../hw xsa

app: ../hw/$(FPGA_TOP).xsa
	vitis -s ../../../vitis_builder.py $(PLATFORM_NAME) ../hw/$(FPGA_TOP).xsa $(OS_NAME) $(CPU_NAME) $(APP_NAME)
