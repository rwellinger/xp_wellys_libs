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

# ── Shared ggml / Metal options (lifted verbatim from the plugin build) ──────
# Order matters: llama.cpp is added FIRST so its pinned `ggml` target wins;
# whisper.cpp then reuses that target instead of pulling a second copy.
set(BUILD_SHARED_LIBS        OFF CACHE BOOL "" FORCE)
set(GGML_METAL               ON  CACHE BOOL "" FORCE)
set(GGML_METAL_EMBED_LIBRARY ON  CACHE BOOL "" FORCE)
set(GGML_ACCELERATE          ON  CACHE BOOL "" FORCE)
set(GGML_BLAS                OFF CACHE BOOL "" FORCE)

# ── llama.cpp (provides ggml, llama, llama-common) ───────────────────────────
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

# ── whisper.cpp (provides whisper; reuses llama's ggml target) ───────────────
set(WHISPER_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_TESTS    OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_SERVER   OFF CACHE BOOL "" FORCE)
add_subdirectory(${TP}/whisper.cpp ${CMAKE_BINARY_DIR}/whisper.cpp EXCLUDE_FROM_ALL)

# ── Piper (provides piper; pulls espeak-ng static + onnxruntime prebuilt) ────
add_subdirectory(${TP}/piper1-gpl/libpiper ${CMAKE_BINARY_DIR}/libpiper EXCLUDE_FROM_ALL)

set(ESPEAK_DATA_DIR "${CMAKE_BINARY_DIR}/espeak_ng-install/share/espeak-ng-data")
set(ONNX_LIB_DIR
    "${TP}/piper1-gpl/libpiper/lib/onnxruntime-osx-arm64-1.22.0/lib")

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
        "${BUNDLE}/lib" "${BUNDLE}/include" "${BUNDLE}/include/ggml"
        "${BUNDLE}/include/common" "${BUNDLE}/share"
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

# Headers (configure-time paths in the submodule source trees).
add_custom_command(TARGET bundle POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        "${TP}/whisper.cpp/include/whisper.h" "${BUNDLE}/include/"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        "${TP}/llama.cpp/include/llama.h" "${BUNDLE}/include/"
    COMMAND ${CMAKE_COMMAND} -E copy_directory
        "${TP}/llama.cpp/ggml/include" "${BUNDLE}/include/ggml"
    COMMAND ${CMAKE_COMMAND} -E copy_directory
        "${TP}/llama.cpp/common" "${BUNDLE}/include/common"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        "${TP}/piper1-gpl/libpiper/include/piper.h" "${BUNDLE}/include/"
    COMMENT "Copying headers into bundle"
    VERBATIM)

# onnxruntime dylibs (versioned + alias) + espeak-ng-data — produced at build
# time by Piper's ExternalProject, so this runs after piper via the dependency.
add_custom_command(TARGET bundle POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        "${ONNX_LIB_DIR}/libonnxruntime.1.22.0.dylib" "${BUNDLE}/lib/"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        "${ONNX_LIB_DIR}/libonnxruntime.dylib" "${BUNDLE}/lib/"
    COMMAND ${CMAKE_COMMAND} -E copy_directory
        "${ESPEAK_DATA_DIR}" "${BUNDLE}/share/espeak-ng-data"
    COMMENT "Copying onnxruntime dylibs + espeak-ng-data into bundle"
    VERBATIM)

# Consumer cmake + manifest (SHA256 of every lib + the submodule pins).
add_custom_command(TARGET bundle POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        "${CMAKE_SOURCE_DIR}/cmake/xp_wellys_libs.cmake" "${BUNDLE}/"
    COMMAND ${CMAKE_COMMAND}
        -DBUNDLE=${BUNDLE} -DSRC=${CMAKE_SOURCE_DIR}
        -P "${CMAKE_SOURCE_DIR}/cmake/write_manifest.cmake"
    COMMENT "Writing xp_wellys_libs.cmake + manifest.txt"
    VERBATIM)
