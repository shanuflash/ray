#ifndef RAY_LINUX_AC_LINUX_PAGE_COMMITS_H_
#define RAY_LINUX_AC_LINUX_PAGE_COMMITS_H_

#include <optional>

#include "base/values.h"

namespace raycore {

inline constexpr char kLinuxReportCommitsRoute[] = "tabs.reportCommits";
inline constexpr const char* kLinuxPageCommitRoutes[] = {"tabs.reportCommits"};

inline std::optional<bool> LinuxReportCommits(const base::DictValue& input) {
  return input.FindBool("on");
}

struct LinuxPageCommits {
  double at = 0;
  int http_status = 0;
  void Note(double now_ms, int status) {
    at = now_ms;
    http_status = status;
  }
  void Reset() {
    at = 0;
    http_status = 0;
  }
  void Report(base::DictValue& navigation) const {
    navigation.Set("committedAt", at);
    if (http_status > 0) navigation.Set("httpStatus", http_status);
  }
};

}

#endif
