# xp_wellys_libs.cmake — shipped inside the bundle, included by the plugin's
# CMakeLists to consume the prebuilt local-inference libraries.
#
# Three bundle kinds ship from this repo:
#   * full     (arm64-macos): whisper + llama + ggml/Metal + Piper. Defines
#                both xp_wellys_libs::inference AND xp_wellys_libs::piper.
#   * full     (linux-x64):   same, but plain-CPU ggml (no Metal/Accelerate).
#   * tts-only (win-x64, planned #73/#74): Piper + onnxruntime only. Defines
#                xp_wellys_libs::piper. No whisper/llama/Metal.
#
# Usage (plugin repo):
#   set(XP_WELLYS_LIBS_ROOT "${CMAKE_SOURCE_DIR}/vendor/prebuilt/xp_wellys_libs")
#   include(${XP_WELLYS_LIBS_ROOT}/xp_wellys_libs.cmake)
#   # full local slice:
#   target_link_libraries(xp_wellys_vfr_atc PRIVATE xp_wellys_libs::inference)
#   # hybrid TTS-only slice:
#   target_link_libraries(xp_wellys_vfr_atc PRIVATE xp_wellys_libs::piper)
#
# The link ORDER of the full target is the one real risk of the prebuilt
# approach and is validated by the smoke test in this repo's CI before any
# release is cut.

if(NOT DEFINED XP_WELLYS_LIBS_ROOT)
    message(FATAL_ERROR
        "XP_WELLYS_LIBS_ROOT must point at the extracted xp_wellys_libs bundle")
endif()

set(_xwl_lib "${XP_WELLYS_LIBS_ROOT}/lib")
set(_xwl_inc "${XP_WELLYS_LIBS_ROOT}/include")

# One tarball per platform, so bundle platform == consumer platform by
# construction. Catch a tarball extracted into the wrong tree (hand-copied,
# stale, mis-scripted CI) here rather than 200 lines later as a confusing
# "libpiper.so missing" -- manifest.txt's first line is
# "xp_wellys_libs <ver>  (<platform>, <kind>)".
if(APPLE)
    set(_xwl_expect "arm64-macos")
elseif(WIN32)
    set(_xwl_expect "win-x64")
else()
    set(_xwl_expect "linux-x64")
endif()
if(EXISTS "${XP_WELLYS_LIBS_ROOT}/manifest.txt")
    file(STRINGS "${XP_WELLYS_LIBS_ROOT}/manifest.txt" _xwl_hdr LIMIT_COUNT 1)
    if(NOT _xwl_hdr MATCHES "\\(${_xwl_expect}[,)]")
        message(FATAL_ERROR
            "xp_wellys_libs bundle platform mismatch: this build needs "
            "${_xwl_expect}, but the bundle says: ${_xwl_hdr}")
    endif()
endif()

# The Piper artefact differs by platform: a self-contained dylib on macOS, a
# .so on Linux, a DLL + import .lib on Windows. Pick the linkable file (the one
# the consumer links against) and use it both for the completeness check and
# the target.
if(WIN32)
    set(_xwl_piper_link "${_xwl_lib}/piper.lib")
    set(_xwl_onnx_link  "${_xwl_lib}/onnxruntime.lib")
elseif(APPLE)
    set(_xwl_piper_link "${_xwl_lib}/libpiper.dylib")
    set(_xwl_onnx_link  "${_xwl_lib}/libonnxruntime.1.22.0.dylib")
else()
    set(_xwl_piper_link "${_xwl_lib}/libpiper.so")
    set(_xwl_onnx_link  "${_xwl_lib}/libonnxruntime.so.1.22.0")
endif()

if(NOT EXISTS "${_xwl_piper_link}")
    message(FATAL_ERROR
        "xp_wellys_libs bundle incomplete: ${_xwl_piper_link} missing. "
        "Re-run `make setup` in the plugin repo to download it.")
endif()

# ── Piper-only target — present in EVERY bundle ──────────────────────────────
# The self-contained Piper library (statically bundles espeak-ng) + onnxruntime.
# Pure CPU: no whisper/llama, no Metal. This is what the plugin's hybrid TTS
# slices link (issue #69). On macOS the .dylib resolves onnxruntime via
# @loader_path; on Windows the consumer links piper.lib/onnxruntime.lib and
# ships piper.dll + onnxruntime.dll next to the plugin.
add_library(xp_wellys_libs::piper INTERFACE IMPORTED)
target_include_directories(xp_wellys_libs::piper INTERFACE "${_xwl_inc}")
target_link_libraries(xp_wellys_libs::piper INTERFACE
    "${_xwl_piper_link}"
    "${_xwl_onnx_link}"
)

# ── Full inference target — only in the full bundles ──────────────────────────
# Static archives in dependency order, then Piper + onnxruntime, then the
# platform's system dependencies. Absent from tts-only bundles (no libwhisper.a).
if(EXISTS "${_xwl_lib}/libwhisper.a")
    add_library(xp_wellys_libs::inference INTERFACE IMPORTED)
    target_include_directories(xp_wellys_libs::inference INTERFACE
        "${_xwl_inc}"
        "${_xwl_inc}/ggml"
        "${_xwl_inc}/common"
    )

    # ggml-metal only exists in a Metal-enabled (macOS) bundle. Decide on the
    # bundle's CONTENT rather than on if(APPLE) -- the archive list should
    # describe what is actually there.
    set(_xwl_static
        "${_xwl_lib}/libwhisper.a"
        "${_xwl_lib}/libllama-common.a"
        "${_xwl_lib}/libllama-common-base.a"
        "${_xwl_lib}/libllama.a")
    if(EXISTS "${_xwl_lib}/libggml-metal.a")
        list(APPEND _xwl_static "${_xwl_lib}/libggml-metal.a")
    endif()
    list(APPEND _xwl_static
        "${_xwl_lib}/libggml-cpu.a"
        "${_xwl_lib}/libggml-base.a"
        "${_xwl_lib}/libggml.a")

    if(APPLE)
        # ld64 re-scans archives, so a single dependency-ordered pass links.
        target_link_libraries(xp_wellys_libs::inference INTERFACE
            ${_xwl_static}
            "${_xwl_piper_link}"
            "${_xwl_onnx_link}"
            "-framework Metal"
            "-framework MetalKit"
            "-framework Foundation"
            "-framework Accelerate"
        )
    else()
        # GNU ld does NOT re-scan archives the way ld64 does, and ggml <->
        # ggml-base/ggml-cpu reference each other, so one ordered pass is
        # brittle. --start-group removes the ordering risk outright for a few
        # extra link seconds. lld and mold honour it too.
        find_package(Threads REQUIRED)
        target_link_libraries(xp_wellys_libs::inference INTERFACE
            "-Wl,--start-group" ${_xwl_static} "-Wl,--end-group"
            "${_xwl_piper_link}"
            "${_xwl_onnx_link}"
            # ggml links these PRIVATE onto ggml-base upstream via CMake
            # targets; shipping raw .a paths drops that, so re-state them.
            Threads::Threads
            ${CMAKE_DL_LIBS}
            m
        )
    endif()
endif()
