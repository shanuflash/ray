#ifndef RAY_LINUX_AC_LINUX_TAB_SLEEP_H_
#define RAY_LINUX_AC_LINUX_TAB_SLEEP_H_

#include <optional>

#include "base/values.h"

namespace content {
class WebContents;
}

namespace raycore {

inline constexpr int kLinuxSleepUnavailable = -1;
inline constexpr double kLinuxSleepLongestHiddenSeconds = 7 * 24 * 60 * 60;

std::optional<double> ParseLinuxSleepSeconds(const base::ListValue& args);
base::ListValue SleepLinuxTabIfHidden(content::WebContents* contents, double seconds);

}

#endif
