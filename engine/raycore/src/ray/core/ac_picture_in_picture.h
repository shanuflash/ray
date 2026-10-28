// Copyright 2026 Ray. Apache-2.0.

#ifndef RAY_CORE_AC_PICTURE_IN_PICTURE_H_
#define RAY_CORE_AC_PICTURE_IN_PICTURE_H_

#include <string>

namespace content {
class WebContents;
}

namespace raycore {

void StartPictureInPictureObserver();

bool PictureInPictureTracing();
void TracePictureInPicture(const std::string& line);

void TraceAutoPictureInPictureInputs(content::WebContents* contents, const char* when);

}

#endif
