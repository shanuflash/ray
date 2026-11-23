#ifndef RAY_LINUX_AC_LINUX_CAPTURE_H_
#define RAY_LINUX_AC_LINUX_CAPTURE_H_

#include <cstddef>
#include <optional>
#include <string>
#include <string_view>

namespace content {
class WebContents;
}

namespace raycore {

namespace linux_capture {

inline constexpr char kChangeCaptureSourceCall[] = "media.changeCaptureSource";
inline constexpr char kStopCaptureCall[] = "media.stopCapture";
inline constexpr const char* kCaptureCapabilities[] = {"media.changeCaptureSource", "media.stopCapture"};

enum class Kind { kSwitch, kStop };

struct Request {
  Kind kind = Kind::kStop;
  std::string capturer;
  std::string target;
};

inline std::optional<Request> ParseCaptureRequest(std::string_view name,
                                                  const std::string* capturer,
                                                  const std::string* target,
                                                  const std::string* tab_id,
                                                  size_t keys) {
  if (name == kChangeCaptureSourceCall) {
    if (keys != 2 || !capturer || !target || capturer->empty() || target->empty() || *capturer == *target) {
      return std::nullopt;
    }
    return Request{Kind::kSwitch, *capturer, *target};
  }
  if (name == kStopCaptureCall) {
    if (keys != 1 || !tab_id || tab_id->empty()) return std::nullopt;
    return Request{Kind::kStop, *tab_id, std::string()};
  }
  return std::nullopt;
}

constexpr bool SharesInstead(int buttons, int share_instead, bool enabled, size_t matches) {
  return matches == 1 && (buttons & share_instead) != 0 && enabled;
}

constexpr bool ReachesTab(bool caller_private, bool tab_private) {
  return caller_private == tab_private;
}

}

bool ShareLinuxTabInstead(content::WebContents* capturer, content::WebContents* target);
bool StopLinuxCapture(content::WebContents* capturer);

}

#endif
