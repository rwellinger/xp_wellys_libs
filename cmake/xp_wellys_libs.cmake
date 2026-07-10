# xp_wellys_libs.cmake — shipped inside the bundle, included by the plugin's
# CMakeLists to consume the prebuilt arm64 local-inference libraries.
#
# Usage (plugin repo):
#   set(XP_WELLYS_LIBS_ROOT "${CMAKE_SOURCE_DIR}/vendor/prebuilt/xp_wellys_libs")
#   include(${XP_WELLYS_LIBS_ROOT}/xp_wellys_libs.cmake)
#   target_link_libraries(xp_wellys_vfr_atc PRIVATE xp_wellys_libs::inference)
#
# The link ORDER below is the one real risk of the prebuilt approach and is
# validated by the plugin build in this repo's CI before any release is cut.

if(NOT DEFINED XP_WELLYS_LIBS_ROOT)
    message(FATAL_ERROR
        "XP_WELLYS_LIBS_ROOT must point at the extracted xp_wellys_libs bundle")
endif()

set(_xwl_lib "${XP_WELLYS_LIBS_ROOT}/lib")
set(_xwl_inc "${XP_WELLYS_LIBS_ROOT}/include")

if(NOT EXISTS "${_xwl_lib}/libwhisper.a")
    message(FATAL_ERROR
        "xp_wellys_libs bundle incomplete: ${_xwl_lib}/libwhisper.a missing. "
        "Re-run `make setup` in the plugin repo to download it.")
endif()

add_library(xp_wellys_libs::inference INTERFACE IMPORTED)

target_include_directories(xp_wellys_libs::inference INTERFACE
    "${_xwl_inc}"
    "${_xwl_inc}/ggml"
    "${_xwl_inc}/common"
)

# Static archives in dependency order, then the self-contained Piper dylib
# (statically bundles espeak-ng) + the onnxruntime dylib it resolves via
# @loader_path, then the Apple frameworks ggml-metal / Accelerate pull in.
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
