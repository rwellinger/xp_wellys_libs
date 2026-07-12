# xp_wellys_libs

Prebuilt local-inference libraries for
[xp_wellys_vfr_atc](https://github.com/rwellinger/xp_wellys_vfr_atc).

Two bundle kinds, compiled **once per pin bump** and published as versioned
binary bundles the plugin downloads in `make setup` (instead of compiling from
source — turning its ~50 min cold release build into a deterministic ~5–8 min
one):

- **`arm64-macos` (full)** — whisper.cpp + llama.cpp + ggml (Metal) + Piper +
  espeak-ng. The Apple-Silicon local-inference slice.
- **`x86_64-macos` (tts-only)** — Piper + onnxruntime + espeak-ng only (pure
  CPU, no whisper/llama/Metal). Feeds the plugin's hybrid mode (cloud STT/LM +
  local German Piper voice) on Intel Macs (issue #71). A Windows Piper-only
  bundle follows (#73/#74).

See [DESIGN.md](DESIGN.md) for the full rationale, bundle layout, link-order
handling, toolchain pinning, and the plugin-side consumption flow.

## Build locally

```bash
make setup              # init the whisper.cpp / llama.cpp / piper1-gpl submodules

# Full arm64 bundle:
make bundle             # stage build/bundle/ (libs + headers + espeak-ng-data)
make tarball            # -> xp_wellys_libs-arm64-macos-<version>.tar.gz

# Piper-only bundles (issue #71):
make bundle-tts-arm64   # local fast sanity of the TTS-only path (no whisper/llama)
make tarball-tts-x86_64 # -> xp_wellys_libs-x86_64-macos-<version>.tar.gz
```

The x86_64 Piper-only bundle must be built on a **native Intel** process (Piper
selects its onnxruntime arch from `CMAKE_SYSTEM_PROCESSOR`). CI uses a `macos-13`
runner; locally on Apple Silicon it needs an x86_64 cmake (`ROSETTA='arch
-x86_64'`) — the arm64 cmake cannot cross-select the onnx arch.

CI (`.github/workflows/release.yml`) builds both kinds (arm64 full on `macos-15`,
x86_64 tts-only on `macos-13`), link-smoke-tests each bundle exactly as the
plugin will consume it, and on a `v*` tag publishes the tarballs as a GitHub
release.

## Cut a release

1. Bump submodule pins if needed; set `VERSION.txt`.
2. `git tag v<x.y.z> && git push --tags` → CI builds + publishes the bundle.
3. In the plugin repo bump `PREBUILT_LIBS_VERSION` to `<x.y.z>`.

## Pinned upstream revisions

| Submodule | Pin |
|---|---|
| whisper.cpp | `f049fff95a089aa9969deb009cdd4892b3e74916` |
| llama.cpp | `f449e0553708b895adbd94a301431cef691f632d` |
| piper1-gpl | `d6975e21a440c0d8b6e5fb7c41027409af13d44d` |
| onnxruntime | 1.22.0 (prebuilt, fetched by Piper) |

## License

**GPL-3.0-or-later** — inherited from espeak-ng, statically linked into
`libpiper.dylib`. See [LICENSE](LICENSE).
