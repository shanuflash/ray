#ifndef RAY_LINUX_AC_LINUX_OPEN_URLS_H_
#define RAY_LINUX_AC_LINUX_OPEN_URLS_H_

#include <cstddef>
#include <string>
#include <string_view>
#include <vector>

namespace ray::linux_open_urls {

inline constexpr char kEventCapability[] = "RayShell.onOpenURLs";
inline constexpr char kListenCall[] = "RayShell.listenForOpenURLs";
inline constexpr const char* kOpenUrlCapabilities[] = {"RayShell.onOpenURLs", "RayShell.listenForOpenURLs"};

inline constexpr size_t kUrlBytes = 32 * 1024;
inline constexpr size_t kLaunchUrls = 64;
inline constexpr size_t kPendingUrls = 256;

struct Launch {
  std::vector<std::string> switches;
  std::vector<std::string> urls;
  bool background = false;
  bool process_startup = false;
  bool has_window = false;
};

bool SwitchKeepsChromiumOpening(std::string_view name);
bool SchemeGoesToShell(std::string_view url);
bool ShellTakesLaunch(const Launch& launch);

class Inbox {
 public:
  Inbox();
  ~Inbox();
  Inbox(const Inbox&) = delete;
  Inbox& operator=(const Inbox&) = delete;

  size_t Add(const std::vector<std::string>& urls);
  std::vector<std::string> Take();
  bool empty() const { return urls_.empty(); }
  size_t pending() const { return urls_.size(); }

 private:
  std::vector<std::string> urls_;
};

}

#endif
