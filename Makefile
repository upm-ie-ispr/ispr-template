# Define the source directory and the target directory
SOURCE_DIR ?= tutorials/lab1

SOURCE_PRJ := $(shell basename $(SOURCE_DIR))
TARGET_PRJ := $(shell basename $(TARGET_DIR))

# Rule to set up a new lab projet
new:
	if [ -d "$(TARGET_DIR)" ]; then \
		echo "Error: Directory $(TARGET_DIR) already exists."; \
		exit 1; \
	fi
	echo "Creating new project at $(TARGET_DIR)"
	mkdir -p $(TARGET_DIR)/hw $(TARGET_DIR)/sw
	cp $(SOURCE_DIR)/hw/Makefile $(TARGET_DIR)/hw/Makefile
	cp $(SOURCE_DIR)/sw/.gitignore $(TARGET_DIR)/sw/.gitignore
	cp $(SOURCE_DIR)/sw/Makefile $(TARGET_DIR)/sw/Makefile
	if [ -d "$(SOURCE_DIR)/hw/src" ]; then \
		cp -r $(SOURCE_DIR)/hw/src $(TARGET_DIR)/hw/src; \
	fi
	if [ -f "$(SOURCE_DIR)/hw/create_project.tcl" ]; then \
		cp $(SOURCE_DIR)/hw/create_project.tcl $(TARGET_DIR)/hw/create_project.tcl; \
		sed -i 's/$(SOURCE_PRJ)/$(TARGET_PRJ)/g' $(TARGET_DIR)/hw/create_project.tcl; \
	fi

# Usage:
# make new SOURCE_DIR=existing_project_path TARGET_DIR=new_project_path
