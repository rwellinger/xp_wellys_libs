# xp_wellys_libs.cmake — shipped inside the bundle, included by the plugin's
# CMakeLists to consume the prebuilt local-inference libraries.
#
# Three bundles ship from this repo, all of them "full":
#   * arm64-macos: whisper + llama + ggml/Metal + Piper. Defines both
#                  xp_wellys_libs::inference AND xp_wellys_libs::piper.
#   * linux-x64:   same, but plain-CPU ggml (no Metal/Accelerate).
#   * win-x64:     same, with ggml/Vulkan as the GPU backend. NOTE: its static
#                  archives are built with the STATIC MSVC runtime (/MT) — see
#                  the guard in the WIN32 branch below.
# A tts-only bundle (Piper + onnxruntime, no whisper/llama) is still buildable
# via XPWELLYS_LIBS_TTS_ONLY, but no longer released for any platform.
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
    set(_xwl_ar_pre "")
    set(_xwl_ar_suf ".lib")
elseif(APPLE)
    set(_xwl_piper_link "${_xwl_lib}/libpiper.dylib")
    set(_xwl_onnx_link  "${_xwl_lib}/libonnxruntime.1.22.0.dylib")
    set(_xwl_ar_pre "lib")
    set(_xwl_ar_suf ".a")
else()
    set(_xwl_piper_link "${_xwl_lib}/libpiper.so")
    set(_xwl_onnx_link  "${_xwl_lib}/libonnxruntime.so.1.22.0")
    set(_xwl_ar_pre "lib")
    set(_xwl_ar_suf ".a")
endif()

# One static-archive path in the target platform's naming scheme: libwhisper.a
# on macOS/Linux, whisper.lib under MSVC. The archive NAMES differ per platform;
# the questions asked about them below ("is whisper in this bundle?", "did it
# come with a GPU backend?") do not.
function(_xwl_archive name out)
    set(${out} "${_xwl_lib}/${_xwl_ar_pre}${name}${_xwl_ar_suf}" PARENT_SCOPE)
endfunction()

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
_xwl_archive(whisper _xwl_whisper)
if(EXISTS "${_xwl_whisper}")
    add_library(xp_wellys_libs::inference INTERFACE IMPORTED)
    target_include_directories(xp_wellys_libs::inference INTERFACE
        "${_xwl_inc}"
        "${_xwl_inc}/ggml"
        "${_xwl_inc}/common"
    )

    set(_xwl_static "")
    foreach(_a whisper llama-common llama-common-base llama)
        _xwl_archive(${_a} _xwl_p)
        list(APPEND _xwl_static "${_xwl_p}")
    endforeach()
    # GPU backends: ggml-metal on macOS, ggml-vulkan on Windows. Decide on the
    # bundle's CONTENT rather than on if(APPLE)/if(WIN32) -- the archive list
    # should describe what is actually there.
    foreach(_a ggml-metal ggml-vulkan)
        _xwl_archive(${_a} _xwl_p)
        if(EXISTS "${_xwl_p}")
            list(APPEND _xwl_static "${_xwl_p}")
        endif()
    endforeach()
    foreach(_a ggml-cpu ggml-base ggml)
        _xwl_archive(${_a} _xwl_p)
        list(APPEND _xwl_static "${_xwl_p}")
    endforeach()

    if(WIN32)
        # These archives are built with the STATIC MSVC runtime (/MT). They link
        # into the SAME module as the plugin, so a /MD consumer means LNK2005 --
        # or two CRT heaps in one module, which surfaces as a crash on the first
        # free() across the boundary. Fail at configure time instead.
        if(NOT CMAKE_MSVC_RUNTIME_LIBRARY MATCHES "^MultiThreaded(Debug)?$")
            message(FATAL_ERROR
                "xp_wellys_libs (win-x64) is built against the STATIC MSVC "
                "runtime. Set -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded in the "
                "consuming build (current value: '${CMAKE_MSVC_RUNTIME_LIBRARY}').")
        endif()
        # link.exe resolves cross-references between .lib files regardless of
        # order, so there is no --start-group equivalent to reach for and no
        # ordering risk. The list stays in dependency order for readability.
        #
        # vulkan-1.lib is the Vulkan LOADER import lib and lives IN THE BUNDLE:
        # ggml-vulkan needs only vkGetInstanceProcAddr at link time (everything
        # else goes through the dynamic vulkan.hpp dispatcher), so shipping it
        # means the consuming build needs no Vulkan SDK. The matching
        # vulkan-1.dll comes from the graphics driver -- X-Plane 12 renders
        # through Vulkan on Windows, so it is present on every target system.
        target_link_libraries(xp_wellys_libs::inference INTERFACE
            ${_xwl_static}
            "${_xwl_piper_link}"
            "${_xwl_onnx_link}"
        )
        if(EXISTS "${_xwl_lib}/vulkan-1.lib")
            target_link_libraries(xp_wellys_libs::inference INTERFACE
                "${_xwl_lib}/vulkan-1.lib")
        endif()
    elseif(APPLE)
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
