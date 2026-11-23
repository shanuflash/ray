#ifndef RAY_LINUX_AC_LINUX_IDLE_PROFILE_ENGINE_H_
#define RAY_LINUX_AC_LINUX_IDLE_PROFILE_ENGINE_H_

#include <optional>
#include <string>

class Profile;

namespace content {
class WebContents;
}

namespace raycore {

bool LinuxTabSleepsOrCanSleep(content::WebContents* contents, bool sleep);
std::optional<std::string> LinuxProfileHeldOpenBy(Profile* profile);
std::string ReleaseLinuxIdleProfile(Profile* profile);

}

#endif
