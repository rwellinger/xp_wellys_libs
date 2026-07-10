# xp_wellys_libs

Prebuilt **arm64 macOS** local-inference libraries for
[xp_wellys_vfr_atc](https://github.com/rwellinger/xp_wellys_vfr_atc).

whisper.cpp + llama.cpp + ggml (Metal) + Piper + espeak-ng, compiled **once
per pin bump** and published as a versioned binary bundle. The plugin
downloads the bundle in `make setup` instead of compiling it from source —
turning its ~50 min cold release build into a deterministic ~5–8 min one.

See [DESIGN.md](DESIGN.md) for the full rationale, bundle layout, link-order
handling, toolchain pinning, and the plugin-side consumption flow.

## Build locally

```bash
make setup     # init the whisper.cpp / llama.cpp / piper1-gpl submodules
make build     # compile everything (the slow part; Homebrew LLVM auto-pinned)
make bundle    # stage build/bundle/ (libs + headers + espeak-ng-data)
make tarball   # -> xp_wellys_libs-arm64-macos-<version>.tar.gz
```

CI (`.github/workflows/release.yml`) does the same on `macos-15`, link-smoke-
tests the bundle exactly as the plugin will consume it, and on a `v*` tag
publishes the tarball as a GitHub release.

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
