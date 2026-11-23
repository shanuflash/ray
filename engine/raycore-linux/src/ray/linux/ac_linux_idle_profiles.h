#ifndef RAY_LINUX_AC_LINUX_IDLE_PROFILES_H_
#define RAY_LINUX_AC_LINUX_IDLE_PROFILES_H_

#include <functional>
#include <optional>
#include <string>
#include <vector>

#include "base/values.h"

namespace raycore {

inline constexpr char kLinuxUnloadIdleProfileCall[] = "profiles.unloadIdle";

struct LinuxIdleProfileTab {
  std::string key;
  std::string kept_by;
  std::function<bool()> can_keep_history;
  std::function<bool()> discarded;
  std::function<bool(bool sleep)> sleeps;
  std::function<bool()> keep_history;
  std::function<bool()> unload;
};

struct LinuxIdleProfileWindow {
  bool shows_profile = false;
  std::vector<LinuxIdleProfileTab> tabs;
  std::function<void()> close_member;
};

struct LinuxIdleProfileState {
  bool loaded = false;
  bool loading = false;
  bool regular = false;
  std::optional<std::string> held_open_by;
};

base::DictValue UnloadLinuxIdleProfile(const LinuxIdleProfileState& state,
                                       std::vector<LinuxIdleProfileWindow>& windows,
                                       const std::function<std::string()>& release);

}

#endif
