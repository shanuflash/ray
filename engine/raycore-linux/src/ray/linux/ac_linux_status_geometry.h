#ifndef RAY_LINUX_AC_LINUX_STATUS_GEOMETRY_H_
#define RAY_LINUX_AC_LINUX_STATUS_GEOMETRY_H_

#include <cmath>
#include <optional>

namespace raycore {

struct LinuxStatusPane {
  double x = 0;
  double y = 0;
  double width = 0;
  double height = 0;
};

inline std::optional<double> LinuxPointerFromPageBottom(double pointer_x, double pointer_y, const LinuxStatusPane& pane,
                                                        double shell_scale) {
  if (!std::isfinite(pointer_x) || !std::isfinite(pointer_y) || !std::isfinite(shell_scale) || shell_scale <= 0 ||
      !(pane.width > 0) || !(pane.height > 0)) {
    return std::nullopt;
  }
  if (pointer_x < pane.x || pointer_x >= pane.x + pane.width || pointer_y < pane.y ||
      pointer_y >= pane.y + pane.height) {
    return std::nullopt;
  }
  return (pane.y + pane.height - pointer_y) / shell_scale;
}

}

#endif
