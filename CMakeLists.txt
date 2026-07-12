cmake_minimum_required(VERSION 3.26)

# ── Toolchain ────────────────────────────────────────────────────────────────
# Use the DEFAULT compiler (Apple clang from the active Xcode), exactly like
# the plugin's own build — its Makefile sets no CMAKE_*_COMPILER. Static .a
# archives are ABI-sensitive, so matching the plugin's compiler matters, and
# Apple clang IS what the plugin uses. It is also the only clang that compiles
# Apple's SDK headers cleanly: Homebrew LLVM's newer clang errors on them
# (-Welaborated-enum-base in vDSP.h / CoreFoundation). CLAUDE.md's "Homebrew
# LLVM" note refers to clang-format / clang-tidy tooling, not the compiler.
project(xp_wellys_libs C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# ── Bundle kind ──────────────────────────────────────────────────────────────
# Default OFF: the full arm64 bundle (whisper.cpp + llama.cpp + ggml/Metal +
# Piper), exactly as before. ON: a Piper-ONLY bundle (libpiper + onnxruntime +
# espeak-ng-data, no whisper/llama/ggml/Metal) — pure CPU TTS, so it builds off
# Apple Silicon too. This feeds the plugin's hybrid mode (cloud STT/LM + local
# German Piper voice, issue #69) on the non-Apple-Silicon slices. Windows is the
# live target (built on windows-latest, plugin #73/#74); x86_64-macOS was
# dropped when GitHub retired the Intel runners.
option(XPWELLYS_LIBS_TTS_ONLY
    "Build a Piper-only bundle (no whisper/llama/ggml/Metal)" OFF)

# arm64 + macOS 13.3, matching the plugin's local-inference slice exactly
# (onnxruntime 1.22.0's prebuilt dylib is built against the 13.3 SDK).
if(NOT CMAKE_OSX_ARCHITECTURES)
    set(CMAKE_OSX_ARCHITECTURES "arm64")
endif()
set(CMAKE_OSX_DEPLOYMENT_TARGET "13.3")
set(CMAKE_BUILD_TYPE "Release" CACHE STRING "" FORCE)

# ccache if available — big win on same-pin re-runs.
find_program(CCACHE_PROGRAM ccache)
if(CCACHE_PROGRAM)
    set(CMAKE_C_COMPILER_LAUNCHER   "${CCACHE_PROGRAM}")
    set(CMAKE_CXX_COMPILER_LAUNCHER "${CCACHE_PROGRAM}")
    message(STATUS "ccache enabled: ${CCACHE_PROGRAM}")
endif()

set(TP "${CMAKE_SOURCE_DIR}/third_party")

set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)

