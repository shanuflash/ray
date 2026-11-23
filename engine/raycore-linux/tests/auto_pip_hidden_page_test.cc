#include <cassert>
#include <cstdio>

#include "ray/linux/ac_linux_auto_pip.h"

int main() {
  raycore::linux_auto_pip::HiddenPageWait wait;
  assert(wait.Depart(false) && !wait.waiting());
  assert(!wait.PageHidden() && !wait.WaitedOut());
  assert(!wait.Depart(true) && wait.waiting());
  assert(wait.PageHidden() && !wait.waiting());
  assert(!wait.PageHidden() && !wait.WaitedOut());
  assert(!wait.Depart(true));
  assert(wait.WaitedOut() && !wait.PageHidden());
  assert(!wait.Depart(true));
  wait.Return();
  assert(!wait.waiting() && !wait.PageHidden() && !wait.WaitedOut());
  assert(!wait.Depart(true) && wait.Depart(false) && !wait.waiting() && !wait.WaitedOut());
  static_assert(raycore::linux_auto_pip::kHiddenPageWaitMs == 400);
  std::puts("ok");
  return 0;
}
