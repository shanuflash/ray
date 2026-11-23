#include <cassert>
#include <cstdio>
#include <optional>
#include <string>

#include "ray/linux/ac_linux_cast_core.h"

namespace cast = raycore::linux_cast;

int main() {
  const std::string tab = "tab-video";
  const std::string sink = "ac-test-sink";
  const std::string route = "urn:x-org.chromium:media:route:1";
  const std::string empty;

  auto show = cast::ParseCastRequest(cast::kShowCall, &tab, std::nullopt, nullptr, nullptr, std::nullopt, 1);
  assert(show && show->verb == cast::Verb::kShow && show->tab == tab);
  assert(!cast::ParseCastRequest(cast::kShowCall, &empty, std::nullopt, nullptr, nullptr, std::nullopt, 1));
  assert(!cast::ParseCastRequest(cast::kShowCall, &tab, std::nullopt, nullptr, nullptr, std::nullopt, 2));
  assert(!cast::ParseCastRequest(cast::kShowCall, nullptr, std::nullopt, nullptr, nullptr, std::nullopt, 0));

  auto start = cast::ParseCastRequest(cast::kStartCall, nullptr, 3, &sink, nullptr, 2, 3);
  assert(start && start->verb == cast::Verb::kStart && start->dialog == 3 && start->sink == sink && start->mode == 2);
  for (int mode : {1, 2, 4, 8}) assert(cast::ParseCastRequest(cast::kStartCall, nullptr, 1, &sink, nullptr, mode, 3));
  for (int mode : {0, 3, 16, -1}) assert(!cast::ParseCastRequest(cast::kStartCall, nullptr, 1, &sink, nullptr, mode, 3));
  assert(!cast::ParseCastRequest(cast::kStartCall, nullptr, 0, &sink, nullptr, 2, 3));
  assert(!cast::ParseCastRequest(cast::kStartCall, nullptr, 1, &empty, nullptr, 2, 3));
  assert(!cast::ParseCastRequest(cast::kStartCall, nullptr, 1, &sink, nullptr, std::nullopt, 2));

  auto stop = cast::ParseCastRequest(cast::kStopCall, nullptr, 4, nullptr, &route, std::nullopt, 2);
  assert(stop && stop->verb == cast::Verb::kStop && stop->dialog == 4 && stop->route == route);
  assert(!cast::ParseCastRequest(cast::kStopCall, nullptr, 4, nullptr, nullptr, std::nullopt, 1));

  auto close = cast::ParseCastRequest(cast::kCloseCall, nullptr, 5, nullptr, nullptr, std::nullopt, 1);
  assert(close && close->verb == cast::Verb::kClose && close->dialog == 5);
  assert(!cast::ParseCastRequest(cast::kCloseCall, nullptr, -5, nullptr, nullptr, std::nullopt, 1));

  auto watch = cast::ParseCastRequest(cast::kWatchCall, nullptr, std::nullopt, nullptr, nullptr, std::nullopt, 0);
  assert(watch && watch->verb == cast::Verb::kWatch);
  assert(!cast::ParseCastRequest(cast::kWatchCall, &tab, std::nullopt, nullptr, nullptr, std::nullopt, 1));

  auto terminate = cast::ParseCastRequest(cast::kTerminateCall, nullptr, std::nullopt, nullptr, &route, std::nullopt, 1);
  assert(terminate && terminate->verb == cast::Verb::kTerminate && terminate->route == route);
  assert(!cast::ParseCastRequest(cast::kTerminateCall, nullptr, std::nullopt, nullptr, &empty, std::nullopt, 1));

  assert(!cast::ParseCastRequest("media.changeCaptureSource", &tab, std::nullopt, nullptr, nullptr, std::nullopt, 1));
  for (const char* call : cast::kCastCapabilities) assert(cast::IsCastCall(call));
  assert(!cast::IsCastCall("media.stopCapture"));

  assert(cast::TestSinkAllowed(true, true, true));
  assert(!cast::TestSinkAllowed(false, true, true));
  assert(!cast::TestSinkAllowed(true, false, true));
  assert(!cast::TestSinkAllowed(true, true, false));
  std::puts("ok");
  return 0;
}