# whisper.cpp + llama.cpp + ggml/Metal are the Metal STT/LM half of the bundle
# — arm64-only and skipped entirely for a Piper-only build.
if(NOT XPWELLYS_LIBS_TTS_ONLY)
    # ── Shared ggml / Metal options (lifted verbatim from the plugin build) ──
    # Order matters: llama.cpp is added FIRST so its pinned `ggml` target wins;
    # whisper.cpp then reuses that target instead of pulling a second copy.
    set(GGML_METAL               ON  CACHE BOOL "" FORCE)
    set(GGML_METAL_EMBED_LIBRARY ON  CACHE BOOL "" FORCE)
    set(GGML_ACCELERATE          ON  CACHE BOOL "" FORCE)
    set(GGML_BLAS                OFF CACHE BOOL "" FORCE)

    # ── llama.cpp (provides ggml, llama, llama-common) ───────────────────────
    set(LLAMA_BUILD_COMMON   ON  CACHE BOOL "" FORCE)
    set(LLAMA_BUILD_TOOLS    OFF CACHE BOOL "" FORCE)
    set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
    set(LLAMA_BUILD_SERVER   OFF CACHE BOOL "" FORCE)
    set(LLAMA_BUILD_TESTS    OFF CACHE BOOL "" FORCE)
    set(LLAMA_CURL           OFF CACHE BOOL "" FORCE)
    # See the plugin CMakeLists: leaving httplib's OpenSSL on drags a hard
    # /opt/homebrew openssl LC_LOAD_DYLIB into libcommon that does not exist on
    # end-user Macs. We never use httplib's HTTPS path.
    set(LLAMA_OPENSSL        OFF CACHE BOOL "" FORCE)
    add_subdirectory(${TP}/llama.cpp ${CMAKE_BINARY_DIR}/llama.cpp EXCLUDE_FROM_ALL)

    # ── whisper.cpp (provides whisper; reuses llama's ggml target) ───────────
    set(WHISPER_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
    set(WHISPER_BUILD_TESTS    OFF CACHE BOOL "" FORCE)
    set(WHISPER_BUILD_SERVER   OFF CACHE BOOL "" FORCE)
    add_subdirectory(${TP}/whisper.cpp ${CMAKE_BINARY_DIR}/whisper.cpp EXCLUDE_FROM_ALL)
endif()

# ── Piper (provides piper; pulls espeak-ng static + onnxruntime prebuilt) ────
add_subdirectory(${TP}/piper1-gpl/libpiper ${CMAKE_BINARY_DIR}/libpiper EXCLUDE_FROM_ALL)

set(ESPEAK_DATA_DIR "${CMAKE_BINARY_DIR}/espeak_ng-install/share/espeak-ng-data")

# onnxruntime is fetched + extracted by libpiper into lib/onnxruntime-<prefix>/,
# where <prefix> follows the platform/arch the same way libpiper picks it (see
# its CMakeLists onnx block). Derive the staging dir + the bundle platform label
# the same way. macOS ships only the arm64 full bundle; Windows ships the
# win-x64 Piper-only bundle (plugin #73/#74).
if(WIN32)
    set(_onnx_prefix "onnxruntime-win-x64-1.22.0")
    set(_platform "win-x64")
elseif(CMAKE_SYSTEM_PROCESSOR STREQUAL "x86_64")
    set(_onnx_prefix "onnxruntime-osx-x86_64-1.22.0")
    set(_platform "x86_64-macos")
else()
    set(_onnx_prefix "onnxruntime-osx-arm64-1.22.0")
    set(_platform "arm64-macos")
endif()
set(ONNX_LIB_DIR "${TP}/piper1-gpl/libpiper/lib/${_onnx_prefix}/lib")

# ── Bundle target ────────────────────────────────────────────────────────────
# Copies each built archive + the Piper/onnx dylibs + headers + espeak-ng-data
# into build/bundle/, then writes manifest.txt. `make bundle` (or
# `cmake --build build --target bundle`) produces the release tree.
set(BUNDLE "${CMAKE_BINARY_DIR}/bundle")

# Every static/shared target we might have built. Guarded by if(TARGET) so an
# upstream rename (e.g. ggml-blas absent because GGML_BLAS=OFF) is harmless.
# Modern llama.cpp splits the common helper into `llama-common` +
# `llama-common-base`; older pins used a single `common`. All guarded by
# if(TARGET), so whichever set exists is staged.
set(_bundle_targets
    whisper llama llama-common llama-common-base common
    ggml ggml-base ggml-cpu ggml-metal ggml-blas
    piper)

add_custom_target(bundle
    COMMAND ${CMAKE_COMMAND} -E make_directory
        "${BUNDLE}/lib" "${BUNDLE}/include" "${BUNDLE}/share"
    COMMENT "Staging xp_wellys_libs bundle -> ${BUNDLE}"
    VERBATIM)

set(_present_targets "")
foreach(t ${_bundle_targets})
    if(TARGET ${t})
        list(APPEND _present_targets ${t})
        add_custom_command(TARGET bundle POST_BUILD
            COMMAND ${CMAKE_COMMAND} -E copy_if_different
                "$<TARGET_FILE:${t}>" "${BUNDLE}/lib/"
            VERBATIM)
    endif()
endforeach()
add_dependencies(bundle ${_present_targets})

# On Windows a SHARED lib splits into the runtime DLL ($<TARGET_FILE>, staged
# above) and the import .lib the consumer links against ($<TARGET_LINKER_FILE>).
# Stage piper's import lib too. On macOS the dylib IS its own linker file, so
# this is Windows-only.
if(WIN32 AND TARGET piper)
    add_custom_command(TARGET bundle POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "$<TARGET_LINKER_FILE:piper>" "${BUNDLE}/lib/"
        VERBATIM)
endif()

# Headers (configure-time paths in the submodule source trees). piper.h is
# always staged; the whisper/llama/ggml/common headers only in the full bundle.
add_custom_command(TARGET bundle POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        "${TP}/piper1-gpl/libpiper/include/piper.h" "${BUNDLE}/include/"
    COMMENT "Copying piper.h into bundle"
    VERBATIM)
if(NOT XPWELLYS_LIBS_TTS_ONLY)
    add_custom_command(TARGET bundle POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E make_directory
            "${BUNDLE}/include/ggml" "${BUNDLE}/include/common"
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "${TP}/whisper.cpp/include/whisper.h" "${BUNDLE}/include/"
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "${TP}/llama.cpp/include/llama.h" "${BUNDLE}/include/"
        COMMAND ${CMAKE_COMMAND} -E copy_directory
            "${TP}/llama.cpp/ggml/include" "${BUNDLE}/include/ggml"
        COMMAND ${CMAKE_COMMAND} -E copy_directory
            "${TP}/llama.cpp/common" "${BUNDLE}/include/common"
        COMMENT "Copying whisper/llama/ggml/common headers into bundle"
        VERBATIM)
endif()

# onnxruntime runtime libs + espeak-ng-data — produced at build time by Piper's
# ExternalProject, so this runs after piper via the dependency. Windows ships
# onnxruntime.dll + its import .lib; macOS ships the versioned dylib + alias.
if(WIN32)
    add_custom_command(TARGET bundle POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "${ONNX_LIB_DIR}/onnxruntime.dll" "${BUNDLE}/lib/"
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "${ONNX_LIB_DIR}/onnxruntime.lib" "${BUNDLE}/lib/"
        COMMAND ${CMAKE_COMMAND} -E copy_directory
            "${ESPEAK_DATA_DIR}" "${BUNDLE}/share/espeak-ng-data"
        COMMENT "Copying onnxruntime.dll + import lib + espeak-ng-data into bundle"
        VERBATIM)
else()
    add_custom_command(TARGET bundle POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "${ONNX_LIB_DIR}/libonnxruntime.1.22.0.dylib" "${BUNDLE}/lib/"
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "${ONNX_LIB_DIR}/libonnxruntime.dylib" "${BUNDLE}/lib/"
        COMMAND ${CMAKE_COMMAND} -E copy_directory
            "${ESPEAK_DATA_DIR}" "${BUNDLE}/share/espeak-ng-data"
        COMMENT "Copying onnxruntime dylibs + espeak-ng-data into bundle"
        VERBATIM)
endif()

# Consumer cmake + manifest (SHA256 of every lib + the submodule pins).
add_custom_command(TARGET bundle POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        "${CMAKE_SOURCE_DIR}/cmake/xp_wellys_libs.cmake" "${BUNDLE}/"
    COMMAND ${CMAKE_COMMAND}
        -DBUNDLE=${BUNDLE} -DSRC=${CMAKE_SOURCE_DIR}
        -DPLATFORM=${_platform} -DTTS_ONLY=${XPWELLYS_LIBS_TTS_ONLY}
        -P "${CMAKE_SOURCE_DIR}/cmake/write_manifest.cmake"
    COMMENT "Writing xp_wellys_libs.cmake + manifest.txt"
    VERBATIM)
