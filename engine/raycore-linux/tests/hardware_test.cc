#include <cstdio>
#include <cstdlib>
#include <limits>
#include <string>

#include "ray/linux/ac_linux_hardware.h"

using namespace ray::linux_hardware;

namespace {

void Expect(bool condition, const char* what) {
  if (!condition) {
    std::fprintf(stderr, "failed: %s\n", what);
    std::abort();
  }
}

}

int main() {
  Expect(MemoryGB(0) == 0 && MemoryGB(16ull << 30) == 16, "whole gigabytes");
  Expect(MemoryGB(16473620480ull) == 15 && MemoryGB(33536192512ull) == 31, "what the kernel reports rounds to the nearest gigabyte");
  Expect(MemoryGB((7ull << 30) + (600ull << 20)) == 8, "rounded, not truncated, as on the Mac");
  Expect(MemoryGB(std::numeric_limits<uint64_t>::max()) == 1000000, "an absurd amount is capped");

  Expect(Name("  Intel(R) Core(TM) i7-8565U CPU @ 1.80GHz\n") == "Intel(R) Core(TM) i7-8565U CPU @ 1.80GHz", "a name is trimmed");
  Expect(Name("AMD\tRyzen  7\x01 5800X") == "AMD Ryzen 7 5800X", "runs of spaces and control characters become one space");
  Expect(Name("").empty() && Name(" \n\t").empty(), "nothing stays nothing");
  Expect(Name(std::string(1000, 'x')).size() == kNameMax, "a name is bounded");
  std::string wide;
  for (int i = 0; i < 200; ++i) wide += "\xe6\x96\x87";
  const std::string cut = Name(wide);
  Expect(cut.size() <= kNameMax && cut.size() % 3 == 0 && !cut.empty(), "a bounded name ends on a whole character");
  Expect(GpuName("Mesa Intel(R) UHD Graphics 620", "ANGLE (Intel)") == "Mesa Intel(R) UHD Graphics 620", "the device name wins");
  Expect(GpuName(" ", "ANGLE (Intel, Mesa Intel(R) UHD Graphics 620, OpenGL 4.6)") == "ANGLE (Intel, Mesa Intel(R) UHD Graphics 620, OpenGL 4.6)",
         "the renderer stands in for a missing device name");
  Expect(GpuName("", "").empty(), "no GPU information is no name");

  Decode decode;
  NoteDecodeProfile(decode, -1);
  NoteDecodeProfile(decode, 11);
  NoteDecodeProfile(decode, 19);
  NoteDecodeProfile(decode, 23);
  NoteDecodeProfile(decode, 27);
  NoteDecodeProfile(decode, 37);
  NoteDecodeProfile(decode, 1000);
  Expect(!decode.av1 && !decode.vp9 && !decode.hevc && !decode.h264, "VP8, Dolby Vision, Theora and unknown profiles count for nothing");
  NoteDecodeProfile(decode, 3);
  Expect(decode.h264 && !decode.vp9 && !decode.hevc && !decode.av1, "H.264 High");
  NoteDecodeProfile(decode, 12);
  Expect(decode.vp9 && !decode.hevc && !decode.av1, "VP9 profile 0");
  Decode extended;
  NoteDecodeProfile(extended, 29);
  Expect(extended.hevc && !extended.av1, "an HEVC range extension is HEVC");
  NoteDecodeProfile(decode, 17);
  NoteDecodeProfile(decode, 24);
  Expect(decode.hevc && decode.av1, "HEVC Main10 and AV1 Main");

  Hardware hardware;
  hardware.chip = " Intel(R) Core(TM) i7-8565U CPU @ 1.80GHz ";
  hardware.gpu = "Mesa Intel(R) UHD Graphics 620";
  hardware.memory_bytes = 16473620480ull;
  hardware.displays = 2;
  hardware.max_scale = 1.5;
  hardware.decode = decode;
  const base::DictValue reply = Reply(hardware);
  Expect(reply.size() == 6, "the Mac's six fields");
  Expect(*reply.FindString("chip") == "Intel(R) Core(TM) i7-8565U CPU @ 1.80GHz" && *reply.FindString("gpu") == "Mesa Intel(R) UHD Graphics 620", "names");
  Expect(reply.FindInt("memoryGB") == 15 && reply.FindInt("displays") == 2 && reply.FindDouble("maxScale") == 1.5, "numbers");
  const base::DictValue* codecs = reply.FindDict("hardwareDecode");
  Expect(codecs && codecs->size() == 4 && codecs->FindBool("av1") == true && codecs->FindBool("vp9") == true &&
         codecs->FindBool("hevc") == true && codecs->FindBool("h264") == true, "the four codecs");

  Hardware bare;
  bare.displays = -3;
  bare.max_scale = std::numeric_limits<double>::infinity();
  const base::DictValue empty = Reply(bare);
  Expect(empty.size() == 5 && !empty.Find("gpu") && empty.FindString("chip")->empty(), "an unknown GPU is left out, an unknown chip is empty");
  Expect(empty.FindInt("displays") == 0 && empty.FindDouble("maxScale") == 0.0 && empty.FindInt("memoryGB") == 0, "unknown numbers are zero");
  Expect(empty.FindDict("hardwareDecode")->FindBool("h264") == false, "no decoder is reported without GPU information");
  bare.max_scale = 400;
  Expect(Reply(bare).FindDouble("maxScale") == kScaleMax, "a scale is bounded");
  std::puts("ok");
  return 0;
}
