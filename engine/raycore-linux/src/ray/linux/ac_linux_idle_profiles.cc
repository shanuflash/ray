#include "ray/linux/ac_linux_idle_profiles.h"

#include <utility>

namespace raycore {

namespace {

base::DictValue Reply(std::string_view status, base::ListValue tabs, std::optional<std::string_view> held_by) {
  base::DictValue reply;
  reply.Set("status", status);
  reply.Set("tabs", base::Value(std::move(tabs)));
  if (held_by) reply.Set("heldBy", *held_by);
  return reply;
}

base::DictValue Busy(std::string_view held_by, base::ListValue tabs = base::ListValue()) {
  return Reply("busy", std::move(tabs), held_by);
}

}

base::DictValue UnloadLinuxIdleProfile(const LinuxIdleProfileState& state,
                                       std::vector<LinuxIdleProfileWindow>& windows,
                                       const std::function<std::string()>& release) {
  if (!state.loaded) return state.loading ? Busy("profile") : Reply("released", base::ListValue(), std::nullopt);
  if (!state.regular) return Busy("profile");
  for (const LinuxIdleProfileWindow& window : windows) {
    for (const LinuxIdleProfileTab& tab : window.tabs) {
      if (tab.key.empty()) return Busy("tab");
      if (!tab.kept_by.empty()) return Busy(tab.kept_by);
    }
  }
  if (state.held_open_by) return Busy(*state.held_open_by);
  for (const LinuxIdleProfileWindow& window : windows) {
    if (window.shows_profile) return Busy("window");
  }
  for (const LinuxIdleProfileWindow& window : windows) {
    for (const LinuxIdleProfileTab& tab : window.tabs) {
      if (!tab.can_keep_history()) return Busy("history");
      if (!tab.sleeps(false)) return Busy("page");
    }
  }
  bool settling = false;
  for (const LinuxIdleProfileWindow& window : windows) {
    for (const LinuxIdleProfileTab& tab : window.tabs) {
      settling |= !tab.discarded();
      if (!tab.sleeps(true)) return Busy("page");
      settling |= !tab.keep_history();
    }
  }
  if (settling) return Busy("sleeping");
  base::ListValue unloaded;
  for (const LinuxIdleProfileWindow& window : windows) {
    for (const LinuxIdleProfileTab& tab : window.tabs) {
      if (!tab.unload()) return Busy("history", std::move(unloaded));
      unloaded.Append(base::Value(tab.key));
    }
  }
  for (const LinuxIdleProfileWindow& window : windows) {
    if (window.close_member) window.close_member();
  }
  return Reply(release(), std::move(unloaded), std::nullopt);
}

}
