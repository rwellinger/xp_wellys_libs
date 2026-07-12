# xp_wellys_libs.cmake — shipped inside the bundle, included by the plugin's
# CMakeLists to consume the prebuilt local-inference libraries.
#
# Two bundle kinds ship from this repo:
#   * full     (arm64-macos): whisper + llama + ggml/Metal + Piper. Defines
#                both xp_wellys_libs::inference AND xp_wellys_libs::piper.
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

if(NOT EXISTS "${_xwl_lib}/libpiper.dylib")
    message(FATAL_ERROR
        "xp_wellys_libs bundle incomplete: ${_xwl_lib}/libpiper.dylib missing. "
        "Re-run `make setup` in the plugin repo to download it.")
endif()

# ── Piper-only target — present in EVERY bundle ──────────────────────────────
# The self-contained Piper dylib (statically bundles espeak-ng) + the
# onnxruntime dylib it resolves via @loader_path. Pure CPU: no whisper/llama,
# no Metal. This is what the plugin's hybrid TTS slices link (issue #69).
add_library(xp_wellys_libs::piper INTERFACE IMPORTED)
target_include_directories(xp_wellys_libs::piper INTERFACE "${_xwl_inc}")
target_link_libraries(xp_wellys_libs::piper INTERFACE
    "${_xwl_lib}/libpiper.dylib"
    "${_xwl_lib}/libonnxruntime.1.22.0.dylib"
)

# ── Full inference target — only in the arm64 full bundle ─────────────────────
# Static archives in dependency order, then Piper + onnxruntime, then the Apple
# frameworks ggml-metal / Accelerate pull in. macOS ld64 re-scans archives, so
# this order matters. Absent from tts-only bundles (no libwhisper.a).
if(EXISTS "${_xwl_lib}/libwhisper.a")
    add_library(xp_wellys_libs::inference INTERFACE IMPORTED)
    target_include_directories(xp_wellys_libs::inference INTERFACE
        "${_xwl_inc}"
        "${_xwl_inc}/ggml"
        "${_xwl_inc}/common"
    )
    target_link_libraries(xp_wellys_libs::inference INTERFACE
        "${_xwl_lib}/libwhisper.a"
        "${_xwl_lib}/libllama-common.a"
        "${_xwl_lib}/libllama-common-base.a"
        "${_xwl_lib}/libllama.a"
        "${_xwl_lib}/libggml-metal.a"
        "${_xwl_lib}/libggml-cpu.a"
        "${_xwl_lib}/libggml-base.a"
        "${_xwl_lib}/libggml.a"
        "${_xwl_lib}/libpiper.dylib"
        "${_xwl_lib}/libonnxruntime.1.22.0.dylib"
        "-framework Metal"
        "-framework MetalKit"
        "-framework Foundation"
        "-framework Accelerate"
    )
endif()
