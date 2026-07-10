# xp_wellys_libs — build the prebuilt arm64 local-inference bundle.
#
# Normally CI builds + releases the bundle; you only need a local build when
# bumping an upstream pin offline. `make` with no target prints this help.

BUILD_DIR := build
VERSION   := $(shell cat VERSION.txt)
TARBALL   := xp_wellys_libs-arm64-macos-$(VERSION).tar.gz

# Use Ninja when available (faster, parallel), else fall back to the Unix
# Makefiles generator that ships with every macOS toolchain — so a machine
# without ninja still builds. (CI installs ninja, so it picks Ninja.)
GENERATOR := $(shell command -v ninja >/dev/null 2>&1 && echo Ninja || echo "Unix Makefiles")

.PHONY: help all setup build bundle tarball clean

.DEFAULT_GOAL := help

help:
	@echo "xp_wellys_libs — prebuilt arm64 local-inference bundle"
	@echo ""
	@echo "  make setup     Init the whisper.cpp / llama.cpp / piper1-gpl submodules"
	@echo "  make build     Configure + compile everything (the slow part) + stage build/bundle/"
	@echo "  make bundle    Alias for 'make build'"
	@echo "  make tarball   Package build/bundle/ -> $(TARBALL) (+ SHA256)"
	@echo "  make clean     Remove $(BUILD_DIR)/ and the tarball"
	@echo ""
	@echo "Typical: make setup && make bundle   (generator: $(GENERATOR))"
	@echo "Tip: 'brew install ninja' enables the faster parallel generator."

all: bundle

setup:
	git submodule update --init --recursive

$(BUILD_DIR)/CMakeCache.txt:
	cmake -B $(BUILD_DIR) -G "$(GENERATOR)" -DCMAKE_BUILD_TYPE=Release -Wno-dev

build: $(BUILD_DIR)/CMakeCache.txt
	cmake --build $(BUILD_DIR) --target bundle --parallel

# `bundle` is the default build target; alias for clarity.
bundle: build

tarball: bundle
	tar -C $(BUILD_DIR)/bundle -czf $(TARBALL) .
	@echo "Wrote $(TARBALL)"
	@shasum -a 256 $(TARBALL)

clean:
	rm -rf $(BUILD_DIR) $(TARBALL)
