#ifndef RAY_LINUX_AC_LINUX_PAGE_SWIPE_H_
#define RAY_LINUX_AC_LINUX_PAGE_SWIPE_H_

#include <optional>
#include <string_view>

namespace ray::linux_swipe {

inline constexpr char kPageSwipeEvent[] = "onPageSwipe";

enum class Phase { kBegan, kChanged, kEnded, kCancelled };

constexpr std::string_view PhaseName(Phase phase) {
  switch (phase) {
    case Phase::kBegan:
      return "began";
    case Phase::kChanged:
      return "changed";
    case Phase::kEnded:
      return "ended";
    case Phase::kCancelled:
      return "cancelled";
  }
  return "cancelled";
}

struct Step {
  Phase phase;
  double dx = 0;
  double dy = 0;
};

class PageSwipe {
 public:
  void Begin(bool touchpad) {
    state_ = touchpad ? State::kPending : State::kIdle;
  }

  std::optional<Step> Update(double dx, double dy, bool consumed, bool momentum) {
    if (state_ == State::kTracking && momentum) {
      state_ = State::kIdle;
      return Step{Phase::kEnded};
    }
    if (momentum) return std::nullopt;
    if (state_ == State::kPending) {
      if (consumed) {
        state_ = State::kPage;
        return std::nullopt;
      }
      if (dx == 0 && dy == 0) return std::nullopt;
      state_ = State::kTracking;
      return Step{Phase::kBegan, dx, dy};
    }
    if (state_ == State::kTracking) return Step{Phase::kChanged, dx, dy};
    return std::nullopt;
  }

  std::optional<Step> End(bool cancelled) {
    const bool tracking = state_ == State::kTracking;
    state_ = State::kIdle;
    if (!tracking) return std::nullopt;
    return Step{cancelled ? Phase::kCancelled : Phase::kEnded};
  }

  bool tracking() const { return state_ == State::kTracking; }

 private:
  enum class State { kIdle, kPending, kPage, kTracking };
  State state_ = State::kIdle;
};

}

#endif
