#ifndef RAY_LINUX_AC_LINUX_CAST_CORE_H_
#define RAY_LINUX_AC_LINUX_CAST_CORE_H_

#include <cstddef>
#include <optional>
#include <string>
#include <string_view>

namespace raycore::linux_cast {

inline constexpr char kShowCall[] = "media.showCastDialog";
inline constexpr char kStartCall[] = "media.startCasting";
inline constexpr char kStopCall[] = "media.stopCasting";
inline constexpr char kCloseCall[] = "media.closeCastDialog";
inline constexpr char kWatchCall[] = "media.watchCastRoutes";
inline constexpr char kTerminateCall[] = "media.terminateCastRoute";
inline constexpr const char* kCastCapabilities[] = {"media.showCastDialog", "media.startCasting",
                                                    "media.stopCasting",    "media.closeCastDialog",
                                                    "media.watchCastRoutes", "media.terminateCastRoute"};
inline constexpr char kDialogEvent[] = "media.castDialog";
inline constexpr char kRoutesEvent[] = "media.castRoutes";
inline constexpr char kTestSinkSwitch[] = "ray-test-cast-sink";
inline constexpr char kTestProviderFlag[] = "mediaRouteProvider";

enum class Verb { kShow, kStart, kStop, kClose, kWatch, kTerminate };

struct Request {
  Verb verb = Verb::kShow;
  std::string tab;
  int dialog = 0;
  std::string sink;
  std::string route;
  int mode = 0;
};

constexpr bool KnownCastMode(int mode) {
  return mode == 1 || mode == 2 || mode == 4 || mode == 8;
}

inline bool Present(const std::string* text) {
  return text && !text->empty();
}

inline bool IsCastCall(std::string_view name) {
  for (const char* call : kCastCapabilities) {
    if (name == call) return true;
  }
  return false;
}

inline Request MakeRequest(Verb verb) {
  Request request;
  request.verb = verb;
  return request;
}

inline std::optional<Request> ParseCastRequest(std::string_view name,
                                               const std::string* tab_id,
                                               std::optional<int> id,
                                               const std::string* sink,
                                               const std::string* route,
                                               std::optional<int> mode,
                                               size_t keys) {
  const bool dialog = id && *id > 0;
  if (name == kShowCall) {
    if (keys != 1 || !Present(tab_id)) return std::nullopt;
    Request request = MakeRequest(Verb::kShow);
    request.tab = *tab_id;
    return request;
  }
  if (name == kStartCall) {
    if (keys != 3 || !dialog || !Present(sink) || !mode || !KnownCastMode(*mode)) return std::nullopt;
    Request request = MakeRequest(Verb::kStart);
    request.dialog = *id;
    request.sink = *sink;
    request.mode = *mode;
    return request;
  }
  if (name == kStopCall) {
    if (keys != 2 || !dialog || !Present(route)) return std::nullopt;
    Request request = MakeRequest(Verb::kStop);
    request.dialog = *id;
    request.route = *route;
    return request;
  }
  if (name == kCloseCall) {
    if (keys != 1 || !dialog) return std::nullopt;
    Request request = MakeRequest(Verb::kClose);
    request.dialog = *id;
    return request;
  }
  if (name == kWatchCall) {
    if (keys != 0) return std::nullopt;
    return MakeRequest(Verb::kWatch);
  }
  if (name == kTerminateCall) {
    if (keys != 1 || !Present(route)) return std::nullopt;
    Request request = MakeRequest(Verb::kTerminate);
    request.route = *route;
    return request;
  }
  return std::nullopt;
}

constexpr bool TestSinkAllowed(bool browser_process, bool test_switch, bool own_user_data) {
  return browser_process && test_switch && own_user_data;
}

}

#endif
