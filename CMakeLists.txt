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

# ── GPU backend off Apple ────────────────────────────────────────────────────
# Vulkan, deliberately NOT CUDA. A redistributable bundle must not drag CUDA's
# redist DLLs behind it (ggml-cuda ~50-160 MB plus cuBLAS/cuBLASLt in the
# hundreds of MB) — that is unacceptable for a plugin shipped through the
# SkunkCrafts updater. Vulkan needs NO extra runtime DLL: vulkan-1.dll comes
# with the graphics driver, and X-Plane 12 renders through Vulkan on Windows
# anyway, so it is present on every target system. It also covers AMD/Intel.
# Linux stays CPU-only on purpose: the ICD/driver zoo there is wide and the
# payoff (small whisper/LM models) is narrow.
if(WIN32)
    set(_xwl_vulkan_default ON)
else()
    set(_xwl_vulkan_default OFF)
endif()
option(XPWELLYS_LIBS_VULKAN
    "Build ggml with the Vulkan backend (Windows default)" ${_xwl_vulkan_default})

# arm64 + macOS 13.3, matching the plugin's local-inference slice exactly
# (onnxruntime 1.22.0's prebuilt dylib is built against the 13.3 SDK).
if(APPLE)
    if(NOT CMAKE_OSX_ARCHITECTURES)
        set(CMAKE_OSX_ARCHITECTURES "arm64")
    endif()
    set(CMAKE_OSX_DEPLOYMENT_TARGET "13.3")
endif()
set(CMAKE_BUILD_TYPE "Release" CACHE STRING "" FORCE)

# ccache if available — big win on same-pin re-runs.
# Not under MSVC: cl.exe is not a ccache-compatible launcher, and a ccache that
# merely happens to sit on the runner would break the compile rather than speed
# it up. Upstream llama.cpp keeps it off in its own Windows jobs for the same
# reason (it needs an LLVM toolchain).
find_program(CCACHE_PROGRAM ccache)
if(CCACHE_PROGRAM AND NOT MSVC)
    set(CMAKE_C_COMPILER_LAUNCHER   "${CCACHE_PROGRAM}")
    set(CMAKE_CXX_COMPILER_LAUNCHER "${CCACHE_PROGRAM}")
    message(STATUS "ccache enabled: ${CCACHE_PROGRAM}")
endif()

set(TP "${CMAKE_SOURCE_DIR}/third_party")

set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)

# whisper.cpp + llama.cpp + ggml are the STT/LM half of the bundle — Metal on
# macOS, plain CPU on Linux. Skipped entirely for a Piper-only build.
if(NOT XPWELLYS_LIBS_TTS_ONLY)
    # ── Shared ggml options (lifted verbatim from the plugin build) ──────────
    # Order matters: llama.cpp is added FIRST so its pinned `ggml` target wins;
    # whisper.cpp then reuses that target instead of pulling a second copy.
    set(GGML_BLAS                OFF CACHE BOOL "" FORCE)
    if(APPLE)
        set(GGML_METAL               ON  CACHE BOOL "" FORCE)
        set(GGML_METAL_EMBED_LIBRARY ON  CACHE BOOL "" FORCE)
        set(GGML_ACCELERATE          ON  CACHE BOOL "" FORCE)
    else()
        set(GGML_METAL               OFF CACHE BOOL "" FORCE)
        set(GGML_METAL_EMBED_LIBRARY OFF CACHE BOOL "" FORCE)
        set(GGML_ACCELERATE          OFF CACHE BOOL "" FORCE)
        # A REDISTRIBUTABLE bundle must never carry -march=native: GGML_NATIVE
        # defaults ON off-Apple, which would bake the CI runner's ISA (AVX-512
        # on some Azure SKUs) into the archives -> SIGILL on user CPUs, with no
        # stack trace, just "X-Plane crashes". OFF flips ggml's INS_ENB=ON ->
        # SSE42/AVX/AVX2/BMI2/F16C baseline. macOS-arm64 has one ISA, so this
        # only matters here.
        set(GGML_NATIVE OFF CACHE BOOL "" FORCE)
        # ggml links OpenMP PRIVATE onto ggml-base via a CMake target. We ship
        # raw .a paths, so that link info cannot survive into the bundle and the
        # consumer would hit undefined GOMP_*. ggml's own threadpool is the
        # portable choice for a prebuilt.
        set(GGML_OPENMP OFF CACHE BOOL "" FORCE)
        # The consumer links these archives into a MODULE (the .xpl shared
        # object), so every object in them must be position-independent.
        set(CMAKE_POSITION_INDEPENDENT_CODE ON)
    endif()

    # ── Vulkan GPU backend (see XPWELLYS_LIBS_VULKAN above) ──────────────────
    # With BUILD_SHARED_LIBS=OFF and GGML_BACKEND_DL=OFF, ggml_add_backend()
    # makes ggml-vulkan a plain static lib hanging PUBLIC off ggml, and
    # ggml-backend-reg.cpp calls ggml_backend_vk_reg() directly — so the linker
    # pulls it in without any whole-archive trickery. The .comp shaders are
    # compiled to SPIR-V at build time and embedded as arrays in generated .cpp:
    # there are NO .spv files to ship at runtime.
    set(GGML_VULKAN ${XPWELLYS_LIBS_VULKAN} CACHE BOOL "" FORCE)

    # ── MSVC runtime: STATIC CRT for the archives ────────────────────────────
    # The consumer builds with -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded (its
    # curl comes from vcpkg's x64-windows-static). These static archives land in
    # the SAME module as the plugin, so mixing /MD and /MT means LNK2005 — or,
    # worse, it links and then corrupts the heap on a free() across the boundary.
    #
    # CMAKE_POLICY_DEFAULT_CMP0091 is not optional here: whisper.cpp's
    # CMakeLists.txt opens with cmake_minimum_required(VERSION 3.5), which resets
    # policies in that subdirectory. CMP0091 would be unset (OLD) there and
    # CMAKE_MSVC_RUNTIME_LIBRARY silently ignored — for whisper.lib alone, which
    # is exactly the mismatch that is hardest to spot.
    if(MSVC)
        set(CMAKE_POLICY_DEFAULT_CMP0091 NEW)
        set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
    endif()

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

    # whisper.cpp sets this MSVC workaround only in its own if(NOT TARGET ggml)
    # branch — here ggml already comes from llama.cpp, so that branch never runs
    # and the define would be missing. Restate it.
    if(MSVC AND TARGET ggml-base)
        target_compile_definitions(ggml-base PRIVATE
            _DISABLE_CONSTEXPR_MUTEX_CONSTRUCTOR)
    endif()

    # Back to the dynamic CRT for Piper. piper.dll links espeak-ng.lib, which
    # libpiper builds through an ExternalProject with fixed CMAKE_ARGS that do
    # NOT forward CMAKE_MSVC_RUNTIME_LIBRARY — so espeak-ng is /MD no matter what
    # we set here, and a /MT piper.dll would fail to link against it. Across the
    # DLL boundary the CRT choice does not matter; within one module it does.
    if(MSVC)
        set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>DLL")
    endif()
