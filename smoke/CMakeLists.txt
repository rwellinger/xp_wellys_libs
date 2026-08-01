cmake_minimum_required(VERSION 3.26)
project(xp_wellys_libs_smoke CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
# Match the bundle's arch/deployment. Caller may override -DCMAKE_OSX_ARCHITECTURES
# (x86_64 for a Piper-only x86_64 bundle); default arm64 like the full bundle.
if(APPLE)
    if(NOT CMAKE_OSX_ARCHITECTURES)
        set(CMAKE_OSX_ARCHITECTURES "arm64")
    endif()
    set(CMAKE_OSX_DEPLOYMENT_TARGET "13.3")
endif()

if(NOT DEFINED XP_WELLYS_LIBS_ROOT)
    message(FATAL_ERROR "pass -DXP_WELLYS_LIBS_ROOT=<extracted bundle root>")
endif()

# Consume the bundle exactly as the plugin will.
include("${XP_WELLYS_LIBS_ROOT}/xp_wellys_libs.cmake")

# Full bundle -> link the whole whisper/llama/ggml graph in declared order
# (the one real link-order risk). Piper-only bundle -> link libpiper alone.
if(TARGET xp_wellys_libs::inference)
    add_executable(link_test link_test.cpp)
    target_link_libraries(link_test PRIVATE xp_wellys_libs::inference)
    # The plugin links ::piper on its own too (the hybrid TTS override is
    # available in every mode), so a full bundle must prove BOTH targets link,
    # not just the inference one.
    add_executable(piper_link_test piper_link_test.cpp)
    target_link_libraries(piper_link_test PRIVATE xp_wellys_libs::piper)
endif()

# Runtime test: actually creates a synthesizer and speaks. NOT run in CI (the
# runner has no voice model, and onnxruntime's init is unreliable in a headless
# session) — it is shipped so it can be run ON THE TARGET MACHINE, where it
# isolates libpiper from the host application entirely. See the file header.
if(TARGET xp_wellys_libs::piper)
    add_executable(piper_runtime_test piper_runtime_test.cpp)
    target_link_libraries(piper_runtime_test PRIVATE xp_wellys_libs::piper)
else()
    add_executable(link_test piper_link_test.cpp)
    target_link_libraries(link_test PRIVATE xp_wellys_libs::piper)
endif()
