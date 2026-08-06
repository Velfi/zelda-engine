NODE_INCLUDE_DIR ?= $(shell node -p "require('node:path').resolve(require('node:path').dirname(process.execPath), '../include/node')")
IMGUI_DLL ?= 1
IMGUI_DLL_BOOL := $(if $(filter 0,$(IMGUI_DLL)),false,true)
UNAME_S := $(shell uname -s)
UNAME_M := $(shell uname -m)
IMGUI_DYLIB_DIR := $(if $(filter arm64,$(UNAME_M)),darwin_arm64,darwin_x64)
IMGUI_DYLIB_NAME := imgui.dylib
IMGUI_DYLIB_REL := $(IMGUI_DYLIB_DIR)/$(IMGUI_DYLIB_NAME)
SDL3_LIB_DIR ?= /opt/homebrew/opt/sdl3/lib

CXXFLAGS = \
	-std=c++23 \
	-I$(NODE_INCLUDE_DIR) \
	-shared \
	-fPIC \
	-Wl,-undefined,dynamic_lookup,-rpath,@loader_path,-rpath,$(SDL3_LIB_DIR)

LIBS = -L. -lim

IM_FLAGS = \
	-build-mode:shared \
	-o:minimal \
	-out:libim.dylib \
	-define:IMGUI_DLL=$(IMGUI_DLL_BOOL)

all: im.node

im.node: im.cpp im.h libim.dylib
	clang++ $(CXXFLAGS) -o $@ im.cpp $(LIBS)

libim.dylib:
	odin build . $(IM_FLAGS)
	@if [ "$(UNAME_S)" = "Darwin" ] && [ "$(IMGUI_DLL)" != "0" ]; then install_name_tool -change $(IMGUI_DYLIB_NAME) @loader_path/$(IMGUI_DYLIB_REL) $@; fi

lib: libim.dylib
