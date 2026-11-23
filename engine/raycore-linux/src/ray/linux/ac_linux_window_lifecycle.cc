#include "ray/linux/ac_linux_window_lifecycle.h"

#include <algorithm>
#include <cmath>

namespace ray::linux_window {

namespace {

constexpr double kMaxExtent = 100000;
constexpr double kMaxOrigin = 1000000;

}

bool FocusLedger::Wants(const OpenIntent& intent) const {
  return may_activate_ && (intent.utility || (intent.focus && !intent.behind));
}

Presentation FocusLedger::Create(int window, const OpenIntent& intent, int64_t now_ms) {
  if (Wants(intent)) {
    Request(window);
    return Presentation::kActivate;
  }
  const int keep = intent.behind_window ? intent.behind_window : active_;
  if (may_activate_ && intent.hand_back && keep && keep != window) {
    kept_[window] = {.window = keep, .presses = presses_, .created_ms = now_ms};
  }
  return Presentation::kInactive;
}

void FocusLedger::Presented(int window, int64_t now_ms) {
  const auto found = kept_.find(window);
  if (found != kept_.end() && !found->second.presented_ms) found->second.presented_ms = now_ms;
}

std::optional<int> FocusLedger::Unrequested(int window, int64_t now_ms) {
  const auto found = kept_.find(window);
  if (found == kept_.end()) return std::nullopt;
  const Kept kept = found->second;
  kept_.erase(found);
  if (kept.presses != presses_ || now_ms > kept.created_ms + kHandBackLimitMs) return std::nullopt;
  if (kept.presented_ms && now_ms > *kept.presented_ms + kHandBackAfterFrameMs) return std::nullopt;
  return kept.window;
}

Activation FocusLedger::Reuse(int window, const OpenIntent& intent,
                              bool own_renderer) {
  if (!may_activate_ && intent.utility) return Activation::kShowInactive;
  if (!Wants(intent) || (own_renderer && !intent.utility)) return Activation::kNone;
  kept_.clear();
  Request(window);
  return Activation::kActivate;
}

Activation FocusLedger::Focus(int window) {
  if (!may_activate_) return Activation::kShowInactive;
  kept_.clear();
  Request(window);
  return Activation::kActivate;
}

Activation FocusLedger::HandBack(int window) {
  if (!may_activate_) return Activation::kNone;
  Request(window);
  return Activation::kActivate;
}

Activation FocusLedger::Ready(int window) {
  const auto found = pending_.find(window);
  if (found == pending_.end()) return Activation::kNone;
  const uint64_t requested = found->second;
  pending_.erase(found);
  if (!may_activate_ || active_ == window || requested != epoch_) {
    return Activation::kNone;
  }
  return Activation::kActivate;
}

bool FocusLedger::Observe(int window, bool active) {
  if (active) {
    pending_.erase(window);
    if (active_ == window) return false;
    active_ = window;
    ++epoch_;
    return true;
  }
  if (active_ != window) return false;
  active_ = 0;
  ++epoch_;
  return false;
}

void FocusLedger::Forget(int window) {
  pending_.erase(window);
  kept_.erase(window);
  std::erase_if(kept_, [window](const auto& entry) { return entry.second.window == window; });
  if (active_ == window) active_ = 0;
}

std::optional<int64_t> OutputLabelled(const std::vector<Output>& outputs, const std::string& label) {
  if (label.empty()) return std::nullopt;
  std::optional<int64_t> found;
  for (const Output& output : outputs) {
    if (output.label != label) continue;
    if (found) return std::nullopt;
    found = output.id;
  }
  return found;
}

std::array<int, 4> SharedFrame(const Rect& bounds, const Rect& primary) {
  return {bounds.x - primary.x,
          primary.y + primary.height - (bounds.y + bounds.height),
          bounds.width, bounds.height};
}

std::optional<Requested> RequestedFrame(const std::vector<double>& frame,
                                        const Rect& primary,
                                        bool global_coordinates) {
  if (frame.size() != 4) return std::nullopt;
  for (const double value : frame) {
    if (!std::isfinite(value)) return std::nullopt;
  }
  if (std::fabs(frame[0]) > kMaxOrigin || std::fabs(frame[1]) > kMaxOrigin ||
      frame[2] > kMaxExtent || frame[3] > kMaxExtent) {
    return std::nullopt;
  }
  const int width = static_cast<int>(std::lround(frame[2]));
  const int height = static_cast<int>(std::lround(frame[3]));
  if (width <= 0 || height <= 0) return std::nullopt;
  Requested requested;
  requested.bounds.width = width;
  requested.bounds.height = height;
  requested.positioned = global_coordinates;
  if (global_coordinates) {
    requested.bounds.x = primary.x + static_cast<int>(std::lround(frame[0]));
    requested.bounds.y = primary.y + primary.height -
                         (static_cast<int>(std::lround(frame[1])) + height);
  }
  return requested;
}

Requested RequestedSmallFrame(const std::vector<double>& size,
                              const Rect& work_area,
                              bool global_coordinates) {
  const bool given = size.size() == 2 && std::isfinite(size[0]) && std::isfinite(size[1]);
  const auto fit = [](double wanted, int minimum, int room) {
    const double floor = std::max(wanted, static_cast<double>(minimum));
    if (room <= 0) return std::min(floor, kMaxExtent);
    const double largest = std::min(std::max(std::round(room * kSmallWindowLargestShare), static_cast<double>(minimum)),
                                    static_cast<double>(room));
    return std::min(floor, largest);
  };
  const double width = fit(given ? size[0] : kSmallWindowWidth, kSmallWindowMinWidth, work_area.width);
  const double height = fit(given ? size[1] : kSmallWindowHeight, kSmallWindowMinHeight, work_area.height);
  Requested requested;
  requested.bounds.width = static_cast<int>(std::lround(width));
  requested.bounds.height = static_cast<int>(std::lround(height));
  requested.positioned = global_coordinates && work_area.width > 0 && work_area.height > 0;
  if (requested.positioned) {
    requested.bounds.x = work_area.x + static_cast<int>(std::lround((work_area.width - width) / 2));
    requested.bounds.y = work_area.y + static_cast<int>(std::lround((work_area.height - height) / 2));
  }
  return requested;
}

Requested RequestedUtilityFrame(int width,
                                int height,
                                const Rect& opener,
                                const Rect& work_area,
                                bool global_coordinates) {
  const bool room = work_area.width > 0 && work_area.height > 0;
  Requested requested;
  requested.bounds.width = room ? std::min(width, work_area.width) : width;
  requested.bounds.height = room ? std::min(height, work_area.height) : height;
  requested.positioned = global_coordinates && opener.width > 0 && opener.height > 0;
  if (!requested.positioned) return requested;
  int x = opener.x + (opener.width - requested.bounds.width) / 2;
  int y = opener.y + (opener.height - requested.bounds.height) / 2;
  if (room) {
    x = std::clamp(x, work_area.x, work_area.x + work_area.width - requested.bounds.width);
    y = std::clamp(y, work_area.y, work_area.y + work_area.height - requested.bounds.height);
  }
  requested.bounds.x = x;
  requested.bounds.y = y;
  return requested;
}

std::optional<std::array<int, 4>> GeometryLedger::Frame(const Rect& bounds,
                                                        const Rect& primary,
                                                        bool fullscreen,
                                                        bool minimized) {
  if (!global_coordinates_ || fullscreen || minimized || bounds.width <= 0 ||
      bounds.height <= 0) {
    return std::nullopt;
  }
  const auto frame = SharedFrame(bounds, primary);
  if (last_frame_ == frame) return std::nullopt;
  last_frame_ = frame;
  return frame;
}

std::optional<bool> GeometryLedger::FullScreen(bool fullscreen) {
  if (fullscreen == fullscreen_) return std::nullopt;
  fullscreen_ = fullscreen;
  return fullscreen;
}

}
