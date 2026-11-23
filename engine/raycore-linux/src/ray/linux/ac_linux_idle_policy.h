#ifndef RAY_LINUX_AC_LINUX_IDLE_POLICY_H_
#define RAY_LINUX_AC_LINUX_IDLE_POLICY_H_

#include <algorithm>
#include <cmath>
#include <map>
#include <set>
#include <utility>
#include <vector>

namespace ray::linux_idle {

inline constexpr double kMinThresholdSeconds = 1;
inline constexpr double kMaxThresholdSeconds = 24 * 60 * 60;
inline constexpr double kActivePollSeconds = 1;
inline constexpr double kLongestWaitSeconds = 60;
inline constexpr size_t kMaxThresholds = 16;

inline std::set<double> CleanThresholds(const std::vector<double>& wanted) {
  std::set<double> kept;
  for (double threshold : wanted) {
    if (std::isfinite(threshold) && threshold >= kMinThresholdSeconds && threshold <= kMaxThresholdSeconds) {
      kept.insert(threshold);
    }
    if (kept.size() == kMaxThresholds) break;
  }
  return kept;
}

class IdleWatch {
 public:
  void Watch(const std::set<double>& thresholds) {
    std::map<double, bool> next;
    for (double threshold : thresholds) {
      const auto found = idle_.find(threshold);
      next[threshold] = found != idle_.end() && found->second;
    }
    idle_ = std::move(next);
  }

  bool empty() const { return idle_.empty(); }

  std::vector<double> IdleAmong(const std::set<double>& thresholds) const {
    std::vector<double> idle;
    for (double threshold : thresholds) {
      const auto found = idle_.find(threshold);
      if (found != idle_.end() && found->second) idle.push_back(threshold);
    }
    return idle;
  }

  std::vector<std::pair<double, bool>> Update(double idle_seconds) {
    std::vector<std::pair<double, bool>> changed;
    for (auto& [threshold, was] : idle_) {
      const bool now = idle_seconds >= threshold;
      if (now != was) {
        was = now;
        changed.emplace_back(threshold, now);
      }
    }
    return changed;
  }

  double NextCheckSeconds(double idle_seconds) const {
    double wait = kLongestWaitSeconds;
    bool any_idle = false;
    for (const auto& [threshold, idle] : idle_) {
      if (idle) {
        any_idle = true;
      } else {
        wait = std::min(wait, threshold - idle_seconds);
      }
    }
    if (any_idle) wait = std::min(wait, kActivePollSeconds);
    return std::clamp(wait, 0.25, kLongestWaitSeconds);
  }

 private:
  std::map<double, bool> idle_;
};

}

#endif
