#include <cassert>
#include <cstdio>
#include <optional>
#include <string>

#include "ray/linux/ac_linux_automation_window.h"

namespace offscreen = raycore::linux_automation_window;

int main() {
  offscreen::OffscreenTab tab{.found = true, .in_strip = true};
  assert(!offscreen::OffscreenRefusal(tab));
  auto refused = [&](auto change) {
    offscreen::OffscreenTab copy = tab;
    change(copy);
    return offscreen::OffscreenRefusal(copy);
  };
  assert(*refused([](auto& t) { t.found = false; }) == "That tab has no page loaded.");
  assert(*refused([](auto& t) { t.discarded = true; }) == "That tab has no page loaded.");
  assert(*refused([](auto& t) { t.private_session = true; }) == "Private tabs can't go off-screen on Linux.");
  assert(*refused([](auto& t) { t.presented = true; }) == "That tab is shown in a window, so it can't go off-screen.");
  assert(*refused([](auto& t) { t.shown_before = true; }) == "That tab is shown in a window, so it can't go off-screen.");
  assert(*refused([](auto& t) { t.in_strip = false; }) == "Ray couldn't take that tab off-screen.");

  offscreen::TargetGenerations generations;
  assert(generations.Record("a", std::nullopt) == 0);
  assert(generations.Record("a", std::string("T1")) == 1);
  assert(generations.Record("a", std::string("T1")) == 1);
  assert(generations.Record("a", std::nullopt) == 1);
  assert(generations.Record("a", std::string("T2")) == 2);
  assert(generations.Record("b", std::string("T2")) == 1);
  assert(generations.Record("a", std::string("T1")) == 3);

  assert(offscreen::TabIdCountAllowed(0) && offscreen::TabIdCountAllowed(offscreen::kMaxTargetTabs));
  assert(!offscreen::TabIdCountAllowed(offscreen::kMaxTargetTabs + 1));
  for (const char* call : offscreen::kCapabilities) assert(std::string(call).starts_with("engine.cli"));
  std::puts("ok");
  return 0;
}
