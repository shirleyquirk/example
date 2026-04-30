# Build the aji_shim that flattens libaji_client's C++ overloads into
# extern-C entry points ctypes can call.
#
# AJI_LIB_DIR  - directory containing libaji_client.so (default: submodule build)
# AJI_INC_DIR  - directory containing aji.h            (default: submodule)
# OUT_DIR      - where to write libaji_shim.so          (default: ./build)

REPO_ROOT  := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../..)
AJI_LIB_DIR ?= $(REPO_ROOT)/vendor/libaji_client/src/jtag/.libs
AJI_INC_DIR ?= $(REPO_ROOT)/vendor/libaji_client/src/h
OUT_DIR     ?= $(REPO_ROOT)/build/aji_shim

CXX      ?= g++
CXXFLAGS ?= -O2 -g -fcf-protection=none
AJI_DEFS  := -DWINDOWS=1 -DUNIX=2 -DLINUX=3 -DPORT=UNIX -DSYS=LINUX -DMODE_64_BIT
CXXFLAGS += -fPIC -Wall -Wextra -std=c++14 -I$(AJI_INC_DIR) $(AJI_DEFS)
LDFLAGS  += -L$(AJI_LIB_DIR) -Wl,-rpath,$(AJI_LIB_DIR)
LIBS     := -laji_client

$(OUT_DIR)/libaji_shim.so: aji_shim.cc | $(OUT_DIR)
	$(CXX) $(CXXFLAGS) -shared -o $@ $< $(LDFLAGS) $(LIBS)

$(OUT_DIR):
	mkdir -p $(OUT_DIR)

clean:
	rm -rf $(OUT_DIR)

.PHONY: clean
