#ifndef RAY_LINUX_AC_LINUX_AUTOMATION_WINDOW_H_
#define RAY_LINUX_AC_LINUX_AUTOMATION_WINDOW_H_

#include <cstddef>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <string_view>

class BrowserWindowInterface;
class Profile;

namespace content {
class WebContents;
}

namespace raycore {

namespace linux_automation_window {

inline constexpr char kOwnsTabCall[] = "engine.cliOwnsTab";
inline constexpr char kMoveOffscreenCall[] = "engine.cliMoveOffscreen";
inline constexpr char kCloseOffscreenTabsCall[] = "engine.cliCloseOffscreenTabs";
inline constexpr char kTabTargetsCall[] = "engine.cliTabTargets";
inline constexpr const char* kCapabilities[] = {"engine.cliOwnsTab", "engine.cliMoveOffscreen",
                                                "engine.cliCloseOffscreenTabs", "engine.cliTabTargets"};
inline constexpr size_t kMaxTargetTabs = 512;

struct OffscreenTab {
  bool found = false;
  bool discarded = false;
  bool private_session = false;
  bool presented = false;
  bool shown_before = false;
  bool in_strip = false;
};

inline std::optional<std::string_view> OffscreenRefusal(const OffscreenTab& tab) {
  if (!tab.found || tab.discarded) return "That tab has no page loaded.";
  if (tab.private_session) return "Private tabs can't go off-screen on Linux.";
  if (tab.presented || tab.shown_before) return "That tab is shown in a window, so it can't go off-screen.";
  if (!tab.in_strip) return "Ray couldn't take that tab off-screen.";
  return std::nullopt;
}

constexpr bool TabIdCountAllowed(size_t count) {
  return count <= kMaxTargetTabs;
}

class TargetGenerations {
 public:
  int Record(const std::string& tab, const std::optional<std::string>& target) {
    if (target) {
      const auto last = last_.find(tab);
      if (last == last_.end() || last->second != *target) {
        last_[tab] = *target;
        ++generations_[tab];
      }
    }
    const auto found = generations_.find(tab);
    return found == generations_.end() ? 0 : found->second;
  }

 private:
  std::map<std::string, std::string> last_;
  std::map<std::string, int> generations_;
};

}

BrowserWindowInterface* LinuxAutomationWindowFor(Profile* profile);
bool IsLinuxAutomationWindow(const BrowserWindowInterface* browser);
bool InsertIntoLinuxAutomationWindow(BrowserWindowInterface* window, std::unique_ptr<content::WebContents> contents);
void CloseLinuxOffscreenTabs();
std::optional<std::string> LinuxDevToolsTargetId(content::WebContents* contents);

}

#endif
