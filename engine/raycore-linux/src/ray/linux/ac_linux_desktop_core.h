#ifndef RAY_LINUX_AC_LINUX_DESKTOP_CORE_H_
#define RAY_LINUX_AC_LINUX_DESKTOP_CORE_H_

#include <cstddef>
#include <functional>
#include <map>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace ray::linux_desktop {

inline constexpr char kDesktopId[] = "ray.desktop";
inline constexpr size_t kEntryLimit = 64 * 1024;
inline constexpr size_t kToolOutputLimit = 4096;
inline constexpr size_t kExternalUrlLimit = 32 * 1024;
inline constexpr int kCheckSeconds = 5;
inline constexpr int kSetSeconds = 15;
inline constexpr const char* kSystemCapabilities[] = {
    "RaySystem.isDefaultBrowser", "RaySystem.setAsDefaultBrowser", "RaySystem.launchAtLoginStatus",
    "RaySystem.setLaunchAtLogin", "RayApp.openExternalURL"};

struct Install {
  Install();
  Install(const Install&);
  Install(Install&&);
  ~Install();
  std::vector<std::string> application_directories;
  std::string autostart_directory;
  std::vector<std::string> search_path;
  std::string launcher;
  std::string executable;
};

using Keys = std::map<std::string, std::string, std::less<>>;

std::optional<Keys> ParseEntry(std::string_view text);
std::optional<std::string> ExecProgram(std::string_view exec);
std::string QuoteExec(std::string_view path);
bool LaunchesThisInstall(std::string_view exec, const Install& install);
std::string FindTool(const Install& install, std::string_view name);

enum class EntryState { kUsable, kMissing, kUnreadable, kHidden, kOtherInstall, kNoHandlers };

struct InstalledEntry {
  EntryState state = EntryState::kMissing;
  std::string path;
};

InstalledEntry FindInstalledEntry(const Install& install);
std::string_view EntryProblem(EntryState state);

struct ToolResult {
  bool ran = false;
  int exit_code = -1;
  std::string output;
};

using ToolRunner = std::function<ToolResult(const std::vector<std::string>& arguments, int seconds)>;

struct DefaultBrowserAnswer {
  bool is_default = false;
  std::string problem;
};

DefaultBrowserAnswer IsDefaultBrowser(const Install& install, const ToolRunner& run);
DefaultBrowserAnswer SetAsDefaultBrowser(const Install& install, const ToolRunner& run);

enum class LoginStatus { kEnabled, kNotRegistered, kNotFound };

struct LoginChange {
  bool ok = false;
  std::string code;
  std::string message;
};

std::string_view LoginStatusName(LoginStatus status);
std::string AutostartEntry(const Install& install);
LoginStatus LaunchAtLoginStatus(const Install& install);
LoginChange SetLaunchAtLogin(const Install& install, bool enabled);

bool ExternalSchemeAllowed(std::string_view scheme);

}

#endif
