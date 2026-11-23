#ifndef RAY_LINUX_AC_LINUX_POINTER_REGIONS_H_
#define RAY_LINUX_AC_LINUX_POINTER_REGIONS_H_

#include <cstdint>
#include <vector>

namespace ray::linux_window {

struct PassRect {
  int x = 0;
  int y = 0;
  int width = 0;
  int height = 0;
};

constexpr bool ButtonsHeld(int flags, int changed, bool released, int buttons) {
  return ((released ? flags & ~changed : flags) & buttons) != 0;
}

inline bool InPassRegion(const std::vector<PassRect>& pass, int x, int y) {
  for (const PassRect& rect : pass) {
    if (rect.width > 0 && rect.height > 0 && x >= rect.x && y >= rect.y &&
        static_cast<int64_t>(x) - rect.x < rect.width && static_cast<int64_t>(y) - rect.y < rect.height) {
      return true;
    }
  }
  return false;
}

inline bool ShellHoverIsStale(bool shell_hovered, bool button_down, const std::vector<PassRect>& pass, int x, int y) {
  return shell_hovered && !button_down && InPassRegion(pass, x, y);
}

}

#endif
