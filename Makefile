# xp_wellys_libs — build the prebuilt local-inference bundles.
#
# Normally CI builds + releases the bundles; you only need a local build when
# bumping an upstream pin offline. `make` with no target prints this help.
#
# Two bundle kinds:
#   * full (default): whisper + llama + ggml + Piper. Metal on macOS-arm64,
#     plain CPU on linux-x64. Platform is derived from the host below.
#       make bundle && make tarball  ->  xp_wellys_libs-<platform>-<ver>.tar.gz
#   * Piper-only (XPWELLYS_LIBS_TTS_ONLY): libpiper + onnxruntime +
#     espeak-ng-data, no whisper/llama/Metal — pure CPU TTS.
#       make bundle-tts-arm64        (local sanity of the TTS-only path)
#     The Windows Piper-only bundle (plugin #73/#74) reuses this option in CI
#     on windows-latest. The x86_64-macOS variant was dropped (no Intel
#     GitHub runner) — see release.yml.

VERSION := $(shell cat VERSION.txt)

# Mirror CMakeLists' _platform label -- the tarball name and manifest.txt must
# agree, and the consumer derives the download URL from exactly these strings.
UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
    PLATFORM  := arm64-macos
    SHA256SUM := shasum -a 256
else
    PLATFORM  := linux-x64
    SHA256SUM := sha256sum
endif
TARBALL := xp_wellys_libs-$(PLATFORM)-$(VERSION).tar.gz

# Use Ninja when available (faster, parallel), else fall back to the Unix
# Makefiles generator that ships with every macOS toolchain — so a machine
# without ninja still builds. (CI installs ninja, so it picks Ninja.)
GENERATOR := $(shell command -v ninja >/dev/null 2>&1 && echo Ninja || echo "Unix Makefiles")

.PHONY: help all setup build bundle tarball bundle-tts-arm64 clean

.DEFAULT_GOAL := help

help:
	@echo "xp_wellys_libs — prebuilt local-inference bundles"
	@echo ""
	@echo "  make setup             Init whisper.cpp / llama.cpp / piper1-gpl submodules"
	@echo "  make bundle            Full $(PLATFORM) bundle (whisper+llama+ggml+Piper)"
	@echo "  make tarball           Package it -> $(TARBALL)"
	@echo ""
	@echo "  make bundle-tts-arm64  Piper-only arm64 bundle (local sanity of the TTS path)"
	@echo ""
	@echo "  make clean             Remove build*/ and the tarballs"
	@echo ""
	@echo "Typical: make setup && make bundle   (generator: $(GENERATOR))"
	@echo "Tip: 'brew install ninja' enables the faster parallel generator."

all: bundle

setup:
	git submodule update --init --recursive

# ── Full bundle (default) — arm64-macos or linux-x64, per host ───────────────
build bundle:
	cmake -B build -G "$(GENERATOR)" -DCMAKE_BUILD_TYPE=Release -Wno-dev
	cmake --build build --target bundle --parallel

# No -h: the Linux bundle's libonnxruntime.so{,.1} MUST stay symlinks in the
# tarball, or they unpack as two extra 15 MB copies.
tarball: bundle
	tar -C build/bundle -czf $(TARBALL) .
	@echo "Wrote $(TARBALL)"
	@$(SHA256SUM) $(TARBALL)

# ── Piper-only bundle (XPWELLYS_LIBS_TTS_ONLY) ───────────────────────────────
# arm64 Piper-only — a fast local sanity check of the TTS-only build path
# (skips the ~50 min whisper/llama compile). Not a release artifact; the
# Windows Piper-only release bundle (plugin #73/#74) is built in CI on
# windows-latest with the same XPWELLYS_LIBS_TTS_ONLY option. The x86_64-macOS
# variant was dropped — GitHub retired the Intel runners (see release.yml).
bundle-tts-arm64:
	cmake -B build-tts-arm64 -G "$(GENERATOR)" -DCMAKE_BUILD_TYPE=Release \
	    -DXPWELLYS_LIBS_TTS_ONLY=ON -Wno-dev
	cmake --build build-tts-arm64 --target bundle --parallel

clean:
	rm -rf build build-tts-arm64 \
	    xp_wellys_libs-*-$(VERSION).tar.gz