endif()

# ── Piper (provides piper; pulls espeak-ng static + onnxruntime prebuilt) ────
add_subdirectory(${TP}/piper1-gpl/libpiper ${CMAKE_BINARY_DIR}/libpiper EXCLUDE_FROM_ALL)

# Two Windows-only fixes for the Piper DLL (no-ops off Windows):
if(WIN32 AND TARGET piper)
    # 1) espeak-ng is linked statically, but its speak_lib.h defaults to
    #    __declspec(dllimport) on Windows (→ unresolved __imp_espeak_* /
    #    LNK2019). LIBESPEAK_NG_EXPORT makes the header use dllexport instead,
    #    so the plain symbols resolve from the static espeak-ng.lib.
    target_compile_definitions(piper PRIVATE LIBESPEAK_NG_EXPORT)
    # 2) piper.h declares its C API without __declspec(dllexport), so piper.dll
    #    would export nothing and its import lib would be empty (consumers hit
    #    LNK2019 on piper_create). Auto-export all symbols so piper.lib carries
    #    the API. (On macOS symbols are exported by default — non-issue.)
    set_target_properties(piper PROPERTIES WINDOWS_EXPORT_ALL_SYMBOLS TRUE)
endif()

set(ESPEAK_DATA_DIR "${CMAKE_BINARY_DIR}/espeak_ng-install/share/espeak-ng-data")

# onnxruntime is fetched + extracted by libpiper into lib/onnxruntime-<prefix>/,
# where <prefix> follows the platform/arch the same way libpiper picks it (see
# its CMakeLists onnx block). Mirror that if/elseif shape EXACTLY, or we point
# at a directory libpiper never extracted. macOS ships the arm64 full bundle,
# Linux the linux-x64 full bundle, Windows the win-x64 Piper-only bundle
# (plugin #73/#74).
if(WIN32)
    set(_onnx_prefix "onnxruntime-win-x64-1.22.0")
    set(_platform "win-x64")
elseif(APPLE)
    if(CMAKE_SYSTEM_PROCESSOR STREQUAL "x86_64")
        set(_onnx_prefix "onnxruntime-osx-x86_64-1.22.0")
        set(_platform "x86_64-macos")
    else()
        set(_onnx_prefix "onnxruntime-osx-arm64-1.22.0")
        set(_platform "arm64-macos")
    endif()
elseif(CMAKE_SYSTEM_PROCESSOR STREQUAL "aarch64")
    # libpiper would happily extract onnxruntime-linux-aarch64, but no runner
    # builds or releases this and nobody has ever linked it. A branch nobody
    # tests is a lie -- fail loudly instead.
    message(FATAL_ERROR "linux-arm64 is not built/released by this repo")
else()
    set(_onnx_prefix "onnxruntime-linux-x64-1.22.0")
    set(_platform "linux-x64")
