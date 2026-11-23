#ifndef RAY_LINUX_AC_LINUX_AUTOPLAY_H_
#define RAY_LINUX_AC_LINUX_AUTOPLAY_H_

#include "base/functional/callback.h"

class GURL;

namespace content {
class BrowserContext;
class WebContents;
}

namespace raycore {

bool LinuxAutoplayBlocked(const GURL& url, content::BrowserContext* context);
bool SetLinuxBlockAutoplayEverywhere(bool enabled);
void InstallLinuxAutoplayPolicy();
void FollowLinuxAutoplay(content::WebContents* contents, base::RepeatingCallback<void()> changed);

}

#endif
