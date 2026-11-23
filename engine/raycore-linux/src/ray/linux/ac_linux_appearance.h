#ifndef RAY_LINUX_AC_LINUX_APPEARANCE_H_
#define RAY_LINUX_AC_LINUX_APPEARANCE_H_

#include <optional>
#include <string_view>

namespace ray::linux_appearance {

inline constexpr char kSetAppearanceCall[] = "RayShell.setAppearance";

enum class Appearance { kAuto, kLight, kDark };

inline std::optional<Appearance> ParseAppearance(std::string_view mode) {
  if (mode == "auto") return Appearance::kAuto;
  if (mode == "light") return Appearance::kLight;
  if (mode == "dark") return Appearance::kDark;
  return std::nullopt;
}

}

#endif
