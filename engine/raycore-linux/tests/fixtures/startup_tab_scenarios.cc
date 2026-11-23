#include "ray/linux/ac_linux_startup_tab.h"

#include <cassert>
#include <cstdio>
#include <string>
#include <utility>

using namespace linux_startup_tab;

namespace {

base::DictValue Tab(const std::string& window, const std::string& url, const std::string& kind = "idle",
                    const std::string& profile = "default") {
  return base::DictValue()
      .Set("windowId", window)
      .Set("profileId", profile)
      .Set("url", url)
      .Set("page", base::DictValue().Set("kind", kind));
}

base::DictValue Window(const std::string& kind, const std::string& active, std::initializer_list<const char*> ids,
                       const std::string& profile = "default") {
  base::ListValue list;
  for (const char* id : ids) list.Append(base::Value(id));
  return base::DictValue()
      .Set("kind", kind)
      .Set("profileId", profile)
      .Set("tabIds", base::Value(std::move(list)))
      .Set("activeTabIds", base::DictValue().Set(profile, active));
}

base::DictValue Session(base::DictValue windows, base::DictValue tabs) {
  base::ListValue order;
  order.Append(base::Value("main"));
  return base::DictValue()
      .Set("windows", std::move(windows))
      .Set("tabs", std::move(tabs))
      .Set("windowOrder", base::Value(std::move(order)))
      .Set("focusedWindowId", "main")
      .Set("settings", base::DictValue().Set("restoreSession", base::Value(true)));
}

base::DictValue OneWindow(const std::string& url, const std::string& kind = "idle") {
  return Session(base::DictValue().Set("main", Window("main", "b", {"a", "b"})),
                 base::DictValue().Set("a", Tab("main", "https://a.test/")).Set("b", Tab("main", url, kind)));
}

void PicksTheLaunchWindowsActiveTab() {
  auto picked = StartupTabFor(OneWindow("https://b.test/page"), "main", "default");
  assert(picked && picked->tab_id == "b" && picked->url == "https://b.test/page");
  assert(StartupTabFor(OneWindow("http://b.test/"), "main", "default"));
}

void SkipsWhatTheShellWouldNotLoadAsIs() {
  for (const char* url : {"", "chrome://settings/", "ray://history", "about:blank", "file:///tmp/a.html",
                          "javascript:1", "data:text/html,x"}) {
    assert(!StartupTabFor(OneWindow(url), "main", "default"));
  }
  for (const char* kind : {"asleep", "frozen", "loaded", "adopted"}) {
    assert(!StartupTabFor(OneWindow("https://b.test/", kind), "main", "default"));
  }
  assert(!StartupTabFor(OneWindow("https://b.test/" + std::string(kMaxUrlBytes, 'x')), "main", "default"));
}

void SkipsAnEmptySessionOrADisabledRestore() {
  assert(!StartupTabFor(base::DictValue(), "main", "default"));
  assert(!StartupTabFor(Session(base::DictValue(), base::DictValue()), "main", "default"));
  assert(!StartupTabFor(Session(base::DictValue().Set("main", Window("main", "", {})), base::DictValue()), "main", "default"));
  base::DictValue off = OneWindow("https://b.test/");
  off.Set("settings", base::DictValue().Set("restoreSession", base::Value(false)));
  assert(!StartupTabFor(off, "main", "default"));
}

void SkipsOtherProfilesAndPrivateOrSmallWindows() {
  assert(!StartupTabFor(OneWindow("https://b.test/"), "main", "work"));
  auto small = Session(base::DictValue().Set("main", Window("small", "b", {"b"})),
                       base::DictValue().Set("b", Tab("main", "https://b.test/")));
  assert(!StartupTabFor(small, "main", "default"));
  auto private_tab = Session(base::DictValue().Set("main", Window("main", "b", {"b"})),
                             base::DictValue().Set("b", Tab("main", "https://b.test/", "idle", "incognito:1")));
  assert(!StartupTabFor(private_tab, "main", "default"));
  auto stray = Session(base::DictValue().Set("main", Window("main", "b", {"b"})),
                       base::DictValue().Set("b", Tab("other", "https://b.test/")));
  assert(!StartupTabFor(stray, "main", "default"));
  assert(ShellProfile("") == "default");
  assert(ShellProfile("incognito:3") == "default");
  assert(ShellProfile("work") == "work");
}

void AdoptsAnotherSavedWindowAsTheLaunchWindow() {
  auto session = Session(base::DictValue().Set("w2", Window("main", "c", {"c"})),
                         base::DictValue().Set("c", Tab("w2", "https://c.test/")));
  base::ListValue order;
  order.Append(base::Value("w2"));
  session.Set("windowOrder", base::Value(std::move(order)));
  session.Set("focusedWindowId", "w2");
  auto picked = StartupTabFor(session, "main", "default");
  assert(picked && picked->tab_id == "c");
  assert(!StartupTabFor(session, "w3", "default"));
  auto small_first = Session(base::DictValue().Set("s", Window("small", "d", {"d"})).Set("w2", Window("main", "c", {"c"})),
                             base::DictValue().Set("d", Tab("s", "https://d.test/")).Set("c", Tab("w2", "https://c.test/")));
  base::ListValue both;
  both.Append(base::Value("s"));
  both.Append(base::Value("w2"));
  small_first.Set("windowOrder", base::Value(std::move(both)));
  small_first.Set("focusedWindowId", "s");
  picked = StartupTabFor(small_first, "main", "default");
  assert(picked && picked->tab_id == "c");
}

}

int main() {
  PicksTheLaunchWindowsActiveTab();
  SkipsWhatTheShellWouldNotLoadAsIs();
  SkipsAnEmptySessionOrADisabledRestore();
  SkipsOtherProfilesAndPrivateOrSmallWindows();
  AdoptsAnotherSavedWindowAsTheLaunchWindow();
  std::puts("startup tab scenarios passed");
}
