#ifndef RAY_CORE_RAYCORE_TAB_INTERNAL_H_
#define RAY_CORE_RAYCORE_TAB_INTERNAL_H_

#import <AppKit/AppKit.h>

#import "ray/core/public/RayCore.h"
#include "base/memory/raw_ptr.h"

namespace content {
class WebContents;
}

@interface RayCoreTab () {
  raw_ptr<content::WebContents> _contents;
  int _browserId;
  NSColor* __strong _pageBackgroundColor;
}
@end

#endif
