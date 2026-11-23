#ifndef RAY_LINUX_AC_LINUX_APP_ACTIVATION_H_
#define RAY_LINUX_AC_LINUX_APP_ACTIVATION_H_

#include <cstdint>
#include <optional>

namespace ray::linux_window {

inline constexpr char kResignActiveEvent[] = "resignActive";
inline constexpr const char* kAppActivationCapabilities[] = {"RayShell.resignActive"};

class AppActivation {
 public:
  static constexpr int kSettleMs = 150;

  bool active() const { return active_; }
  bool settling() const { return settle_.has_value(); }

  std::optional<uint64_t> WindowsChanged(bool any_window_active) {
    if (any_window_active) {
      active_ = true;
      settle_.reset();
      return std::nullopt;
    }
    if (!active_) return std::nullopt;
    settle_ = ++generation_;
    return settle_;
  }

  bool Settled(uint64_t generation, bool any_window_active, bool quiet) {
    if (settle_ != generation) return false;
    settle_.reset();
    if (any_window_active) return false;
    active_ = false;
    return quiet;
  }

 private:
  bool active_ = false;
  std::optional<uint64_t> settle_;
  uint64_t generation_ = 0;
};

}

#endif
