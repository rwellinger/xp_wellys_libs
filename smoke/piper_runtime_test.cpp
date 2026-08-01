// Runtime smoke test for libpiper: actually creates a synthesizer and speaks a
// sentence, outside any host application.
//
// Why this exists: on Windows, piper_create was taking X-Plane down from inside
// the xp_wellys_vfr_atc plugin, with three different faces depending on how the
// DLL was linked (delay-load thunk 0xC06D007E, ERROR_DLL_INIT_FAILED 1114, and
// an access violation 0xC0000005 inside piper.dll itself). Inside a host that
// large, the plugin loader, the delay-load machinery and the CRT boundary all
// overlap and none of them can be ruled out. This binary removes every one of
// them: no host, no delay-load, no plugin.
//
//   crashes here  -> libpiper/onnxruntime is broken as built; fix belongs here
//   works here    -> the library is fine and the fault is in how the host
//                    embeds it
//
// Usage:
//   piper_runtime_test <voice.onnx> <voice.onnx.json> <espeak-ng-data-dir>
//
// Put it next to piper.dll / onnxruntime.dll so the loader resolves them from
// the executable's own directory.

#include "piper.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>

#if defined(_WIN32)
#include <windows.h>
#endif

namespace {

void step(const char *msg) {
  // Unbuffered: if the next call takes the process down, we still know how far
  // it got. That is the whole point of this program.
  std::printf("[ .. ] %s\n", msg);
  std::fflush(stdout);
}

void ok(const char *msg) {
  std::printf("[ OK ] %s\n", msg);
  std::fflush(stdout);
}

void fail(const char *msg) {
  std::printf("[FAIL] %s\n", msg);
  std::fflush(stdout);
}

#if defined(_WIN32)
// Catch the access violation instead of letting Windows kill us silently, so
// the exception code makes it to the console.
piper_synthesizer *create_guarded(const char *onnx, const char *json,
                                  const char *espeak, unsigned long *code) {
  *code = 0;
  __try {
    return piper_create(onnx, json, espeak);
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    *code = static_cast<unsigned long>(GetExceptionCode());
    return nullptr;
  }
}
#endif

} // namespace

int main(int argc, char **argv) {
  if (argc != 4) {
    std::printf("usage: %s <voice.onnx> <voice.onnx.json> <espeak-ng-data>\n",
                argv[0]);
    return 2;
  }
  const char *onnx = argv[1];
  const char *json = argv[2];
  const char *espeak = argv[3];

  std::printf("piper runtime smoke test\n");
  std::printf("  onnx   : %s\n", onnx);
  std::printf("  json   : %s\n", json);
  std::printf("  espeak : %s\n\n", espeak);

#if defined(_WIN32)
  // Which piper.dll actually got loaded, and from where. A stale copy elsewhere
  // on the search path would explain a lot and is invisible otherwise.
  step("resolving piper.dll");
  if (HMODULE h = GetModuleHandleW(L"piper.dll")) {
    wchar_t path[1024] = {};
    if (GetModuleFileNameW(h, path, 1024)) {
      std::wprintf(L"       loaded from: %ls\n", path);
      std::fflush(stdout);
    }
  } else {
    std::printf("       (not yet mapped - it is a load-time import here, so "
                "this is unexpected)\n");
  }
#endif

  step("piper_create (ONNX session init + voice config + espeak-ng)");
#if defined(_WIN32)
  unsigned long seh = 0;
  piper_synthesizer *synth = create_guarded(onnx, json, espeak, &seh);
  if (seh != 0) {
    std::printf("[FAIL] piper_create raised structured exception 0x%08lX\n",
                seh);
    std::printf("       0xC0000005 access violation | 0xC0000135 missing DLL | "
                "0xC0000142 DLL init failed\n");
    return 1;
  }
#else
  piper_synthesizer *synth = piper_create(onnx, json, espeak);
#endif
  if (!synth) {
    fail("piper_create returned null (check the three paths above)");
    return 1;
  }
  ok("piper_create");

  step("piper_synthesize_start");
  piper_synthesize_options opts = piper_default_synthesize_options(synth);
  const char *text = "Hallo, hier ist Friedrichshafen Turm.";
  if (piper_synthesize_start(synth, text, &opts) != 0) {
    fail("piper_synthesize_start");
    piper_free(synth);
    return 1;
  }
  ok("piper_synthesize_start");

  step("piper_synthesize_next (draining chunks)");
  piper_audio_chunk chunk;
  std::memset(&chunk, 0, sizeof(chunk));
  size_t total = 0;
  int chunks = 0;
  int rate = 0;
  while (piper_synthesize_next(synth, &chunk) == 0) {
    total += chunk.num_samples;
    rate = chunk.sample_rate;
    ++chunks;
    if (chunks > 10000)
      break; // runaway guard
  }
  std::printf("[ OK ] synthesized %zu samples in %d chunks at %d Hz",
              total, chunks, rate);
  if (rate > 0)
    std::printf(" (%.2f s of audio)", static_cast<double>(total) / rate);
  std::printf("\n");

  step("piper_free");
  piper_free(synth);
  ok("piper_free");

  std::printf("\nALL GOOD - libpiper works standalone on this machine.\n");
  return total > 0 ? 0 : 1;
}
