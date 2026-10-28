// Copyright 2026 Ray. Apache-2.0.

#ifndef RAY_CORE_AC_VIDEO_UPSCALING_H_
#define RAY_CORE_AC_VIDEO_UPSCALING_H_

#include <optional>

@class NSDictionary;

namespace raycore {

void StartVideoUpscaling();

void SetVideoUpscalingEnabled(bool enabled);

void SetVideoUpscalingTestConditions(std::optional<bool> low_power,
                                     std::optional<bool> thermal_pressure);

void VideoUpscalingInputsChanged();

NSDictionary* VideoUpscalingState();

}

#endif