endif()
set(ONNX_LIB_DIR "${TP}/piper1-gpl/libpiper/lib/${_onnx_prefix}/lib")

# REQUIRED, not optional: patchelf rewrites libpiper.so's RUNPATH during
# staging. Without it the bundle would ship a .so pointing at a build-machine
# path and fail to load onnxruntime on every user's box.
if(UNIX AND NOT APPLE)
    find_program(PATCHELF_EXECUTABLE patchelf REQUIRED)
endif()

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
    ggml ggml-base ggml-cpu ggml-metal ggml-blas ggml-vulkan
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

# vulkan-1.lib: ggml-vulkan.cpp drives everything through the dynamic vulkan.hpp
# dispatcher, so exactly ONE symbol is left at link time (vkGetInstanceProcAddr).
# Shipping that tiny import lib means the CONSUMER's CI needs no Vulkan SDK at
# all. The matching vulkan-1.dll is NOT shipped — it comes from the graphics
# driver, and X-Plane 12 renders through Vulkan on Windows anyway.
if(WIN32 AND TARGET ggml-vulkan)
    find_package(Vulkan REQUIRED)
    add_custom_command(TARGET bundle POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "${Vulkan_LIBRARY}" "${BUNDLE}/lib/vulkan-1.lib"
        COMMENT "Copying vulkan-1 import lib into bundle"
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
    # Stage EVERY onnxruntime DLL, not just onnxruntime.dll — the win-x64
    # package can ship runtime siblings (e.g. onnxruntime_providers_shared.dll)
    # that onnxruntime.dll load-time-depends on; missing one crashes any process
    # that loads Piper. libpiper downloads + extracts onnx at configure time, so
    # the glob is populated here.
    file(GLOB _onnx_dlls "${ONNX_LIB_DIR}/*.dll")
    foreach(_dll ${_onnx_dlls})
        add_custom_command(TARGET bundle POST_BUILD
            COMMAND ${CMAKE_COMMAND} -E copy_if_different "${_dll}" "${BUNDLE}/lib/"
            VERBATIM)
    endforeach()
    add_custom_command(TARGET bundle POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "${ONNX_LIB_DIR}/onnxruntime.lib" "${BUNDLE}/lib/"
        COMMAND ${CMAKE_COMMAND} -E copy_directory
            "${ESPEAK_DATA_DIR}" "${BUNDLE}/share/espeak-ng-data"
        COMMENT "Copying onnxruntime DLLs + import lib + espeak-ng-data into bundle"
        VERBATIM)
elseif(APPLE)
    add_custom_command(TARGET bundle POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "${ONNX_LIB_DIR}/libonnxruntime.1.22.0.dylib" "${BUNDLE}/lib/"
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "${ONNX_LIB_DIR}/libonnxruntime.dylib" "${BUNDLE}/lib/"
        COMMAND ${CMAKE_COMMAND} -E copy_directory
            "${ESPEAK_DATA_DIR}" "${BUNDLE}/share/espeak-ng-data"
        COMMENT "Copying onnxruntime dylibs + espeak-ng-data into bundle"
        VERBATIM)
else()
    # libpiper.so's DT_NEEDED is the SONAME libonnxruntime.so.1, which the
    # upstream tarball does not ship (it has .so -> .so.1.22.0 only), so we
    # create it. create_symlink, NOT copy_if_different: the latter dereferences,
    # which is why the macOS bundle carries libonnxruntime.dylib as a second
    # 33 MB copy of the versioned file. Symlinks also make write_manifest emit
    # `symlink <name>` lines, which the consumer's SHA256 grep skips by design.
    add_custom_command(TARGET bundle POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "${ONNX_LIB_DIR}/libonnxruntime.so.1.22.0" "${BUNDLE}/lib/"
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "${ONNX_LIB_DIR}/libonnxruntime_providers_shared.so" "${BUNDLE}/lib/"
        COMMAND ${CMAKE_COMMAND} -E create_symlink
            libonnxruntime.so.1.22.0 "${BUNDLE}/lib/libonnxruntime.so.1"
        COMMAND ${CMAKE_COMMAND} -E create_symlink
            libonnxruntime.so.1.22.0 "${BUNDLE}/lib/libonnxruntime.so"
        # libpiper bakes an absolute build-machine RUNPATH into libpiper.so.
        # Rewrite it HERE so the bundle is self-describing: the consumer stages
        # onnxruntime next to libpiper.so and must not need to know about this.
        # DT_RUNPATH is non-transitive, but libonnxruntime.so.1 is a DIRECT
        # DT_NEEDED of libpiper.so, so $ORIGIN resolves it.
        COMMAND ${PATCHELF_EXECUTABLE} --set-rpath "$ORIGIN"
            "${BUNDLE}/lib/libpiper.so"
        COMMAND ${CMAKE_COMMAND} -E copy_directory
            "${ESPEAK_DATA_DIR}" "${BUNDLE}/share/espeak-ng-data"
        COMMENT "Copying onnxruntime .so + espeak-ng-data into bundle"
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
