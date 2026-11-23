#include <cassert>
#include <cstdio>

#include "ray/linux/ac_linux_page_swipe.h"

namespace swipe = ray::linux_swipe;

int main() {
  using swipe::Phase;
  swipe::PageSwipe gesture;
  gesture.Begin(true);
  auto step = gesture.Update(6, 1, false, false);
  assert(step && step->phase == Phase::kBegan && step->dx == 6 && step->dy == 1);
  step = gesture.Update(10, 0, true, false);
  assert(step && step->phase == Phase::kChanged && step->dx == 10);
  step = gesture.End(false);
  assert(step && step->phase == Phase::kEnded && !gesture.tracking());
  assert(!gesture.End(false));

  gesture.Begin(true);
  assert(!gesture.Update(0, 12, true, false));
  assert(!gesture.Update(20, 0, false, false));
  assert(!gesture.End(false));

  gesture.Begin(false);
  assert(!gesture.Update(20, 0, false, false));
  assert(!gesture.End(false));

  gesture.Begin(true);
  assert(!gesture.Update(0, 0, false, false));
  assert(!gesture.Update(4, 0, false, true));
  step = gesture.Update(4, 0, false, false);
  assert(step && step->phase == Phase::kBegan);
  step = gesture.Update(30, 0, false, true);
  assert(step && step->phase == Phase::kEnded && !gesture.tracking());
  assert(!gesture.Update(30, 0, false, true));
  assert(!gesture.Update(30, 0, false, false));

  gesture.Begin(true);
  assert(gesture.Update(-8, 0, false, false));
  step = gesture.End(true);
  assert(step && step->phase == Phase::kCancelled);

  assert(swipe::PhaseName(Phase::kBegan) == "began");
  assert(swipe::PhaseName(Phase::kChanged) == "changed");
  assert(swipe::PhaseName(Phase::kEnded) == "ended");
  assert(swipe::PhaseName(Phase::kCancelled) == "cancelled");
  std::puts("ok");
  return 0;
}
