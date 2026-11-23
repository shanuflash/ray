#ifndef RAY_LINUX_AC_LINUX_STARTUP_TAB_H_
#define RAY_LINUX_AC_LINUX_STARTUP_TAB_H_

#include <cstdint>
#include <optional>
#include <string>
#include <string_view>

#include "base/values.h"

namespace linux_startup_tab {

inline constexpr std::string_view kLaunchWindowId = "main";
inline constexpr std::string_view kDefaultProfile = "default";
inline constexpr int64_t kUnclaimedCloseMs = 30000;
inline constexpr size_t kMaxUrlBytes = 8192;

struct StartupTab {
  std::string tab_id;
  std::string url;
};

std::string ShellProfile(std::string_view page_profile);

std::optional<StartupTab> StartupTabFor(const base::DictValue& session, std::string_view window_id,
                                        std::string_view profile);

}

#endif
