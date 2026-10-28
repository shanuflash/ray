#ifndef RAY_CORE_AC_NAVIGATION_HOLD_H_
#define RAY_CORE_AC_NAVIGATION_HOLD_H_

#include <string>

class Profile;

namespace content {
class NavigationThrottleRegistry;
}

namespace raycore {

void HoldNavigationsForRulesets(Profile* profile, const std::string& extension_id);

void ReleaseNavigationHold(Profile* profile, const std::string& reason);

void ReleaseNavigationHoldReady(Profile* profile);

void MaybeAddNavigationHoldThrottle(content::NavigationThrottleRegistry& registry);

}

#endif
