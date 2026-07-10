# xp_wellys_libs — build the prebuilt arm64 local-inference bundle.
#
#   make setup    # init/update the three submodules
#   make build    # configure + compile whisper/llama/ggml/Piper (the slow part)
#   make bundle    # stage build/bundle/ (libs + headers + espeak-ng-data)
#   make tarball   # -> xp_wellys_libs-arm64-macos-<version>.tar.gz
#   make clean

BUILD_DIR := build
VERSION   := $(shell cat VERSION.txt)
TARBALL   := xp_wellys_libs-arm64-macos-$(VERSION).tar.gz

.PHONY: all setup build bundle tarball clean

all: bundle

setup:
	git submodule update --init --recursive

$(BUILD_DIR)/CMakeCache.txt:
	cmake -B $(BUILD_DIR) -G Ninja -DCMAKE_BUILD_TYPE=Release -Wno-dev

build: $(BUILD_DIR)/CMakeCache.txt
	cmake --build $(BUILD_DIR) --target bundle

# `bundle` is the default build target; alias for clarity.
bundle: build

tarball: bundle
	tar -C $(BUILD_DIR)/bundle -czf $(TARBALL) .
	@echo "Wrote $(TARBALL)"
	@shasum -a 256 $(TARBALL)

clean:
	rm -rf $(BUILD_DIR) $(TARBALL)
