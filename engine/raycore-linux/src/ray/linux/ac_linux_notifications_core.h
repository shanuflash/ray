#ifndef RAY_LINUX_AC_LINUX_NOTIFICATIONS_CORE_H_
#define RAY_LINUX_AC_LINUX_NOTIFICATIONS_CORE_H_

#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace ray::linux_notifications {

inline constexpr const char* kNotificationCapabilities[] = {
    "RayApp.notificationPermission",
    "RayApp.requestNotificationPermission",
    "RayApp.postNotification",
    "RayApp.removeNotifications",
};
inline constexpr char kResponseEvent[] = "onNotificationResponse";

inline constexpr size_t kIdBytes = 256;
inline constexpr size_t kTitleBytes = 1024;
inline constexpr size_t kBodyBytes = 4096;
inline constexpr size_t kReferenceBytes = 256;
inline constexpr size_t kDataBytes = 16 * 1024;
inline constexpr size_t kLiveNotifications = 64;
inline constexpr size_t kRemovedAtOnce = 256;
inline constexpr char kChromiumPrefix[] = "ray:";

struct Post {
  std::string id;
  std::string title;
  std::string body;
  bool silent = false;
  bool dismissible = false;
  std::optional<std::string> tab_id;
  std::optional<std::string> window_id;
  std::string data = "null";
  int owner = 0;
};

struct Response {
  std::string id;
  std::string action;
  std::optional<std::string> tab_id;
  std::optional<std::string> window_id;
  std::string data;
  int owner = 0;
};

bool ValidId(std::string_view id);
bool ValidReference(std::string_view text);
std::string Clip(std::string_view utf8, size_t bytes);
std::string BodyText(std::string_view subtitle, std::string_view body);
std::string ChromiumId(std::string_view id);
std::optional<std::string> RayId(std::string_view chromium_id);
std::string_view PermissionName(bool background);

class Ledger {
 public:
  Ledger();
  ~Ledger();
  Ledger(const Ledger&) = delete;
  Ledger& operator=(const Ledger&) = delete;

  std::vector<std::string> Add(Post post);
  bool Remove(std::string_view id);
  std::optional<Response> Clicked(std::string_view id);
  std::optional<Response> Closed(std::string_view id, bool by_user);
  size_t size() const { return posts_.size(); }

 private:
  std::optional<Post> Take(std::string_view id);

  std::vector<Post> posts_;
};

}

#endif
