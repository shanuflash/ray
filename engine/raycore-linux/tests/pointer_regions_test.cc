#include <cassert>
#include <climits>
#include <cstdio>
#include <vector>

#include "ray/linux/ac_linux_pointer_regions.h"

using ray::linux_window::ButtonsHeld;
using ray::linux_window::InPassRegion;
using ray::linux_window::PassRect;
using ray::linux_window::ShellHoverIsStale;

namespace {

constexpr int kLeft = 1 << 4;
constexpr int kMiddle = 1 << 5;
constexpr int kRight = 1 << 6;
constexpr int kButtons = kLeft | kMiddle | kRight;
constexpr int kControl = 1 << 2;

void APointInsideAPassRectIsOverThePage() {
  const std::vector<PassRect> pass{{240, 40, 800, 600}, {1050, 40, 300, 200}};
  assert(InPassRegion(pass, 240, 40));
  assert(InPassRegion(pass, 1039, 639));
  assert(!InPassRegion(pass, 1040, 300));
  assert(!InPassRegion(pass, 239, 300));
  assert(!InPassRegion(pass, 500, 640));
  assert(InPassRegion(pass, 1100, 100));
  assert(!InPassRegion(pass, 1100, 240));
  assert(!InPassRegion({}, 500, 300));
  assert(!InPassRegion({{0, 0, 0, 50}, {0, 0, 50, -1}}, 0, 0));
  assert(InPassRegion({{INT_MAX - 10, INT_MIN, 10, 10}}, INT_MAX - 1, INT_MIN + 9));
  assert(!InPassRegion({{INT_MAX - 10, 0, 10, 10}}, INT_MIN, 0));
  assert(!InPassRegion({{INT_MIN, 0, 10, 10}}, INT_MAX, 0));
}

void TheShellLosesAHoverThatAPageNowOwns() {
  const std::vector<PassRect> pass{{240, 40, 800, 600}};
  assert(ShellHoverIsStale(true, false, pass, 300, 300));
  assert(!ShellHoverIsStale(false, false, pass, 300, 300));
  assert(!ShellHoverIsStale(true, true, pass, 300, 300));
  assert(!ShellHoverIsStale(true, false, pass, 100, 300));
  assert(!ShellHoverIsStale(true, false, {}, 300, 300));
}

void AReleaseDropsItsOwnButtonAndKeepsTheOthers() {
  assert(!ButtonsHeld(0, 0, false, kButtons));
  assert(!ButtonsHeld(kControl, 0, false, kButtons));
  assert(ButtonsHeld(kLeft, kLeft, false, kButtons));
  assert(ButtonsHeld(kLeft | kControl, 0, false, kButtons));
  assert(!ButtonsHeld(kLeft, kLeft, true, kButtons));
  assert(ButtonsHeld(kLeft | kRight, kLeft, true, kButtons));
  assert(ButtonsHeld(kMiddle, 0, true, kButtons));
}

}

int main() {
  APointInsideAPassRectIsOverThePage();
  TheShellLosesAHoverThatAPageNowOwns();
  AReleaseDropsItsOwnButtonAndKeepsTheOthers();
  std::puts("ok");
  return 0;
}
