#include <cstdio>
#include <cstdlib>
#include <string_view>

#include "ray/linux/ac_linux_switcher_keys.h"

using ray::linux_switcher::SwitcherKey;

namespace {

void Expect(const char* key, const char* want, const char* what) {
  const bool same = key && want ? std::string_view(key) == want : key == want;
  if (same) return;
  std::printf("%s: got %s, want %s\n", what, key ? key : "nothing", want ? want : "nothing");
  std::exit(1);
}

}

int main() {
  Expect(SwitcherKey({.key_code = 0x1B}), "escape", "escape cancels");
  Expect(SwitcherKey({.key_code = 0x27}), "next", "right moves on");
  Expect(SwitcherKey({.key_code = 0x25}), "previous", "left moves back");
  Expect(SwitcherKey({.key_code = 0x57, .control = true}), "close", "ctrl-w closes the selected row");
  Expect(SwitcherKey({.key_code = 0x57, .command = true}), "close", "super-w closes the selected row");
  Expect(SwitcherKey({.key_code = 0x57, .control = true, .repeat = true}), nullptr, "a held ctrl-w closes one row");
  Expect(SwitcherKey({.key_code = 0x57, .control = true, .alt = true}), nullptr, "ctrl-alt-w is not close");
  Expect(SwitcherKey({.key_code = 0x57}), nullptr, "a bare w does nothing");
  Expect(SwitcherKey({.key_code = 0x09, .control = true}), nullptr, "the switcher's own key is left to its binding");
  std::puts("ok");
  return 0;
}
