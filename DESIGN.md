# xp_wellys_libs — Design

Prebuilt local-inference libraries for **xp_wellys_vfr_atc**.

## Why this repo exists

The main plugin's release build spent ~50 min compiling whisper.cpp +
llama.cpp + ggml (Metal) + Piper + espeak-ng from source on every cold CI
run. The ccache/`warm-deps` scheme meant to hide that cost defeated itself:
frequent commits cancelled the warm job before it could upload its cache, so
the deps were perpetually cold.

This repo compiles those heavy third-party trees **once per pin bump** and
publishes a versioned binary bundle as a GitHub release. The main repo then
downloads the bundle in `make setup` (seconds) instead of compiling it. The
release build becomes deterministic ~5–8 min, cold or warm.

## Scope: two bundle kinds

Local **STT/LM** (whisper.cpp + llama.cpp, Metal-accelerated) is
**Apple-Silicon-only**. Local **TTS** (Piper) is pure CPU (onnxruntime +
espeak-ng, no Metal), so it is portable to Intel Macs and Windows — the plugin's
hybrid mode (cloud STT/LM + local German Piper voice, plugin issue #69) needs it
on those slices too. So this repo produces two bundle kinds:

| Bundle | Contents | Consumer target | Built by |
|---|---|---|---|
| `arm64-macos` (full) | whisper + llama + ggml/Metal + Piper | `xp_wellys_libs::inference` (+ `::piper`) | `macos-15` (arm64) |
| `x86_64-macos` (tts-only) | Piper + onnxruntime + espeak-ng-data | `xp_wellys_libs::piper` | `macos-13` (Intel) |

The Piper-only bundle is selected with `-DXPWELLYS_LIBS_TTS_ONLY=ON`; it skips
whisper/llama/ggml/Metal entirely. Piper picks its onnxruntime arch from
`CMAKE_SYSTEM_PROCESSOR`, so the x86_64 bundle is built on a **native Intel**
process (CI's `macos-13` runner; locally only under an x86_64 cmake) — a plain
cross `-arch` flag is not enough. A Windows Piper-only bundle is the next step
(plugin issues #73/#74).

## What the bundle contains

`xp_wellys_libs-arm64-macos-<version>.tar.gz`, extracting to:

```
lib/
  libwhisper.a
  libllama.a
  libllama-common.a      # llama.cpp's common helper
  libllama-common-base.a # split out of common in recent llama.cpp
  libggml.a              # umbrella
  libggml-base.a
  libggml-cpu.a
  libggml-metal.a        # Metal kernels embedded (GGML_METAL_EMBED_LIBRARY)
  libpiper.dylib         # shared; statically bundles espeak-ng
  libonnxruntime.1.22.0.dylib
  libonnxruntime.dylib   # symlink-style alias piper's rpath resolves
include/
  whisper.h
  llama.h
  ggml/*.h               # ggml.h, ggml-*.h, gguf.h
  common/*.h             # common.h et al (llama-common)
  piper.h
share/
  espeak-ng-data/        # runtime voice data, shipped next to the .xpl
manifest.txt             # SHA256 of every lib + the source submodule pins
xp_wellys_libs.cmake     # consumer include: defines the link list + order
```

### Pinned upstream revisions (must match the plugin's submodules)

| Submodule | Pin |
|---|---|
| whisper.cpp | `f049fff95a089aa9969deb009cdd4892b3e74916` |
| llama.cpp | `f449e0553708b895adbd94a301431cef691f632d` |
| piper1-gpl | `d6975e21a440c0d8b6e5fb7c41027409af13d44d` |
| onnxruntime | 1.22.0 (prebuilt, downloaded by Piper's CMake) |

## Build (this repo)

`CMakeLists.txt` lifts the exact ggml/Metal options and the
`add_subdirectory` ordering already proven in the plugin's build (llama.cpp
first so its pinned `ggml` target wins; whisper.cpp reuses it; Piper last).
A `bundle` custom target copies each `$<TARGET_FILE:...>` plus the headers
and espeak-ng-data into `build/bundle/`, then writes `manifest.txt`.

Toolchain is the **default Apple clang** (from the active Xcode) + deployment
target **13.3**, identical to the plugin — its Makefile sets no
`CMAKE_*_COMPILER`, so it builds with Apple clang too. Static `.a` archives
are ABI-sensitive, so matching the plugin's compiler matters; Apple clang is
also the only clang that compiles Apple's SDK headers cleanly (Homebrew LLVM's
newer clang errors with `-Welaborated-enum-base` in vDSP.h / CoreFoundation).
CI runs on `macos-15` (arm64), the same runner generation the plugin is
released from.

## Consumption (main repo)

- A `PREBUILT_LIBS_VERSION` file in the plugin repo pins the bundle version.
- `make setup` (and the CI deps step) `curl`s the matching release tarball
  and extracts it to `vendor/prebuilt/xp_wellys_libs/`. The SHA256 in
  `manifest.txt` is verified before use.
- `CMakeLists.txt`, in local-inference mode, gets a new branch: if the
  prebuilt bundle is present it consumes it via `xp_wellys_libs.cmake`
  (imported static libs + `libpiper.dylib`) instead of `add_subdirectory`-ing
  the submodules. The from-source path stays as a fallback
  (`-DXPWELLYS_LOCAL_FROM_SOURCE=ON`) for when a pin is being bumped.
- The plugin drops the three `spikes/spike_*/third_party` submodules from its
  release build. `warm-deps` + the espeak/onnx `actions/cache` dance are
  deleted from `.github/workflows/build.yml`.

## Link order (the one real risk)

The static libs must be handed to `ld` in dependency order:

```
whisper  llama-common  llama-common-base  llama  ggml-metal  ggml-cpu  ggml-base  ggml
+ frameworks: Metal MetalKit Foundation Accelerate
+ libpiper.dylib (self-contained)  libonnxruntime.1.22.0.dylib
```

`xp_wellys_libs.cmake` encodes this list. macOS `ld64` re-scans archives, so
minor ordering slack is tolerated, but the file fixes a known-good order.
**This is validated by the first CI run** — the plugin must link and its
Catch2 suite must pass against the downloaded bundle before we cut a release.

## Versioning workflow

1. Bump a submodule pin here → tag `v<x.y.z>` → CI builds + publishes the
   bundle.
2. In the plugin repo, bump `PREBUILT_LIBS_VERSION` to `<x.y.z>` and the
   matching submodule pins (kept in sync for the from-source fallback).
3. Plugin CI downloads the new bundle. No heavy compile in the plugin repo
   ever again.

License: **GPL-3.0-or-later** — inherited from espeak-ng, statically linked
into `libpiper.dylib`.
