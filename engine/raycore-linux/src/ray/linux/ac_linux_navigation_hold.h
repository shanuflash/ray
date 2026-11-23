#ifndef RAY_LINUX_AC_LINUX_NAVIGATION_HOLD_H_
#define RAY_LINUX_AC_LINUX_NAVIGATION_HOLD_H_

#include <string>

class Profile;

namespace ray {

void InstallLinuxNavigationHold();
void HoldLinuxNavigations(Profile* profile);
void ReleaseLinuxNavigations(Profile* profile, const std::string& why);
bool LinuxNavigationsHeld(Profile* profile);

}

#endif
