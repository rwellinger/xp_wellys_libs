cmake_minimum_required(VERSION 3.26)
project(xp_wellys_libs_smoke CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OSX_ARCHITECTURES "arm64")
set(CMAKE_OSX_DEPLOYMENT_TARGET "13.3")

if(NOT DEFINED XP_WELLYS_LIBS_ROOT)
    message(FATAL_ERROR "pass -DXP_WELLYS_LIBS_ROOT=<extracted bundle root>")
endif()

# Consume the bundle exactly as the plugin will.
include("${XP_WELLYS_LIBS_ROOT}/xp_wellys_libs.cmake")

add_executable(link_test link_test.cpp)
target_link_libraries(link_test PRIVATE xp_wellys_libs::inference)
