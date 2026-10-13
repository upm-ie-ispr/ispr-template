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

# --- PROJECT CREATION ---

TEMPLATE_DIR 	   := assets/templates
VALID_PROJECT_DIRS := exercises tutorials

PARENT := $(notdir $(patsubst %/,%,$(dir $(TARGET_DIR))))
define CHECK_PROJECT_DIR
	@if [ -z "$(filter $(PARENT),$(VALID_PROJECT_DIRS))" ]; then \
		$(LOG_ERROR) "Invalid parent directory $(PARENT), must be one of: $(VALID_PROJECT_DIRS)"; \
		exit 1; \
	fi
endef

.PHONY: new add_hls new_hls

# Create a new project, either from a source project or from templates.
# Usage:
#   make new TARGET_DIR=path/to/new/project                      				 		 # init mode: create from templates
#   make new SOURCE_DIR=path/to/__EXISTING__/project TARGET_DIR=path/to/__NEW__/project  # copy mode: copy from source
new:
	@$(LOG_INFO) "Creating new project..."
	@if [ -z "$(TARGET_DIR)" ]; then \
		$(LOG_ERROR) "TARGET_DIR is not set."; \
		printf "    Usage: make new TARGET_DIR=path/to/new/project [SOURCE_DIR=path/to/existing/project]"; \
		exit 1; \
	fi
	@if [ -d "$(TARGET_DIR)" ]; then \
		$(LOG_ERROR) "Directory $(TARGET_DIR) already exists."; \
		exit 1; \
	fi
	$(CHECK_PROJECT_DIR)

	@if [ -n "$(SOURCE_DIR)" ] && [ ! -d "$(SOURCE_DIR)" ]; then \
		$(LOG_ERROR) "SOURCE_DIR '$(SOURCE_DIR)' does not exist."; \
		exit 1; \
	fi

	@$(LOG_INFO) "Populating $(TARGET_DIR)..."
	@mkdir -p $(TARGET_DIR)/hw $(TARGET_DIR)/sw
	@if [ -z "$(SOURCE_DIR)" ]; then \
		$(LOG_INFO) "SOURCE_DIR is not set, creating $(TARGET_DIR) from templates..."; \
		cp $(TEMPLATE_DIR)/gitignore_mod    $(TARGET_DIR)/.gitignore; \
		cp $(TEMPLATE_DIR)/makefile_mod     $(TARGET_DIR)/Makefile; \
		cp $(TEMPLATE_DIR)/gitignore_hw     $(TARGET_DIR)/hw/.gitignore; \
		cp $(TEMPLATE_DIR)/makefile_vivado  $(TARGET_DIR)/hw/Makefile; \
		cp $(TEMPLATE_DIR)/gitignore_sw     $(TARGET_DIR)/sw/.gitignore; \
		cp $(TEMPLATE_DIR)/makefile_vivado  $(TARGET_DIR)/sw/Makefile; \
	else \
		$(LOG_INFO) "Using $(SOURCE_DIR) as source..."; \
		if [ -f "$(SOURCE_DIR)/Makefile" ]; then cp $(SOURCE_DIR)/Makefile $(TARGET_DIR)/Makefile; fi; \
		if [ -f "$(SOURCE_DIR)/.gitignore" ]; then cp $(SOURCE_DIR)/.gitignore $(TARGET_DIR)/.gitignore; fi; \
		cp $(SOURCE_DIR)/hw/Makefile $(TARGET_DIR)/hw/Makefile; \
		if [ -f "$(SOURCE_DIR)/hw/.gitignore" ]; then cp $(SOURCE_DIR)/hw/.gitignore $(TARGET_DIR)/hw/.gitignore; fi; \
		if [ -d "$(SOURCE_DIR)/hw/src" ]; then cp -r $(SOURCE_DIR)/hw/src $(TARGET_DIR)/hw/src; fi; \
		if [ -f "$(SOURCE_DIR)/hw/create_project.tcl" ]; then \
			cp $(SOURCE_DIR)/hw/create_project.tcl $(TARGET_DIR)/hw/create_project.tcl; \
			sed -i 's/$(notdir $(SOURCE_DIR))/$(notdir $(TARGET_DIR))/g' $(TARGET_DIR)/hw/create_project.tcl; \
		fi; \
		cp $(SOURCE_DIR)/sw/Makefile $(TARGET_DIR)/sw/Makefile; \
		if [ -f "$(SOURCE_DIR)/sw/.gitignore" ]; then cp $(SOURCE_DIR)/sw/.gitignore $(TARGET_DIR)/sw/.gitignore; fi; \
		if [ -f "$(SOURCE_DIR)/hls/.gitignore" ]; then mkdir -p $(TARGET_DIR)/hls; cp $(SOURCE_DIR)/hls/.gitignore $(TARGET_DIR)/hls/.gitignore; fi; \
		if [ -f "$(SOURCE_DIR)/hls/Makefile" ]; then mkdir -p $(TARGET_DIR)/hls; cp $(SOURCE_DIR)/hls/Makefile $(TARGET_DIR)/hls/Makefile; fi; \
	fi
	@$(LOG_SUCCESS) "Project $(TARGET_DIR) created successfully."

# Create only the HLS folder inside an existing project.
# Usage:
#   make add_hls TARGET_DIR=path/to/existing/project
add_hls:
	@$(LOG_INFO) "Adding HLS folder to project..."
	@if [ -z "$(TARGET_DIR)" ]; then \
		@$(LOG_ERROR) "TARGET_DIR is not set."; \
		printf "    Usage: make add_hls TARGET_DIR=path/to/project"; \
		exit 1; \
	fi
	@if [ ! -d "$(TARGET_DIR)" ]; then \
		@$(LOG_ERROR) "TARGET_DIR '$(TARGET_DIR)' does not exist. Run 'make new ...' first."; \
		exit 1; \
	fi
	@if [ -d "$(TARGET_DIR)/hls" ]; then \
		@$(LOG_ERROR) "Directory $(TARGET_DIR)/hls already exists."; \
		exit 1; \
	fi
	$(CHECK_PROJECT_DIR)
	@mkdir -p $(TARGET_DIR)/hls
	@cp $(TEMPLATE_DIR)/makefile_vivado $(TARGET_DIR)/hls/Makefile
	@cp $(TEMPLATE_DIR)/gitignore_hls   $(TARGET_DIR)/hls/.gitignore
	@$(LOG_SUCCESS) "HLS folder created successfully for $(TARGET_DIR)."

# Create a project with HLS folder included.
# Usage:
#   make new_hls TARGET_DIR=path/to/project
new_hls:
	@$(MAKE) new TARGET_DIR=$(TARGET_DIR)
	@$(MAKE) add_hls TARGET_DIR=$(TARGET_DIR)
