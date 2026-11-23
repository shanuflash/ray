#include <cassert>
#include <cstdio>
#include <string>

#include "ray/linux/ac_linux_capture.h"

namespace capture = raycore::linux_capture;

int main() {
  const std::string meet = "tab-meet";
  const std::string doc = "tab-doc";
  const std::string empty;
  auto change = capture::ParseCaptureRequest(capture::kChangeCaptureSourceCall, &meet, &doc, nullptr, 2);
  assert(change && change->kind == capture::Kind::kSwitch && change->capturer == meet && change->target == doc);
  assert(!capture::ParseCaptureRequest(capture::kChangeCaptureSourceCall, &meet, nullptr, nullptr, 1));
  assert(!capture::ParseCaptureRequest(capture::kChangeCaptureSourceCall, nullptr, &doc, nullptr, 1));
  assert(!capture::ParseCaptureRequest(capture::kChangeCaptureSourceCall, &empty, &doc, nullptr, 2));
  assert(!capture::ParseCaptureRequest(capture::kChangeCaptureSourceCall, &meet, &meet, nullptr, 2));
  assert(!capture::ParseCaptureRequest(capture::kChangeCaptureSourceCall, &meet, &doc, nullptr, 3));
  auto stop = capture::ParseCaptureRequest(capture::kStopCaptureCall, nullptr, nullptr, &meet, 1);
  assert(stop && stop->kind == capture::Kind::kStop && stop->capturer == meet && stop->target.empty());
  assert(!capture::ParseCaptureRequest(capture::kStopCaptureCall, nullptr, nullptr, &empty, 1));
  assert(!capture::ParseCaptureRequest(capture::kStopCaptureCall, &meet, nullptr, &meet, 2));
  assert(!capture::ParseCaptureRequest("media.startCasting", nullptr, nullptr, &meet, 1));
  constexpr int kStop = 1 << 0;
  constexpr int kInstead = 1 << 1;
  assert(capture::SharesInstead(kStop | kInstead, kInstead, true, 1));
  assert(!capture::SharesInstead(kStop, kInstead, true, 1));
  assert(!capture::SharesInstead(kStop | kInstead, kInstead, false, 1));
  assert(!capture::SharesInstead(kStop | kInstead, kInstead, true, 0));
  assert(!capture::SharesInstead(kStop | kInstead, kInstead, true, 2));
  assert(capture::ReachesTab(false, false) && capture::ReachesTab(true, true));
  assert(!capture::ReachesTab(true, false) && !capture::ReachesTab(false, true));
  assert(std::string(capture::kCaptureCapabilities[0]) == capture::kChangeCaptureSourceCall);
  assert(std::string(capture::kCaptureCapabilities[1]) == capture::kStopCaptureCall);
  std::puts("ok");
  return 0;
}
