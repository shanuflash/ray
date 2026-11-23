// Copyright 2026 Ray. Apache-2.0.

#ifndef CHROME_BROWSER_RAY_PIP_AC_PIP_MAC_H_
#define CHROME_BROWSER_RAY_PIP_AC_PIP_MAC_H_

#include <optional>
#include <vector>

#include "base/time/time.h"
#include "ui/gfx/geometry/rect.h"
#include "ui/gfx/native_ui_types.h"

std::optional<gfx::Rect> LoadRayPictureInPictureBounds();
void SaveRayPictureInPictureBounds(const gfx::Rect& bounds);

void FadeOutRayPictureInPicture(gfx::NativeWindow window,
                                      base::TimeDelta duration);
void ResetRayPictureInPictureFade(gfx::NativeWindow window);

struct RayPipNativeControl {
  const char* name;
  gfx::Rect bounds;
  bool hovered;
  bool pressed;
  float opacity;
};

bool PresentRayPictureInPictureControls(
    gfx::NativeWindow window,
    const std::vector<RayPipNativeControl>& controls);

#endif
