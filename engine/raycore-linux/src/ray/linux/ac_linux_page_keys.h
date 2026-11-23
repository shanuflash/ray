#ifndef RAY_LINUX_AC_LINUX_PAGE_KEYS_H_
#define RAY_LINUX_AC_LINUX_PAGE_KEYS_H_

namespace ray::linux_keys {

inline constexpr char kUnhandledEscapeCapability[] = "tab.unhandledEscape";
inline constexpr const char* kPageKeyCapabilities[] = {"tab.unhandledEscape"};
inline constexpr char kCommandEvent[] = "command";
inline constexpr char kEscapeCommand[] = "escape";
inline constexpr int kEscapeKeyCode = 0x1B;

struct PageKey {
  bool raw_key_down = false;
  int key_code = 0;
  bool control = false;
  bool alt = false;
  bool meta = false;
};

constexpr bool IsUnhandledEscape(const PageKey& key) {
  return key.raw_key_down && key.key_code == kEscapeKeyCode && !key.control && !key.alt && !key.meta;
}

constexpr bool PageTakesEscape(bool bound, bool presented, bool pane_visible) {
  return bound && presented && pane_visible;
}

}

#endif
