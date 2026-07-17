# xp_wellys_libs

Prebuilt local-inference libraries for
[xp_wellys_vfr_atc](https://github.com/rwellinger/xp_wellys_vfr_atc) and
[xp_welly_llm_atc](https://github.com/rwellinger/xp_welly_llm_atc).

Three bundles, compiled **once per pin bump** and published as versioned
binary bundles the plugins download in `make setup` (instead of compiling from
source — turning their ~50 min cold release build into a deterministic ~5–8 min
one):

- **`arm64-macos` (full)** — whisper.cpp + llama.cpp + ggml (Metal) + Piper +
  espeak-ng. The Apple-Silicon local-inference slice.
- **`linux-x64` (full)** — the same, with plain-CPU ggml (no Metal/Accelerate).
  Built on `ubuntu-22.04` for a glibc-2.35 floor, with `GGML_NATIVE=OFF` so the
  archives carry a portable ISA baseline rather than the runner's — see
  DESIGN.md.
- **`win-x64` (tts-only, planned)** — Piper + onnxruntime + espeak-ng only (pure
  CPU, no whisper/llama/Metal). Feeds the plugin's hybrid mode (cloud STT/LM +
  local German Piper voice) on Windows (#73/#74). The x86_64-macOS variant was
  dropped — GitHub retired the Intel CI runners (see DESIGN.md); Intel Macs keep
  cloud TTS, no regression.

**This repo must stay public.** The plugins ship espeak-ng (GPL-3.0-or-later)
as a binary, and their `THIRD_PARTY.md` points here for the corresponding
source. Release assets must likewise not be deleted while a plugin version
still pins them.

See [DESIGN.md](DESIGN.md) for the full rationale, bundle layout, link-order
handling, toolchain pinning, and the plugin-side consumption flow.

## Build locally

```bash
make setup              # init the whisper.cpp / llama.cpp / piper1-gpl submodules

# Full bundle for the host platform (arm64-macos or linux-x64):
make bundle             # stage build/bundle/ (libs + headers + espeak-ng-data)
make tarball            # -> xp_wellys_libs-<platform>-<version>.tar.gz

# Piper-only bundle (XPWELLYS_LIBS_TTS_ONLY):
make bundle-tts-arm64   # local fast sanity of the TTS-only path (no whisper/llama)
```

The platform label is derived from `uname -s` and must match the one CMake
writes into `manifest.txt` — the consumer builds its download URL from exactly
these strings. Linux additionally needs `patchelf` installed (it rewrites
`libpiper.so`'s RUNPATH during staging and is a hard `find_program` requirement).

The Windows Piper-only release bundle (plugin #73/#74) is built in CI on
`windows-latest` with the same `XPWELLYS_LIBS_TTS_ONLY` option.

CI (`.github/workflows/release.yml`) builds the arm64 full bundle on `macos-15`
and the linux-x64 full bundle on `ubuntu-22.04`, link-smoke-tests each exactly
as the plugin will consume it, and on a `v*` tag publishes the tarballs as a
GitHub release.

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
