#ifndef RAY_LINUX_AC_LINUX_AUTO_PIP_H_
#define RAY_LINUX_AC_LINUX_AUTO_PIP_H_

#include <functional>
#include <optional>
#include <utility>
#include <vector>

namespace raycore::linux_auto_pip {

inline constexpr int kHiddenPageWaitMs = 400;

class HiddenPageWait {
 public:
  bool Depart(bool page_visible) {
    waiting_ = page_visible;
    return !page_visible;
  }
  bool PageHidden() { return std::exchange(waiting_, false); }
  bool WaitedOut() { return std::exchange(waiting_, false); }
  void Return() { waiting_ = false; }
  bool waiting() const { return waiting_; }

 private:
  bool waiting_ = false;
};

template <class P>
class Preference {
 public:
  using Apply = std::function<void(P*, bool)>;
  using Regular = std::function<bool(P*)>;

  Preference(Apply apply, Regular regular) : apply_(std::move(apply)), regular_(std::move(regular)) {}

  void Set(bool enabled, const std::vector<P*>& loaded) {
    enabled_ = enabled;
    for (P* profile : loaded) Added(profile);
  }

  void Added(P* profile) {
    if (enabled_ && profile && regular_(profile)) apply_(profile, *enabled_);
  }

  std::optional<bool> enabled() const { return enabled_; }

 private:
  Apply apply_;
  Regular regular_;
  std::optional<bool> enabled_;
};

}

#endif
