#import "ray/core/public/RayCore.h"

#include <cmath>
#include <optional>
#include <string>

#include "base/functional/bind.h"
#include "base/strings/sys_string_conversions.h"
#include "components/zoom/page_zoom.h"
#include "components/zoom/zoom_controller.h"
#include "content/public/browser/web_contents.h"
#include "content/public/common/page_zoom.h"
#include "third_party/blink/public/common/page/page_zoom.h"
#include "third_party/skia/include/core/SkColor.h"
#include "ray/core/ac_browser.h"
#include "ray/core/ac_contents_background.h"
#include "ray/core/ac_page_channel.h"
#import "ray/core/raycore_api_internal.h"
#import "ray/core/raycore_internal.h"
#import "ray/core/raycore_tab_internal.h"

using raycore::NS;

@implementation RayCoreTab (Page)

- (double)zoomFactor {
  return _contents ? blink::ZoomLevelToZoomFactor(
                         zoom::ZoomController::GetZoomLevelForWebContents(_contents))
                   : 1;
}

- (void)setZoomFactor:(double)zoomFactor {
  if (!_contents || zoomFactor <= 0) {
    return;
  }
  if (auto* zoom = zoom::ZoomController::FromWebContents(_contents)) {
    zoom->SetZoomLevel(blink::ZoomFactorToZoomLevel(zoomFactor));
  }
}

- (void)zoomStep:(int)direction {
  if (_contents) {
    zoom::PageZoom::Zoom(_contents, direction > 0   ? content::PAGE_ZOOM_IN
                                    : direction < 0 ? content::PAGE_ZOOM_OUT
                                                    : content::PAGE_ZOOM_RESET);
  }
}

- (double)pinchScale {
  return _contents ? raycore::TabBridge::GetOrCreate(_contents)->pinch_scale() : 1;
}

- (NSColor*)pageBackgroundColor {
  return _pageBackgroundColor;
}

- (NSString*)pageColor {
  if (!_contents) {
    return nil;
  }
  auto* channel = raycore::PageChannel::FromWebContents(_contents);
  return channel && !channel->page_color().empty()
             ? base::SysUTF8ToNSString(channel->page_color())
             : nil;
}

- (void)setPageColor:(NSString*)color {
  if (_contents) {
    raycore::PageChannel::GetOrCreate(_contents)->SetPageColor(
        color ? base::SysNSStringToUTF8(color) : std::string());
  }
}

- (void)setPageBackgroundColor:(NSColor*)color {
  _pageBackgroundColor = color;
  if (!_contents) {
    return;
  }
  if (!color) {
    raycore::SetHostPageBaseBackgroundColor(_contents, std::nullopt);
    return;
  }
  NSColor* rgb = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
  raycore::SetHostPageBaseBackgroundColor(
      _contents, SkColorSetARGB(rgb.alphaComponent * 255, rgb.redComponent * 255,
                                rgb.greenComponent * 255, rgb.blueComponent * 255));
}

- (NSColor*)contentsBackgroundColor {
  std::optional<SkColor> color =
      _contents ? raycore::ContentsBackgroundColor(_contents) : std::nullopt;
  return color ? [NSColor colorWithSRGBRed:SkColorGetR(*color) / 255.0
                                     green:SkColorGetG(*color) / 255.0
                                      blue:SkColorGetB(*color) / 255.0
                                     alpha:1]
               : nil;
}

- (void)setContentsBackgroundColor:(NSColor*)color {
  if (!_contents) {
    return;
  }
  NSColor* rgb = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
  raycore::SetContentsBackgroundColor(
      _contents, rgb ? std::optional<SkColor>(SkColorSetRGB(std::lround(rgb.redComponent * 255),
                                                            std::lround(rgb.greenComponent * 255),
                                                            std::lround(rgb.blueComponent * 255)))
                     : std::nullopt);
}

- (void)executeJavaScript:(NSString*)code frame:(NSString*)frameId {
  if (!_contents) {
    return;
  }
  raycore::EndAheadBlank(_contents);
  raycore::PageChannel* channel =
      raycore::PageChannel::GetOrCreate(_contents);
  if (frameId) {
    channel->ExecuteInFrame(base::SysNSStringToUTF8(frameId),
                            base::SysNSStringToUTF8(code));
  } else {
    channel->Execute(base::SysNSStringToUTF8(code));
  }
}

- (void)evaluate:(NSString*)code completion:(void (^)(NSString*))completion {
  if (!_contents) {
    completion(nil);
    return;
  }
  raycore::EndAheadBlank(_contents);
  raycore::PageChannel::GetOrCreate(_contents)->Evaluate(
      base::SysNSStringToUTF8(code),
      base::BindOnce(
          [](void (^completion)(NSString*), const std::optional<std::string>& json) {
            completion(json ? NS(*json) : nil);
          },
          completion));
}

- (BOOL)hasLiveFrame:(NSString*)frameId {
  return _contents && (!frameId.length ||
                       raycore::PageChannel::GetOrCreate(_contents)->HasFrame(
                           base::SysNSStringToUTF8(frameId)));
}

- (void)callPage:(NSString*)kind json:(NSString*)json {
  if (_contents) {
    raycore::EndAheadBlank(_contents);
    raycore::PageChannel::GetOrCreate(_contents)->CallPage(
        base::SysNSStringToUTF8(kind), base::SysNSStringToUTF8(json));
  }
}

- (void)callFrame:(NSString*)frameId kind:(NSString*)kind json:(NSString*)json {
  if (_contents) {
    raycore::EndAheadBlank(_contents);
    raycore::PageChannel::GetOrCreate(_contents)->CallFrame(
        base::SysNSStringToUTF8(frameId), base::SysNSStringToUTF8(kind),
        base::SysNSStringToUTF8(json));
  }
}

@end
