#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string_view>

#include "ray/linux/ac_linux_appearance.h"
#include "ray/linux/ac_linux_hardware.h"

using namespace ray::linux_appearance;

namespace {

void Expect(bool condition, const char* what) {
  if (!condition) {
    std::fprintf(stderr, "failed: %s\n", what);
    std::abort();
  }
}

bool Advertised(std::string_view method) {
  for (const char* capability : ray::linux_hardware::kHardwareCapabilities) {
    if (method == capability) return true;
  }
  return false;
}

}

int main() {
  Expect(ParseAppearance("dark") == Appearance::kDark, "dark is dark");
  Expect(ParseAppearance("light") == Appearance::kLight, "light is light");
  Expect(ParseAppearance("auto") == Appearance::kAuto, "auto follows the system");
  Expect(!ParseAppearance("Dark") && !ParseAppearance("") && !ParseAppearance("system") && !ParseAppearance("darkness"),
         "only the shell's three modes are accepted");
  Expect(std::strcmp(kSetAppearanceCall, "RayShell.setAppearance") == 0, "the call is the shell module's setAppearance");
  Expect(Advertised(kSetAppearanceCall), "the host advertises setAppearance, so the shell sends it instead of keeping it local");
  std::printf("ok\n");
  return 0;
}
