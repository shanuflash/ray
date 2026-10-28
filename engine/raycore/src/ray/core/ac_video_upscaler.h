// Copyright 2026 Ray. Apache-2.0.

#ifndef RAY_CORE_AC_VIDEO_UPSCALER_H_
#define RAY_CORE_AC_VIDEO_UPSCALER_H_

#include <IOSurface/IOSurfaceRef.h>

#include <memory>
#include <vector>

#include "base/apple/scoped_cftyperef.h"
#include "base/functional/callback.h"
#include "ui/gfx/color_space.h"
#include "ui/gfx/geometry/rect_f.h"
#include "ui/gfx/geometry/size_f.h"
#include "ui/gfx/video_types.h"

namespace raycore {

struct VideoUpscaleCandidate {
  IOSurfaceRef source = nullptr;
  gfx::ColorSpace color_space;
  gfx::RectF contents_rect;
  gfx::SizeF target_size;
  gfx::ProtectedVideoType protected_video_type =
      gfx::ProtectedVideoType::kClear;
  bool has_hdr_metadata = false;
  base::apple::ScopedCFTypeRef<IOSurfaceRef> output;
  bool pending = false;
};

class VideoUpscaler {
 public:
  virtual ~VideoUpscaler() = default;
  virtual void Process(bool allowed,
                       std::vector<VideoUpscaleCandidate>& candidates) = 0;
};

std::unique_ptr<VideoUpscaler> CreateVideoUpscaler(
    base::RepeatingClosure on_upscaled);

}

extern std::unique_ptr<raycore::VideoUpscaler> (
    *g_ray_create_video_upscaler)(base::RepeatingClosure on_upscaled);

#endif
