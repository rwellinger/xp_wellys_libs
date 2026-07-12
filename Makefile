# xp_wellys_libs — build the prebuilt local-inference bundles.
#
# Normally CI builds + releases the bundles; you only need a local build when
# bumping an upstream pin offline. `make` with no target prints this help.
#
# Two bundle kinds:
#   * full arm64 (default): whisper + llama + ggml/Metal + Piper.
#       make bundle && make tarball  ->  xp_wellys_libs-arm64-macos-<ver>.tar.gz
#   * Piper-only (issue #71): libpiper + onnxruntime + espeak-ng-data, no
#     whisper/llama/Metal. Builds for x86_64 too (pure CPU TTS).
#       make tarball-tts-x86_64      ->  xp_wellys_libs-x86_64-macos-<ver>.tar.gz
#       make bundle-tts-arm64        (local fast sanity of the TTS-only path)

VERSION := $(shell cat VERSION.txt)

# Use Ninja when available (faster, parallel), else fall back to the Unix
# Makefiles generator that ships with every macOS toolchain — so a machine
# without ninja still builds. (CI installs ninja, so it picks Ninja.)
GENERATOR := $(shell command -v ninja >/dev/null 2>&1 && echo Ninja || echo "Unix Makefiles")

# Prefix for the x86_64 build. Empty on a native Intel runner (CI: macos-13);
# set to `arch -x86_64` locally on Apple Silicon to build the x86_64 slice
# under Rosetta (needs an x86_64-capable cmake/ninja). Piper selects the
# onnxruntime arch from CMAKE_SYSTEM_PROCESSOR, so the build process itself
# must run as x86_64 — a plain cross `-arch` flag is not enough.
ROSETTA ?=

.PHONY: help all setup build bundle tarball \
        bundle-tts-arm64 bundle-tts-x86_64 tarball-tts-x86_64 clean

.DEFAULT_GOAL := help

help:
	@echo "xp_wellys_libs — prebuilt local-inference bundles"
	@echo ""
	@echo "  make setup             Init whisper.cpp / llama.cpp / piper1-gpl submodules"
	@echo "  make bundle            Full arm64 bundle (whisper+llama+ggml/Metal+Piper)"
	@echo "  make tarball           Package it -> xp_wellys_libs-arm64-macos-$(VERSION).tar.gz"
	@echo ""
	@echo "  make bundle-tts-arm64  Piper-only arm64 bundle (local sanity of #71 path)"
	@echo "  make tarball-tts-x86_64  Piper-only x86_64 bundle + tarball (issue #71)"
	@echo "                         On Apple Silicon: prefix with ROSETTA='arch -x86_64'"
	@echo ""
	@echo "  make clean             Remove build*/ and the tarballs"
	@echo ""
	@echo "Typical: make setup && make bundle   (generator: $(GENERATOR))"
	@echo "Tip: 'brew install ninja' enables the faster parallel generator."

all: bundle

setup:
	git submodule update --init --recursive

# ── Full arm64 bundle (default, unchanged) ───────────────────────────────────
build bundle:
	cmake -B build -G "$(GENERATOR)" -DCMAKE_BUILD_TYPE=Release -Wno-dev
	cmake --build build --target bundle --parallel

tarball: bundle
	tar -C build/bundle -czf xp_wellys_libs-arm64-macos-$(VERSION).tar.gz .
	@echo "Wrote xp_wellys_libs-arm64-macos-$(VERSION).tar.gz"
	@shasum -a 256 xp_wellys_libs-arm64-macos-$(VERSION).tar.gz

# ── Piper-only bundles (issue #71) ───────────────────────────────────────────
# arm64 Piper-only — a fast local sanity check of the TTS-only build path
# (skips the ~50 min whisper/llama compile). Not a release artifact.
bundle-tts-arm64:
	cmake -B build-tts-arm64 -G "$(GENERATOR)" -DCMAKE_BUILD_TYPE=Release \
	    -DXPWELLYS_LIBS_TTS_ONLY=ON -Wno-dev
	cmake --build build-tts-arm64 --target bundle --parallel

# x86_64 Piper-only — the release artifact the plugin's x86_64-macOS slice
# consumes. Native on an Intel runner; via Rosetta on Apple Silicon.
bundle-tts-x86_64:
	$(ROSETTA) cmake -B build-tts-x86_64 -G "$(GENERATOR)" -DCMAKE_BUILD_TYPE=Release \
	    -DXPWELLYS_LIBS_TTS_ONLY=ON -DCMAKE_OSX_ARCHITECTURES=x86_64 -Wno-dev
	$(ROSETTA) cmake --build build-tts-x86_64 --target bundle --parallel

tarball-tts-x86_64: bundle-tts-x86_64
	tar -C build-tts-x86_64/bundle -czf xp_wellys_libs-x86_64-macos-$(VERSION).tar.gz .
	@echo "Wrote xp_wellys_libs-x86_64-macos-$(VERSION).tar.gz"
	@shasum -a 256 xp_wellys_libs-x86_64-macos-$(VERSION).tar.gz

clean:
	rm -rf build build-tts-arm64 build-tts-x86_64 \
	    xp_wellys_libs-arm64-macos-$(VERSION).tar.gz \
	    xp_wellys_libs-x86_64-macos-$(VERSION).tar.gz
