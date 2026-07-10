// Link-only smoke test for the prebuilt bundle. Referencing one symbol from
// whisper and one from llama forces the linker to resolve the entire static
// ggml/whisper/llama graph in the order xp_wellys_libs.cmake declares — the
// one real risk of the prebuilt approach. No models are loaded; this proves
// the archives link, not that inference runs (the plugin's Catch2 suite does
// that). Piper + onnxruntime are self-contained dylibs, resolved by linking.
#include "whisper.h"
#include "llama.h"
#include <cstdio>

int main() {
    std::printf("whisper: %s\n", whisper_print_system_info());
    std::printf("llama:   %s\n", llama_print_system_info());
    return 0;
}
