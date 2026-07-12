# Run in -P script mode from the bundle target. Writes ${BUNDLE}/manifest.txt:
# the SHA256 of every staged lib plus the source submodule pins, so the plugin
# repo can verify the download and correlate it to exact upstream revisions.
file(READ "${SRC}/VERSION.txt" _ver)
string(STRIP "${_ver}" _ver)

# ARCH ("arm64" | "x86_64") and TTS_ONLY ("ON"/"OFF") are passed by the caller
# (CMakeLists bundle target). Default to the historical arm64 full bundle.
if(NOT DEFINED ARCH)
    set(ARCH "arm64")
endif()
if(TTS_ONLY)
    set(_kind "tts-only")
else()
    set(_kind "full")
endif()

set(_out "xp_wellys_libs ${_ver}  (${ARCH}-macos, ${_kind})\n")
string(APPEND _out "\n[libs]\n")
file(GLOB _libs "${BUNDLE}/lib/*")
list(SORT _libs)
foreach(_f ${_libs})
    get_filename_component(_name "${_f}" NAME)
    # Skip symlinks (the libonnxruntime.dylib alias) — hashing the target is
    # enough and file(SHA256) on a dangling/relative symlink is unreliable.
    if(IS_SYMLINK "${_f}")
        string(APPEND _out "symlink  ${_name}\n")
    else()
        file(SHA256 "${_f}" _h)
        string(APPEND _out "${_h}  ${_name}\n")
    endif()
endforeach()

string(APPEND _out "\n[submodule pins]\n")
execute_process(
    COMMAND git -C "${SRC}" submodule status --recursive
    OUTPUT_VARIABLE _subs
    OUTPUT_STRIP_TRAILING_WHITESPACE
    ERROR_QUIET)
string(APPEND _out "${_subs}\n")

file(WRITE "${BUNDLE}/manifest.txt" "${_out}")
message(STATUS "Wrote ${BUNDLE}/manifest.txt")
