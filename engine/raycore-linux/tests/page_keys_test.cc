#include <cassert>
#include <cstdio>

#include "ray/linux/ac_linux_page_keys.h"

using ray::linux_keys::IsUnhandledEscape;
using ray::linux_keys::PageKey;
using ray::linux_keys::PageTakesEscape;

int main() {
  assert(IsUnhandledEscape({.raw_key_down = true, .key_code = 0x1B}));
  assert(!IsUnhandledEscape({.raw_key_down = false, .key_code = 0x1B}));
  assert(!IsUnhandledEscape({.raw_key_down = true, .key_code = 0x0D}));
  assert(!IsUnhandledEscape({.raw_key_down = true, .key_code = 0x1B, .control = true}));
  assert(!IsUnhandledEscape({.raw_key_down = true, .key_code = 0x1B, .alt = true}));
  assert(!IsUnhandledEscape({.raw_key_down = true, .key_code = 0x1B, .meta = true}));
  assert(!IsUnhandledEscape({}));
  assert(PageTakesEscape(true, true, true));
  assert(!PageTakesEscape(false, true, true));
  assert(!PageTakesEscape(true, false, true));
  assert(!PageTakesEscape(true, true, false));
  std::puts("ok");
  return 0;
}
