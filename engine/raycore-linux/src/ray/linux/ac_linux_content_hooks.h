#ifndef RAY_LINUX_AC_LINUX_CONTENT_HOOKS_H_
#define RAY_LINUX_AC_LINUX_CONTENT_HOOKS_H_

#include <utility>
#include <vector>

#include "content/public/browser/media_player_id.h"

namespace content {
class WebContents;

struct RayLinuxPictureInPictureCandidate {
  MediaPlayerId id;
  bool playing = false;
  bool muted = false;
};

std::vector<RayLinuxPictureInPictureCandidate> RayLinuxPictureInPictureCandidates(WebContents* contents);
bool RayLinuxRequestPictureInPicture(WebContents* contents, const MediaPlayerId& id);
}

#endif
