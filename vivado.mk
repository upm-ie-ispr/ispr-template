# --- COLOR DEFINITIONS ---
ESC    := $(shell printf '\033')
# Text styles
BOLD   := $(ESC)[1m
DIM    := $(ESC)[2m
ITALIC := $(ESC)[3m
# Foreground colors
RESET  := $(ESC)[0m
RED    := $(ESC)[31m
GREEN  := $(ESC)[32m
YELLOW := $(ESC)[33m
BLUE   := $(ESC)[34m
MAGENTA:= $(ESC)[35m
CYAN   := $(ESC)[36m
WHITE  := $(ESC)[37m
# --- STATUS PREFIXES ---
LOG_INFO    := printf '%s%s\n' "$(BLUE)[INFO]$(RESET) "
LOG_SUCCESS := printf '%s%s\n' "$(GREEN)[SUCCESS]$(RESET) "
LOG_WARNING := printf '%s%s\n' "$(YELLOW)[WARN]$(RESET) "
LOG_ERROR   := printf '%s%s\n' "$(RED)[ERROR]$(RESET) "

# --- PROJECT CONFIGURATION ---

PRJ_DIR  ?= project
TUT_DIR  ?= $(patsubst %/,%,$(dir $(CURDIR)))
FPGA_TOP ?= $(notdir $(patsubst %/,%,$(dir $(CURDIR))))
TOP_NAME ?= system_wrapper
CREATE_PROJECT_FILE ?= create_project.tcl


PLATFORM_NAME  ?= system_wrapper
WORKSPACE_NAME ?= workspace
OS_NAME        ?= standalone
CPU_NAMES      ?= ps7_cortexa9_0 ps7_cortexa9_1
# one app per CPU: <top>-cpu<N>
APP_NAMES      := $(shell i=0; for c in $(CPU_NAMES); do echo $(FPGA_TOP)-cpu$$i; i=$$((i+1)); done)

ifeq ($(OS),Windows_NT)
    VITIS := cmd //c vitis
	UNZIP := cmd //c unzip
else
    VITIS := vitis
	UNZIP := unzip
endif

.PHONY: prj bit xsa hw_clean open_with_probes check_create_project # more below

# ---
# HW 
# ---
define HW_VALIDATE
	if [ "$$(basename $(CURDIR))" != "hw" ]; then \
		$(LOG_ERROR) "This target must be run from the 'hw' directory (currently in: $(CURDIR))."; \
		exit 1; \
	fi
endef

hw_clean:
	@$(LOG_INFO) "Cleaning hardware build artifacts..."
	@$(HW_VALIDATE)
	@rm -rf $(PRJ_DIR)
	@rm -rf .Xil
	@rm -rf NA/
	@rm -rf *.bit *.log *.jou *.str *.xsa
	@rm -rf run_synth.tcl run_impl.tcl generate_bit.tcl generate_xsa.tcl init_prj.tcl add_probes.tcl
	@$(LOG_SUCCESS) "Hardware build artifacts cleaned."

# project creation/initialization
init_prj.tcl:
	@$(LOG_INFO) "Creating Vivado project initialization script..."
# re-opens and forces validation since it is required to propagate and calculate the ILA port widths
	@echo "open_project $(PRJ_DIR)/$(FPGA_TOP).xpr" > $@
	@echo "set prj_dir   [get_property DIRECTORY [current_project]]" >> $@
	@echo "set prj_name  [get_property NAME      [current_project]]" >> $@
	@echo "update_compile_order -fileset sources_1" >> $@
	@echo "set bd_file [lindex [get_files *.bd] 0]" >> $@
	@echo "open_bd_design \$$bd_file" >> $@
	@echo "validate_bd_design -force" >> $@
	@echo "save_bd_design" >> $@
# cleans and generates ALL simulation/synthesis targets natively
	@echo "reset_target all \$$bd_file" >> $@
	@echo "generate_target {synthesis simulation} \$$bd_file" >> $@
	@echo "export_ip_user_files -of_objects \$$bd_file -no_script -sync -force" >> $@
# creates and launches OOC IP synthesis runs (skip already-complete)
	@echo "create_ip_run [get_files \$$bd_file]" >> $@
	@echo "foreach run [get_runs -filter {IS_SYNTHESIS == 1 && IS_OUT_OF_CONTEXT == 1 && STATUS != {synth_design Complete!}}] {" >> $@
	@echo "  launch_runs \$$run" >> $@
	@echo "  wait_on_run \$$run" >> $@
	@echo "}" >> $@
# generates HDL wrapper and set as top
	@echo "make_wrapper -files \$$bd_file -top" >> $@
	@echo "set wrapper_file [lindex [get_files *_wrapper.v] 0]" >> $@
	@echo "add_files -norecurse \$$wrapper_file" >> $@
	@echo "set_property top [file rootname [file tail \$$wrapper_file]] [current_fileset]" >> $@
	@echo "update_compile_order -fileset sources_1" >> $@
# simulates only if sim_1 fileset exists and has sources (e.g. a testbench)
	@echo "set sim_filesets [get_filesets -filter {FILESET_TYPE == SimulationSrcs}]" >> $@
	@echo "if {[llength \$$sim_filesets] > 0 && [llength [get_files -of_objects [get_filesets sim_1]]] > 0} {" >> $@
# checks if DB and wrapper are linked to the simuation scopre
	@echo "  set bd_asset [get_files -quiet system.bd]" >> $@
	@echo "  set wrapper_asset [get_files -quiet system_wrapper.v]" >> $@
# if not found inside the active session context, search disk files and link them
	@echo "  if {\$$bd_asset eq \"\"} {" >> $@
	@echo "    set bd_file [lindex [get_files -quiet *.bd] 0]" >> $@
	@echo "    if {\$$bd_file ne \"\" && [llength [get_files -of_objects [get_filesets sim_1] [file tail \$$bd_file]]] == 0} {" >> $@
	@echo "      add_files -fileset sim_1 -norecurse \$$bd_file" >> $@
	@echo "    }" >> $@
	@echo "  }" >> $@
	@echo "  if {\$$wrapper_asset eq \"\"} {" >> $@
	@echo "    set wrapper_file [lindex [get_files -quiet *_wrapper.v] 0]" >> $@
	@echo "    if {\$$wrapper_file ne \"\" && [llength [get_files -of_objects [get_filesets sim_1] [file tail \$$wrapper_file]]] == 0} {" >> $@
	@echo "      add_files -fileset sim_1 -norecurse \$$wrapper_file" >> $@
	@echo "    }" >> $@
	@echo "  }" >> $@
# sets simulation top and launches
	@echo "  set_property top     tb             [get_filesets sim_1]" >> $@
	@echo "  set_property top_lib xil_defaultlib [get_filesets sim_1]" >> $@
	@echo "  update_compile_order -fileset sim_1" >> $@
	@echo "  launch_simulation" >> $@
	@echo "  run all" >> $@
	@echo "  close_sim" >> $@
	@echo "} else {" >> $@
	@echo "  puts \"No simulation sources found - skipping simulation\"" >> $@
	@echo "}" >> $@
	@echo "close_project" >> $@
	@$(LOG_SUCCESS) "Vivado project initialization script created."

$(PRJ_DIR)/$(FPGA_TOP).xpr: $(CREATE_PROJECT_FILE)
	@$(HW_VALIDATE)
	vivado -nojournal -nolog -mode batch -source $(CREATE_PROJECT_FILE) -tclargs --project_name $(FPGA_TOP)

$(PRJ_DIR)/.initialized_sentinel: init_prj.tcl | $(PRJ_DIR)/$(FPGA_TOP).xpr
	vivado -nojournal -nolog -mode batch -source init_prj.tcl
	touch $@

prj: $(PRJ_DIR)/.initialized_sentinel

# checks create_project.tcl vailidity
check_create_project:
	@$(HW_VALIDATE); \
	fix() { \
		read -p "       Would you like to automatically apply this fix? (y/N): " answer; \
		if [ "$$answer" = "y" ] || [ "$$answer" = "Y" ]; then \
			$(LOG_INFO) "       -> fixing"; \
			sh -c "$$1"; \
			return 0; \
		else \
			$(LOG_WARNING) "       -> skipped fix"; \
			return 1; \
		fi; \
	}; \
	error=0; \
	\
	# check: there is tcl script \
	if [ ! -e "$(CREATE_PROJECT_FILE)" ]; then \
		$(LOG_ERROR) "Missing $(CREATE_PROJECT_FILE) file"; \
		exit 1; \
	fi; \
	\
	# check: recreate block design is checked \
	grep -q '$(FPGA_TOP)\.srcs/sources_1/bd/system/system\.bd' "$(CREATE_PROJECT_FILE)" && { \
		$(LOG_ERROR) "Found reference to generated Block Design:"; \
		echo "        $(FPGA_TOP).srcs/sources_1/bd/system/system.bd"; \
		echo "        Did you forget to enable 'Recreate Block Design'?"; \
		error=1; \
	}; \
	\
	# check: project would be inside a folder named project instead the project name \
	grep -q 'create_project $${_xil_proj_name_} \./$${_xil_proj_name_} -part' "$(CREATE_PROJECT_FILE)" && { \
		$(LOG_WARNING) "create_project uses ./\$${_xil_proj_name_}"; \
		echo "       It should use ./project instead."; \
		if fix 'sed -Ei "/^create_project / s|\\./\\\$$\\{_xil_proj_name_\\}|./project|" "$(CREATE_PROJECT_FILE)"'; then \
			$(LOG_INFO) "       Applied fix for project directory path."; \
		else \
			error=1; \
		fi; \
	}; \
	\
	# check: FPGA_TOP only appears in allowed locations. \
	bad_lines=$$( \
		sed -E '/^[[:space:]]*#/d; /^[[:space:]]*set[[:space:]]+_xil_proj_name_[[:space:]]+"$(FPGA_TOP)"[[:space:]]*$$/d' \
			"$(CREATE_PROJECT_FILE)" | \
		grep -n '$(FPGA_TOP)' | \
		sed 's/^/        /' \
	); \
	if [ -n "$$bad_lines" ]; then \
		$(LOG_WARNING) "Unexpected occurrence(s) of '$(FPGA_TOP)':"; \
		$(LOG_INFO) "$$bad_lines"; \
		if fix 'sed -Ei -e "/^[[:space:]]*#/b" -e "/set[[:space:]]+_xil_proj_name_/b" -e "s|$(FPGA_TOP)|\\$$\\{_xil_proj_name_\\}|g" "$(CREATE_PROJECT_FILE)"'; then \
			$(LOG_INFO) "       Applied fix for variable substitution."; \
		else \
			error=1; \
		fi; \
	fi; \
	\
	# check: "project/" precedes $(FPGA_TOP).gen. \
	if grep -q '$(FPGA_TOP)\.gen/sources_1/bd/system/hdl/system_wrapper\.v' "$(CREATE_PROJECT_FILE)" && \
	   ! grep -q 'project/$(FPGA_TOP)\.gen/sources_1/bd/system/hdl/system_wrapper\.v' "$(CREATE_PROJECT_FILE)"; then \
		$(LOG_ERROR) "Missing 'project/' before '$(FPGA_TOP).gen'."; \
		error=1; \
	fi; \
	\
	# check: no incremental checkpoint \
	if bad_line=$$(grep -nF 'set_property -name "incremental_checkpoint"' "$(CREATE_PROJECT_FILE)"); then \
		$(LOG_WARNING) "Incremental checkpoint export detected:"; \
		echo "       $$bad_line"; \
		echo "       Remove incremental checkpoint export from create_project.tcl:"; \
		echo "       set_property -name \"incremental_checkpoint\" ..."; \
		if fix 'sed -i "/set_property -name \"incremental_checkpoint\"/d" "$(CREATE_PROJECT_FILE)"'; then \
			$(LOG_INFO) "       Applied fix removing incremental checkpoint."; \
		else \
			error=1; \
		fi; \
	fi; \
	\
	# Check: no imported project files \
	if grep -q '^set imported_files' "$(CREATE_PROJECT_FILE)"; then \
		imported_files=$$( \
			sed -n '/^set files \[list \\/,/^set imported_files/p' "$(CREATE_PROJECT_FILE)" | \
			grep 'file normalize' | \
			sed -E 's|.*\/([^/"]+)".*|       - \1|' \
		); \
		$(LOG_WARNING) "There are files that are copied instead of referenced, This can result in lost modifications if not sync back manually to the repository. Files involved:"; \
		echo "$$imported_files"; \
		echo ""; \
		echo "       To resolve this issue, either:"; \
		echo "       - Uncheck 'Copy sources into project' in the Vivado GUI when adding files (and re-export this script), OR"; \
		echo "       - Edit $(CREATE_PROJECT_FILE) to replace 'lappend imported_files' blocks"; \
		echo "         with 'add_files -norecurse -fileset' blocks containing those files."; \
		error=1; \
	fi; \
	\
	if [ "$$error" -eq 0 ]; then \
		$(LOG_INFO) "       $(CREATE_PROJECT_FILE) validation passed."; \
	else \
		echo ""; \
		$(LOG_ERROR) "       $(CREATE_PROJECT_FILE) validation failed."; \
		exit 1; \
	fi

# synthesis run
run_synth.tcl:
	@echo "open_project $(PRJ_DIR)/$(FPGA_TOP).xpr" > $@
	@echo "reset_run synth_1" >> $@
	@echo "launch_runs -jobs 4 synth_1" >> $@
	@echo "wait_on_run synth_1" >> $@

$(PRJ_DIR)/$(FPGA_TOP).runs/synth_1/$(TOP_NAME).dcp: $(PRJ_DIR)/.initialized_sentinel run_synth.tcl
	vivado -nojournal -nolog -mode batch -source run_synth.tcl

# implementation run
run_impl.tcl: 
	@echo "open_project $(PRJ_DIR)/$(FPGA_TOP).xpr" > $@
	@echo "reset_run impl_1" >> $@
	@echo "launch_runs -jobs 4 impl_1" >> $@
	@echo "wait_on_run impl_1" >> $@

$(PRJ_DIR)/$(FPGA_TOP).runs/impl_1/$(TOP_NAME)_routed.dcp: $(PRJ_DIR)/$(FPGA_TOP).runs/synth_1/$(TOP_NAME).dcp run_impl.tcl
	vivado -nojournal -nolog -mode batch -source run_impl.tcl

PROBES_FILE ?= $(PRJ_DIR)/$(FPGA_TOP).runs/impl_1/debug_probes.ltx

# bit
generate_bit.tcl: 
	@echo "open_project $(PRJ_DIR)/$(FPGA_TOP).xpr" > $@
	@echo "open_run impl_1" >> $@
# write debug netlist only if there is an ila in the design
	@echo "if {[llength [get_debug_cores -quiet]] > 0} {" >> $@
	@echo "  write_debug_probes -force $(PROBES_FILE)" >> $@
	@echo "} else {" >> $@
	@echo "  puts \"No ila found - skipping writing debug hw probes\"" >> $@
	@echo "}" >> $@
	@echo "write_bitstream -force $(PRJ_DIR)/$(FPGA_TOP).runs/impl_1/$(TOP_NAME).bit" >> $@

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

bit: $(FPGA_TOP).bit

# xsa
generate_xsa.tcl: 
	@echo "open_project $(PRJ_DIR)/$(FPGA_TOP).xpr" > $@
	@echo "write_hw_platform -fixed -include_bit -force -file $(FPGA_TOP).xsa" >> $@

$(FPGA_TOP).xsa: $(FPGA_TOP).bit generate_xsa.tcl
	vivado -nojournal -nolog -mode batch -source generate_xsa.tcl

xsa: $(FPGA_TOP).xsa

# open with hw probes
add_probes.tcl:
	@echo "if {[catch {" > $@
	@echo "  open_project $(PRJ_DIR)/$(FPGA_TOP).xpr" >> $@
	@echo "  open_hw_manager" >> $@
	@echo "  connect_hw_server -url localhost:3121" >> $@
	@echo "  open_hw_target" >> $@
	@echo "  refresh_hw_device [current_hw_device]" >> $@
# ILA should be on the design so if not, no use of hw probes...
	@echo "  set ilas [get_hw_ilas -of_objects [current_hw_device]]" >> $@
	@echo "  if {[llength \$$ilas] == 0} {" >> $@
	@echo "    error \"ERROR: Not ila found, is it programmed?\"" >> $@
	@echo "	}" >> $@
	@echo "  set hw_probes_file \"$(PROBES_FILE)"" >> $@
	@echo "  if {\$$hw_probes_file eq \"\"} {" >> $@
	@echo "    error \"ERROR: Not debug hw probes found\"" >> $@
	@echo "	}" >> $@
	@echo "  set_property PROBES.FILE \$$hw_probes_file [current_hw_device]" >> $@
	@echo "  refresh_hw_device [current_hw_device]" >> $@
	@echo "} err]} {" >> $@
	@echo "  puts stderr \"\$$err\"" >> $@
	@echo "  puts \"INFO: Closing in 10s\"" >> $@
	@echo "  after 10000 {" >> $@
	@echo "    catch {close_project}" >> $@
	@echo "    catch {exit 1}" >> $@
	@echo "    catch {quit}" >> $@
	@echo "  }" >> $@
	@echo "}" >> $@

open_with_probes: add_probes.tcl
	@$(HW_VALIDATE)
	vivado -nojournal -nolog -mode gui -source add_probes.tcl

# ------------------------
# APP (cleans then builds)
# ------------------------
.PHONY: app app_clean check_ignored_changes

define SW_VALIDATE
	if [ "$$(basename $(CURDIR))" != "sw" ]; then \
		$(LOG_ERROR) "This target must be run from the 'sw' directory (currently in: $(CURDIR))"; \
		exit 1; \
	fi
endef

../hw/$(FPGA_TOP).xsa:
	@$(SW_VALIDATE)
	make -C ../hw xsa

app: ../hw/$(FPGA_TOP).xsa
	@$(SW_VALIDATE)
	@rm -rf .tmp_backup
	@mkdir -p .tmp_backup
	@for app in $(APP_NAMES); do \
		if [ -d "$(WORKSPACE_NAME)/$$app/src" ]; then \
			$(LOG_WARNING) "[$$app] Vitis source files found. Doing backup..."; \
			mkdir -p ".tmp_backup/$$app/src"; \
			cp -r "$(WORKSPACE_NAME)/$$app/src/." ".tmp_backup/$$app/src/" 2>/dev/null || true; \
		fi; \
		if [ -f "$(WORKSPACE_NAME)/$$app/_ide/launch.json" ]; then \
			$(LOG_WARNING) "[$$app] Vitis IDE files found. Doing backup..."; \
			mkdir -p ".tmp_backup/$$app/_ide"; \
			cp "$(WORKSPACE_NAME)/$$app/_ide/launch.json" ".tmp_backup/$$app/_ide/launch.json" 2>/dev/null || true; \
		fi; \
	done
	@if [ -f "$(WORKSPACE_NAME)/$(FPGA_TOP)/_ide/launch.json" ]; then \
		$(LOG_WARNING) "[$(FPGA_TOP)] System project launch config found. Doing backup..."; \
		mkdir -p ".tmp_backup/$(FPGA_TOP)/_ide"; \
		cp "$(WORKSPACE_NAME)/$(FPGA_TOP)/_ide/launch.json" ".tmp_backup/$(FPGA_TOP)/_ide/launch.json" 2>/dev/null || true; \
	fi
	@rm -rf $(WORKSPACE_NAME)
	@$(LOG_INFO) "Creating new Vitis workspace..."
	$(VITIS) -s ../../../vitis_builder.py --platform $(PLATFORM_NAME) --hw-design ../hw/$(FPGA_TOP).xsa --os $(OS_NAME) --cpus $(CPU_NAMES) --app-prefix $(FPGA_TOP) --workspace $(WORKSPACE_NAME)
	@for app in $(APP_NAMES); do \
		mkdir -p "$(WORKSPACE_NAME)/$$app/src"; \
		if [ -d ".tmp_backup/$$app/src" ] && [ "$$(ls -A ".tmp_backup/$$app/src")" ]; then \
			$(LOG_INFO) "[$$app] Restoring source files from backup..."; \
			cp -r ".tmp_backup/$$app/src/." "$(WORKSPACE_NAME)/$$app/src/" 2>/dev/null || true; \
			if [ ! -f ".tmp_backup/$$app/src/helloworld.c" ]; then \
				rm -f "$(WORKSPACE_NAME)/$$app/src/helloworld.c"; \
			fi; \
		fi; \
		if [ -f ".tmp_backup/$$app/_ide/launch.json" ]; then \
			$(LOG_INFO) "[$$app] Restoring IDE files from backup..."; \
			mkdir -p "$(WORKSPACE_NAME)/$$app/_ide"; \
			cp ".tmp_backup/$$app/_ide/launch.json" "$(WORKSPACE_NAME)/$$app/_ide/launch.json" 2>/dev/null || true; \
		fi; \
	done
	@if [ -f ".tmp_backup/$(FPGA_TOP)/_ide/launch.json" ]; then \
		$(LOG_INFO) "[$(FPGA_TOP)] Restoring system project launch config from backup..."; \
		mkdir -p "$(WORKSPACE_NAME)/$(FPGA_TOP)/_ide"; \
		cp ".tmp_backup/$(FPGA_TOP)/_ide/launch.json" "$(WORKSPACE_NAME)/$(FPGA_TOP)/_ide/launch.json" 2>/dev/null || true; \
	fi
	@rm -rf .tmp_backup
#	@$(LOG_INFO) "Cleaning helloworld build..."
#	$(MAKE) app_clean
	@touch .initialized_sentinel
	@$(LOG_SUCCESS) "App initialized."

# cannot delete more or ide cannot open the workspace	
app_clean:
	@$(SW_VALIDATE)
	rm -rf $(WORKSPACE_NAME)/$(FPGA_TOP)-*/build

# checks for changes in src (a file is considered changed if it is newer than the sentinel)
SW_SENTINEL    ?= .initialized_sentinel
SW_GITIGNORE   ?= .gitignore
SRC_DIRS       ?= $(wildcard $(WORKSPACE_NAME)/$(FPGA_TOP)-*/src)
EXCLUDED_FILES ?= app.yaml compile_commands.json CMakeLists.txt

check_changes:
	@$(SW_VALIDATE)
	@if [ ! -f $(SW_SENTINEL) ]; then \
		$(LOG_WARNING) "$(SW_SENTINEL) not found. The app may not have been created yet."; \
		exit 0; \
	fi
	@any_changes=0; \
	gitignore_modified=0; \
	if [ -n "$(SRC_DIRS)" ]; then \
		for f in $(addsuffix /*,$(SRC_DIRS)) $(addsuffix /**/*,$(SRC_DIRS)); do \
			skip_file=0; \
			for exc in $(EXCLUDED_FILES); do \
				basename_file=$$(basename "$$f"); \
				if [ "$$basename_file" = "$$exc" ]; then \
					skip_file=1; \
					$(LOG_INFO) "skipping $$exc"; \
					break; \
				fi; \
			done; \
			if [ $$skip_file -eq 1 ]; then \
				continue; \
			fi; \
			if [ -f "$$f" ] && [ "$$f" -nt "$(SW_SENTINEL)" ]; then \
				echo "--------------------------------------------------------"; \
				$(LOG_INFO) "Modified (or newer) file: $$f"; \
				\
				read -p "   Would you like to remove from gitignore and add to stage? (y/N): " answer; \
				\
				if [ "$$answer" = "y" ] || [ "$$answer" = "Y" ]; then \
					any_changes=1; \
					if [ -f $(SW_GITIGNORE) ]; then \
						basename_file=$$(basename "$$f"); \
						escaped_file=$$(echo "$$f" | sed 's/\//\\\//g'); \
						\
						# checks if listed in gitignore before remove it \
						if grep -q "$$basename_file" $(SW_GITIGNORE) || grep -q "$$escaped_file" $(SW_GITIGNORE); then \
							sed -i "/$$basename_file/d" $(SW_GITIGNORE); \
							sed -i "/$$escaped_file/d" $(SW_GITIGNORE); \
							gitignore_modified=1; \
							$(LOG_INFO) "   Removed from $(SW_GITIGNORE)"; \
						else \
							$(LOG_WARNING) "   File was not listed in $(SW_GITIGNORE). Please review change and update gitignore it if appropriate"; \
						fi; \
					fi; \
					git add -f "$$f"; \
					$(LOG_INFO) "   staged"; \
				else \
					$(LOG_INFO) "   skipped"; \
				fi; \
			fi; \
		done; \
	fi; \
	\
	if [ $$gitignore_modified -eq 1 ]; then \
		git add $(SW_GITIGNORE); \
		echo "--------------------------------------------------------"; \
		$(LOG_INFO) "Updated $(SW_GITIGNORE) and staged it"; \
	fi; \
	\
	if [ $$any_changes -eq 0 ]; then \
		$(LOG_INFO) "No eligible files in src were found after the sentinel"; \
	fi
# Sentinel file updated to prevent re-checking these files
	@touch $(SW_SENTINEL);

# -----------------------
# HLS (uses existing cfg)
# -----------------------
.PHONY: hls hls_export hls_unzip hls_clean

HLS_CFG        ?= hls_config.cfg
HLS_EXPORT_DIR ?= ../../../ip_repo
HLS_TCL        ?= run_hls.tcl

# Finds all directories one level down that contain the hls_config.cfg file and sorts them
HLS_SUBDIRS := $(patsubst %/$(HLS_CFG),%,$(sort $(wildcard */$(HLS_CFG))))

# if there is only one component and HLS_CHILD_DIR is not provided, assume that component as the target
ifeq ($(origin HLS_CHILD_DIR), undefined)
  ifeq ($(words $(HLS_SUBDIRS)),1)
    HLS_CHILD_DIR := $(firstword $(HLS_SUBDIRS))
  endif
endif

define HLS_VALIDATE
    if [ "$(words $(HLS_SUBDIRS))" -eq 0 ]; then \
        $(LOG_ERROR) "No directory containing $(HLS_CFG) found inside HLS workspace: $(CURDIR)."; \
        exit 1; \
    fi; \
    \
    CURRENT_CHILD="$(HLS_CHILD_DIR)"; \
    if [ -z "$$CURRENT_CHILD" ]; then \
        CURRENT_CHILD="$$HLS_CHILD_DIR"; \
    fi; \
    if [ -z "$$CURRENT_CHILD" ]; then \
        if [ "$(words $(HLS_SUBDIRS))" -eq 1 ]; then \
            CURRENT_CHILD="$(HLS_SUBDIRS)"; \
        else \
            $(LOG_INFO) "Multiple valid component directories found:"; \
            subdirs=($(HLS_SUBDIRS)); \
            i=1; \
            for d in "$${subdirs[@]}"; do \
                echo "  [$$i] $$d"; \
                i=$$((i+1)); \
            done; \
            read -p "Select a directory by number (or 'q' to quit): " choice; \
            if [[ "$$choice" =~ ^[0-9]+$$ ]] && [ "$$choice" -ge 1 ] && [ "$$choice" -le "$${#subdirs[@]}" ]; then \
                CURRENT_CHILD="$${subdirs[$$((choice-1))]}"; \
                $(LOG_INFO) "-> Selected HLS_CHILD_DIR=$$CURRENT_CHILD"; \
            else \
                $(LOG_ERROR) "Aborted or invalid choice."; \
                exit 1; \
            fi; \
        fi; \
    fi; \
    \
    export HLS_CHILD_DIR="$$CURRENT_CHILD"; \
    HLS_WORK_DIR="$$CURRENT_CHILD"; \
    HLS_CFG_PATH="$$HLS_WORK_DIR/$(HLS_CFG)"; \
    \
    if [ ! -f "$$HLS_CFG_PATH" ]; then \
        $(LOG_ERROR) "No config file found: $$HLS_CFG_PATH"; \
        exit 1; \
    fi
endef

VITIS_VERSION := $(shell vitis-run --version 2>&1 | sed -n 's/.*\([0-9]\{4\}\.[0-9]\).*/\1/p')
IS_2025_2     := $(filter 2025.2,$(VITIS_VERSION))

# default: hls_export + hls_unzip
hls: hls_unzip

# runs csynth+export via dynamic tcl generation
hls_export:
	@$(HLS_VALIDATE); \
	HLS_WORK_DIR="$$HLS_CHILD_DIR"; \
	HLS_CFG_PATH="$$HLS_WORK_DIR/$(HLS_CFG)"; \
	HLS_TCL_PATH="$$HLS_WORK_DIR/$(HLS_TCL)"; \
	\
	mkdir -p "$$HLS_WORK_DIR"; \
	cfg=$$HLS_CFG_PATH; \
	if [ "$(IS_2025_2)" = "2025.2" ]; then \
		$(LOG_INFO) "Doing backup of hls_config vitis (tweak 2025.2)"; \
		cp "$$HLS_CFG_PATH" "$$HLS_CFG_PATH.bak"; \
		cfg="$$HLS_CFG_PATH.bak"; \
	fi; \
	# generates a tcl script to allow vitis to regenerate and export the project \
	# in vitis 2025.2, a different configuration file name is required to prevent overwriting \
	echo "open_component $$HLS_WORK_DIR" > "$$HLS_TCL_PATH"; \
	echo "apply_ini $$cfg" >> "$$HLS_TCL_PATH"; \
	echo "csynth_design" >> "$$HLS_TCL_PATH"; \
	echo "export_design" >> "$$HLS_TCL_PATH"; \
	echo "exit" >> "$$HLS_TCL_PATH"; \
	\
	vitis-run --mode hls --tcl --work_dir "$$HLS_WORK_DIR" "$$HLS_TCL_PATH" || \
	(if [ "$(IS_2025_2)" = "2025.2" ]; then \
		$(LOG_INFO) "Restoring backup of hls_config"; \
		cp "$$HLS_CFG_PATH.bak" "$$HLS_CFG_PATH"; \
	fi; \
	exit 1)

# extracts (if needed) into ../ip_repo
hls_unzip:
	@$(HLS_VALIDATE); \
	HLS_WORK_DIR="$$HLS_CHILD_DIR"; \
	IP_ZIP=$$(ls "$$HLS_WORK_DIR"/hls/impl/ip/*.zip 2>/dev/null | head -n 1); \
	if [ -z "$$IP_ZIP" ]; then \
		$(LOG_WARNING) "No zip found, running hls_export..."; \
		$(MAKE) hls_export HLS_CHILD_DIR="$$HLS_CHILD_DIR"; \
		IP_ZIP=$$(ls "$$HLS_WORK_DIR"/hls/impl/ip/*.zip 2>/dev/null | head -n 1); \
	fi; \
	IP_NAME=$$(basename "$$IP_ZIP" .zip); \
	EXPORT_SUBDIR="$(strip $(HLS_EXPORT_DIR))/$$IP_NAME"; \
	if [ -d "$$EXPORT_SUBDIR" ] && [ "$$(ls -A $$EXPORT_SUBDIR)" ]; then \
		$(LOG_WARNING) "$$IP_NAME.zip already extracted in $$EXPORT_SUBDIR, skipping unzip"; \
	else \
		mkdir -p "$$EXPORT_SUBDIR"; \
		$(UNZIP) -o "$$IP_ZIP" -d "$$EXPORT_SUBDIR" > /dev/null; \
		$(LOG_SUCCESS) "Exported IP into $$EXPORT_SUBDIR"; \
	fi

# searches for a ZIP file and removes it from the ip_repo directory, If no zip is found infer/guess the filename, since the version on the zip is limited to two version segments, that's why: cut -d. -f1-2
# then removes it from the ip_repo directory
hls_clean:
	@$(HLS_VALIDATE); \
	HLS_WORK_DIR="$$HLS_CHILD_DIR"; \
	HLS_CFG_PATH="$$HLS_WORK_DIR/$(HLS_CFG)"; \
	HLS_TCL_PATH="$$HLS_WORK_DIR/$(HLS_TCL)"; \
	IP_ZIP=$$(ls "$$HLS_WORK_DIR"/hls/impl/ip/*.zip 2>/dev/null | head -n 1); \
	if [ -n "$$IP_ZIP" ]; then \
		IP_NAME=$$(basename "$$IP_ZIP" .zip); \
	else \
		$(LOG_INFO) "Inferring zip name..."; \
		VENDOR=$$(grep '^package.ip.vendor' "$$HLS_CFG_PATH" | cut -d= -f2 | tr -d ' '); \
		TOP=$$(grep '^syn.top' "$$HLS_CFG_PATH" | cut -d= -f2 | tr -d ' '); \
		VERSION=$$(grep '^package.ip.version' "$$HLS_CFG_PATH" | cut -d= -f2 | tr -d ' ' | cut -d. -f1-2 | tr '.' '_'); \
		IP_NAME="$${VENDOR}_hls_$${TOP}_$${VERSION}"; \
	fi; \
	EXPORT_SUBDIR="$(strip $(HLS_EXPORT_DIR))/$$IP_NAME"; \
	$(LOG_INFO) "Removing: exported IP ($$EXPORT_SUBDIR); hls dir ($$HLS_WORK_DIR/hls), tcl script ($$HLS_TCL_PATH) and Xil folders..."; \
	rm -rf $$EXPORT_SUBDIR $$HLS_WORK_DIR/hls $$HLS_WORK_DIR/.Xil $$HLS_TCL_PATH .Xil
	$(LOG_SUCCESS) "Cleaned hls successfully."

# ------------
# HANDLE CLEAN
# ------------
.PHONY: clean

clean:
	@if [ "$$(basename $(CURDIR))" == "hls" ]; then \
		$(MAKE) hls_clean; \
	elif [ "$$(basename $(CURDIR))" == "sw" ]; then \
		$(MAKE) app_clean; \
	elif [ "$$(basename $(CURDIR))" == "hw" ]; then \
		$(MAKE) hw_clean; \
	else \
	    $(LOG_ERROR) "This target must be run from the 'hls', 'sw', or 'hw' directory (currently in: $(CURDIR))."; \
	fi
