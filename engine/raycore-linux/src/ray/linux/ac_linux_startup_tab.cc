#include "ray/linux/ac_linux_startup_tab.h"

#include <vector>

namespace linux_startup_tab {
namespace {

const std::string* Text(const base::DictValue* dict, std::string_view key) {
  return dict ? dict->FindString(key) : nullptr;
}

bool Is(const base::DictValue* dict, std::string_view key, std::string_view want) {
  const std::string* value = Text(dict, key);
  return value && *value == want;
}

const base::DictValue* Window(const base::DictValue& windows, std::string_view id) {
  return id.empty() ? nullptr : windows.FindDict(id);
}

bool HasSavedTabs(const base::DictValue& windows, const base::DictValue& tabs, std::string_view id) {
  const base::DictValue* window = Window(windows, id);
  const base::Value* ids = window ? window->Find("tabIds") : nullptr;
  if (!ids || !ids->is_list()) return false;
  for (const base::Value& tab : ids->GetList()) {
    if (tab.is_string() && tabs.FindDict(tab.GetString())) return true;
  }
  return false;
}

std::optional<std::string> LaunchWindow(const base::DictValue& session, const base::DictValue& windows,
                                        const base::DictValue& tabs, std::string_view window_id) {
  if (HasSavedTabs(windows, tabs, window_id)) return std::string(window_id);
  if (window_id != kLaunchWindowId) return std::nullopt;
  std::vector<std::string> order;
  if (const std::string* focused = session.FindString("focusedWindowId")) order.push_back(*focused);
  if (const base::Value* listed = session.Find("windowOrder"); listed && listed->is_list()) {
    for (const base::Value& id : listed->GetList()) {
      if (id.is_string()) order.push_back(id.GetString());
    }
  }
  for (const std::string& id : order) {
    if (id != window_id && Is(Window(windows, id), "kind", "main") && HasSavedTabs(windows, tabs, id)) return id;
  }
  return std::nullopt;
}

bool WebUrl(std::string_view url) {
  return url.size() <= kMaxUrlBytes && (url.starts_with("https://") || url.starts_with("http://"));
}

}

std::string ShellProfile(std::string_view page_profile) {
  if (page_profile.empty() || page_profile.starts_with("incognito:")) return std::string(kDefaultProfile);
  return std::string(page_profile);
}

std::optional<StartupTab> StartupTabFor(const base::DictValue& session, std::string_view window_id,
                                        std::string_view profile) {
  if (const base::DictValue* settings = session.FindDict("settings")) {
    const base::Value* restore = settings->Find("restoreSession");
    if (restore && restore->is_bool() && !restore->GetBool()) return std::nullopt;
  }
  const base::DictValue* windows = session.FindDict("windows");
  const base::DictValue* tabs = session.FindDict("tabs");
  if (!windows || !tabs) return std::nullopt;
  const std::optional<std::string> chosen = LaunchWindow(session, *windows, *tabs, window_id);
  const base::DictValue* window = chosen ? Window(*windows, *chosen) : nullptr;
  if (!Is(window, "kind", "main") || !Is(window, "profileId", profile)) return std::nullopt;
  const std::string* active = Text(window->FindDict("activeTabIds"), profile);
  const base::DictValue* tab = active ? tabs->FindDict(*active) : nullptr;
  if (!tab || !Is(tab, "windowId", *chosen) || !Is(tab, "profileId", profile)) return std::nullopt;
  if (!Is(tab->FindDict("page"), "kind", "idle")) return std::nullopt;
  const std::string* url = Text(tab, "url");
  if (!url || !WebUrl(*url)) return std::nullopt;
  return StartupTab{*active, *url};
}

}
