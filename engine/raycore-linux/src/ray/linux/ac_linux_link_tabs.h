#ifndef RAY_LINUX_AC_LINUX_LINK_TABS_H_
#define RAY_LINUX_AC_LINUX_LINK_TABS_H_

#include <stddef.h>

#include <functional>
#include <optional>
#include <set>
#include <string>
#include <string_view>
#include <vector>

#include "base/values.h"

namespace raycore {

inline constexpr const char kLinuxPeekOtherSiteTabsRoute[] = "webView.setPeekOtherSiteTabs";
inline constexpr const char kLinuxNewTabLinksInPlaceRoute[] = "webView.setLittleRayOpensNewTabLinks";
inline constexpr const char* kLinuxLinkTabRoutes[] = {"webView.setPeekOtherSiteTabs",
                                                      "webView.setLittleRayOpensNewTabLinks"};
inline constexpr size_t kLinuxPeekSiteTabsMax = 4096;
inline constexpr size_t kLinuxTabKeyMax = 256;
inline constexpr int kLinuxLinkTabTries = 8;
inline constexpr int kLinuxBlankTabTries = 20;
inline constexpr int kLinuxLinkTabRetryMs = 25;
inline constexpr double kLinuxActivationLifespan = 5;

using LinuxTabKeys = std::set<std::string, std::less<>>;

std::optional<LinuxTabKeys> LinuxPeekSiteTabIds(const base::DictValue& input);
std::optional<bool> LinuxNewTabLinksInPlace(const base::DictValue& input);
bool LinuxTabUrlBlank(std::string_view url);

class LinuxPeekSiteTabs {
 public:
  std::vector<std::string> Set(LinuxTabKeys next);
  std::vector<std::string> Clear() { return Set({}); }
  bool Has(std::string_view key) const { return !key.empty() && tabs_.contains(key); }

 private:
  LinuxTabKeys tabs_;
};

class LinuxNewTabLinks {
 public:
  static constexpr double kLifetime = 2;
  static constexpr double kHiddenLifetime = 1;
  static constexpr size_t kKept = 4;
  void Note(std::string_view url, double now);
  std::optional<std::string> TakeFor(std::string_view first, std::string_view current, double now);
  std::optional<std::string> TakeNoted(double within, double now);
  size_t size() const { return links_.size(); }

 private:
  struct Link {
    std::string url;
    double at = 0;
  };
  void DropStale(double now);
  std::vector<Link> links_;
};

struct LinuxLinkTabAttempt {
  std::string_view first_url;
  std::string_view current_url;
  bool hidden = false;
  int tries = 0;
  bool activated = false;
  bool in_place = false;
  double now = 0;
};

enum class LinuxLinkTabStep { kInPlace, kReport, kRetry };

struct LinuxLinkTabMatch {
  LinuxLinkTabStep step = LinuxLinkTabStep::kReport;
  std::string clicked;
  std::string link_wait;
};

LinuxLinkTabMatch MatchLinuxLinkTab(LinuxNewTabLinks& links, const LinuxLinkTabAttempt& attempt);

}

#endif
