# xp_wellys_libs — Design

Prebuilt local-inference libraries for **xp_wellys_vfr_atc** and
**xp_welly_llm_atc**.

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

## Scope: three bundles

Local **STT/LM** (whisper.cpp + llama.cpp) is GPU-accelerated where a backend is
available and plain-CPU elsewhere. Local **TTS** (Piper) is pure CPU (onnxruntime
+ espeak-ng), so it is portable on its own — the plugin's hybrid mode (cloud
STT/LM + local German Piper voice, plugin issue #69) needs it on slices that have
no local STT/LM. This repo produces three bundles:

| Bundle | Contents | Consumer target | Built by |
|---|---|---|---|
| `arm64-macos` (full) | whisper + llama + ggml/Metal + Piper | `xp_wellys_libs::inference` (+ `::piper`) | `macos-15` (arm64) |
| `linux-x64` (full) | whisper + llama + ggml/CPU + Piper | `xp_wellys_libs::inference` (+ `::piper`) | `ubuntu-22.04` |
| `win-x64` (full) | whisper + llama + ggml/CPU+Vulkan + Piper | `xp_wellys_libs::inference` (+ `::piper`) | `windows-latest` |

A Piper-only bundle is still selectable with `-DXPWELLYS_LIBS_TTS_ONLY=ON` (it
skips whisper/llama/ggml entirely) and remains useful as a fast local sanity
check, but no platform releases that kind anymore.

### Windows portability constraints

- **Vulkan, not CUDA.** CUDA would force the plugin's release to carry the CUDA
  redist DLLs — `ggml-cuda` alone is 50–160 MB and `cuBLAS`/`cuBLASLt` run into
  the hundreds — which is untenable for something shipped through the SkunkCrafts
  updater. Vulkan adds **no runtime DLL at all**: `vulkan-1.dll` ships with the
  graphics driver, and X-Plane 12 renders through Vulkan on Windows anyway, so it
  is present on every target system. It also covers AMD/Intel. The cost is
  roughly 10–30 % throughput versus CUDA on the same card.
- **`vulkan-1.lib` is staged into the bundle.** `ggml-vulkan` drives everything
  through the dynamic `vulkan.hpp` dispatcher, leaving exactly one symbol at link
  time (`vkGetInstanceProcAddr`). Shipping that small import lib means the
  *consuming* build needs no Vulkan SDK — only this repo's CI does.
