// Link-only smoke test for a Piper-only bundle. Referencing a piper symbol
// forces the linker to resolve libpiper.dylib (which in turn pulls
// onnxruntime via @loader_path). No model is loaded — piper_create needs real
// files; taking the function's address is enough to prove the dylib links.
// The plugin's Catch2 suite proves synthesis actually runs.
#include "piper.h"
#include <cstdio>

int main() {
    void *sym = reinterpret_cast<void *>(&piper_create);
    std::printf("piper linked: piper_create=%p\n", sym);
    return sym ? 0 : 1;
}