- **Static MSVC runtime (`/MT`) for the archives.** The consumer builds `/MT`
  (its curl comes from vcpkg's `x64-windows-static`), and these archives link
  into the same module as the plugin, so a mixed CRT means `LNK2005` or two heaps
  in one module. Two traps this had to work around: whisper.cpp opens its
  `CMakeLists.txt` with `cmake_minimum_required(VERSION 3.5)`, which resets
  CMP0091 and would silently ignore `CMAKE_MSVC_RUNTIME_LIBRARY` **for
  `whisper.lib` alone** (hence `CMAKE_POLICY_DEFAULT_CMP0091 NEW`); and libpiper
  builds espeak-ng as an ExternalProject with fixed `CMAKE_ARGS` that do not
  forward the runtime setting, so `/MT` is scoped to the whisper/llama block and
  Piper stays `/MD` behind its DLL boundary. CI asserts both with
  `dumpbin /directives`, and `xp_wellys_libs.cmake` fails the consumer's configure
  outright if it is not building `/MT`.
- **No `-march=native`** — the same `GGML_NATIVE=OFF` reasoning as Linux applies
  verbatim; under MSVC that baseline resolves to `/arch:AVX2`.

### Linux portability constraints

A prebuilt that runs on *other people's* CPUs needs three things the from-source
build never had to care about. All three are set in the `else()` (non-Apple)
branch of the ggml options and asserted in CI, because every one of them looks
perfectly healthy on the build runner and only fails at the user:

- **`GGML_NATIVE=OFF`** — it defaults **ON** off-Apple, i.e. `-march=native`,
  which would bake the runner's ISA (AVX-512 on some Azure SKUs) into the
  archives and SIGILL on user CPUs with no stack trace. OFF flips ggml's
  `INS_ENB=ON` → SSE42/AVX/AVX2/BMI2/F16C baseline.
- **`GGML_OPENMP=OFF`** — ggml links OpenMP PRIVATE onto `ggml-base` via a CMake
  target. The bundle ships raw `.a` paths, so that link info cannot survive and
  the consumer would hit undefined `GOMP_*`. ggml's own threadpool has no such
  dependency.
- **glibc baseline = 2.35** (`ubuntu-22.04`, not 24.04). A prebuilt belongs on
  the oldest base we support: 2.35 is consumable by Debian 12 (2.36) and newer,
  whereas building on 24.04 (2.39) would lock those users out. Revisit only by
  raising the floor deliberately.

`libpiper.so` additionally gets its RUNPATH rewritten to `$ORIGIN` with
`patchelf` **during staging**, not by the consumer: the bundle should describe
itself, and a consumer without patchelf would otherwise ship a silently broken
`.so`.

**Dropped: x86_64-macOS.** A Piper-only Intel-Mac bundle was implemented (plugin
#71) but cannot be produced in CI — GitHub retired the Intel `macos-13` runners
(a 2h+ queue that never allocates), and Piper picks its onnxruntime arch from
`CMAKE_SYSTEM_PROCESSOR`, so cross-building on an arm64 runner would need patching
the pinned espeak-ng submodule's ExternalProject. Intel Macs are a shrinking
niche with **no regression** (they keep cloud TTS). The `XPWELLYS_LIBS_TTS_ONLY`
option + `::piper` target stay: the option as a local sanity check, the target
because every bundle defines it (the plugin's hybrid TTS override is available
in all backend modes).

## What the bundle contains

`xp_wellys_libs-<platform>-<version>.tar.gz`, extracting to the tree below
(shown for `arm64-macos`; `linux-x64` is identical except that
`libggml-metal.a` is absent and the Piper/onnxruntime files are
`libpiper.so` / `libonnxruntime.so.1.22.0` + `.so.1` + `.so` symlinks +
`libonnxruntime_providers_shared.so`). The tree is flat — the platform lives
in the tarball name and in `manifest.txt`'s first line, and
`xp_wellys_libs.cmake` refuses a bundle whose label does not match the
consuming build.

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

On Linux the toolchain is the runner's default GCC (`build-essential` on
`ubuntu-22.04`) — again matching what the plugin's own Linux build uses. The
same ABI-sensitivity argument applies, which is why the glibc floor above is a
deliberate choice and not an accident of runner selection.

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

**On Linux the risk is eliminated, not managed.** GNU `ld` does not re-scan
archives the way `ld64` does, and `ggml` ↔ `ggml-base`/`ggml-cpu` reference each
other, so a single ordered pass is brittle. The non-Apple branch wraps the
archives in `-Wl,--start-group ... -Wl,--end-group`, which makes the order
irrelevant for a few extra link seconds (`lld` and `mold` honour it too). It
also re-states `Threads::Threads`, `dl` and `m`, which ggml links PRIVATE onto
`ggml-base` upstream via CMake targets — link info that raw `.a` paths cannot
carry. `libggml-metal.a` is appended based on whether the bundle actually
contains it, not on `if(APPLE)`, so the list describes the bundle at hand.

## Versioning workflow

1. Bump a submodule pin here → tag `v<x.y.z>` → CI builds + publishes the
   bundle.
2. In the plugin repo, bump `PREBUILT_LIBS_VERSION` to `<x.y.z>` and the
   matching submodule pins (kept in sync for the from-source fallback).
3. Plugin CI downloads the new bundle. No heavy compile in the plugin repo
   ever again.

License: **GPL-3.0-or-later** — inherited from espeak-ng, statically linked
into `libpiper.dylib`.
