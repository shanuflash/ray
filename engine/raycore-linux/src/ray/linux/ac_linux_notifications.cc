#include "ray/linux/ac_linux_notifications.h"

#include <algorithm>
#include <memory>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "ray/core/ac_launch_switches.h"
#include "ray/linux/ac_linux_notifications_core.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/logging.h"
#include "base/no_destructor.h"
#include "base/strings/string_util.h"
#include "base/strings/utf_string_conversions.h"
#include "base/uuid.h"
#include "chrome/browser/notifications/notification_display_service.h"
#include "chrome/browser/notifications/notification_display_service_impl.h"
#include "chrome/browser/notifications/notification_handler.h"
#include "chrome/browser/profiles/profile.h"
#include "content/public/browser/browser_thread.h"
#include "ui/base/models/image_model.h"
#include "ui/message_center/public/cpp/notification.h"
#include "ui/message_center/public/cpp/notification_types.h"
#include "ui/message_center/public/cpp/notifier_id.h"
#include "url/gurl.h"

namespace raycore {

namespace {

namespace notifications = ray::linux_notifications;

using Done = base::OnceCallback<void(bool, base::Value)>;

constexpr NotificationHandler::Type kRayType = NotificationHandler::Type::NEARBY_SHARE;

notifications::Ledger& Posted() {
  static base::NoDestructor<notifications::Ledger> ledger;
  return *ledger;
}

LinuxNotificationSink& Sink() {
  static base::NoDestructor<LinuxNotificationSink> sink;
  return *sink;
}

void Fail(Done done, std::string_view message) {
  std::move(done).Run(false, base::Value(base::DictValue().Set("code", "ERR_NOTIFICATION_REQUEST").Set("message", message)));
}

base::Value OrNull(std::optional<std::string> text) {
  return text ? base::Value(std::move(*text)) : base::Value();
}

void Report(notifications::Response response, bool clicked) {
  if (!Sink()) return;
  auto data = base::JSONReader::Read(response.data, base::JSON_PARSE_RFC);
  Sink().Run(response.owner, clicked, base::Value(base::DictValue()
      .Set("id", std::move(response.id))
      .Set("action", std::move(response.action))
      .Set("tabId", OrNull(std::move(response.tab_id)))
      .Set("windowId", OrNull(std::move(response.window_id)))
      .Set("data", data ? std::move(*data) : base::Value())));
}

class Handler : public NotificationHandler {
 public:
  Handler() = default;
  ~Handler() override = default;

  void OnClose(Profile* profile, const GURL& origin, const std::string& notification_id, bool by_user,
               base::OnceClosure completed_closure) override {
    if (const auto id = notifications::RayId(notification_id)) {
      if (auto response = Posted().Closed(*id, by_user)) Report(std::move(*response), false);
    }
    std::move(completed_closure).Run();
  }

  void OnClick(Profile* profile, const GURL& origin, const std::string& notification_id,
               const std::optional<int>& action_index, const std::optional<std::u16string>& reply,
               base::OnceClosure completed_closure) override {
    if (const auto id = notifications::RayId(notification_id)) {
      auto response = Posted().Clicked(*id);
      if (auto* service = profile ? NotificationDisplayServiceImpl::GetForProfile(profile) : nullptr) {
        service->Close(kRayType, notification_id);
      }
      if (response) Report(std::move(*response), true);
    }
    std::move(completed_closure).Run();
  }
};

NotificationDisplayServiceImpl* Service(Profile* profile) {
  if (!profile) return nullptr;
  auto* service = NotificationDisplayServiceImpl::GetForProfile(profile->GetOriginalProfile());
  if (service && !service->GetNotificationHandler(kRayType)) {
    service->AddNotificationHandler(kRayType, std::make_unique<Handler>());
  }
  return service;
}

std::optional<std::string> Text(const base::DictValue& options, std::string_view key, bool* valid) {
  const base::Value* value = options.Find(key);
  if (!value || value->is_none()) return std::nullopt;
  if (!value->is_string() || !base::IsStringUTF8(value->GetString())) {
    *valid = false;
    return std::nullopt;
  }
  return value->GetString();
}

bool Flag(const base::DictValue& options, std::string_view key, bool* valid) {
  const base::Value* value = options.Find(key);
  if (!value || value->is_none()) return false;
  if (!value->is_bool()) {
    *valid = false;
    return false;
  }
  return value->GetBool();
}

void PostNotification(const base::ListValue& args, Profile* profile, int owner, Done done) {
  if (args.size() != 1 || !args[0].is_dict()) return Fail(std::move(done), "postNotification takes its options");
  const base::DictValue& options = args[0].GetDict();
  bool valid = true;
  notifications::Post post;
  post.id = Text(options, "id", &valid).value_or(base::Uuid::GenerateRandomV4().AsLowercaseString());
  const std::string title = Text(options, "title", &valid).value_or(std::string());
  const std::string body = Text(options, "body", &valid).value_or(std::string());
  const std::string subtitle = Text(options, "subtitle", &valid).value_or(std::string());
  post.silent = Flag(options, "silent", &valid);
  post.dismissible = Flag(options, "dismissible", &valid);
  post.tab_id = Text(options, "tabId", &valid);
  post.window_id = Text(options, "windowId", &valid);
  post.owner = owner;
  if (const base::Value* data = options.Find("data"); data && !data->is_none()) {
    auto json = data->is_dict() ? base::WriteJson(*data) : std::nullopt;
    if (!json || json->size() > notifications::kDataBytes) valid = false;
    else post.data = std::move(*json);
  }
  if (!valid || !notifications::ValidId(post.id) || (post.tab_id && !notifications::ValidReference(*post.tab_id)) ||
      (post.window_id && !notifications::ValidReference(*post.window_id))) {
    return Fail(std::move(done), "The notification options are not valid");
  }
  if (BackgroundInstance()) {
    LOG(INFO) << "Ray background instance: not showing a desktop notification";
    return std::move(done).Run(true, base::Value());
  }
  NotificationDisplayServiceImpl* service = Service(profile);
  if (!service) return std::move(done).Run(true, base::Value());
  message_center::RichNotificationData fields;
  fields.silent = post.silent;
  fields.renotify = true;
  const std::string chromium_id = notifications::ChromiumId(post.id);
  const message_center::Notification notification(
      message_center::NOTIFICATION_TYPE_SIMPLE, chromium_id,
      base::UTF8ToUTF16(notifications::Clip(title, notifications::kTitleBytes)),
      base::UTF8ToUTF16(notifications::BodyText(subtitle, body)), ui::ImageModel(), std::u16string(), GURL(),
      message_center::NotifierId(message_center::NotifierType::APPLICATION, "dev.ray.linux"), fields, nullptr);
  std::string id = post.id;
  for (const std::string& evicted : Posted().Add(std::move(post))) {
    service->Close(kRayType, notifications::ChromiumId(evicted));
  }
  service->Display(kRayType, notification, nullptr);
  std::move(done).Run(true, base::Value(std::move(id)));
}

void RemoveNotifications(const base::ListValue& args, Profile* profile, Done done) {
  if (args.size() != 1 || !args[0].is_list() || args[0].GetList().size() > notifications::kRemovedAtOnce) {
    return Fail(std::move(done), "removeNotifications takes a list of ids");
  }
  NotificationDisplayServiceImpl* service = BackgroundInstance() ? nullptr : Service(profile);
  for (const base::Value& id : args[0].GetList()) {
    if (!id.is_string() || !notifications::ValidId(id.GetString())) continue;
    if (Posted().Remove(id.GetString()) && service) service->Close(kRayType, notifications::ChromiumId(id.GetString()));
  }
  std::move(done).Run(true, base::Value());
}

}

void InitLinuxNotifications(LinuxNotificationSink sink) {
  Sink() = std::move(sink);
}

bool LinuxNotificationsInvokes(std::string_view method) {
  return std::ranges::any_of(notifications::kNotificationCapabilities, [method](const char* handled) { return method == handled; });
}

void LinuxNotificationsInvoke(std::string_view method, const base::ListValue& args, Profile* profile, int owner, Done done) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (method == "RayApp.postNotification") return PostNotification(args, profile, owner, std::move(done));
  if (method == "RayApp.removeNotifications") return RemoveNotifications(args, profile, std::move(done));
  if (!args.empty()) return Fail(std::move(done), "The notification permission calls take no arguments");
  if (method == "RayApp.notificationPermission") {
    return std::move(done).Run(true, base::Value(notifications::PermissionName(BackgroundInstance())));
  }
  if (method == "RayApp.requestNotificationPermission") {
    return std::move(done).Run(true, base::Value(!BackgroundInstance()));
  }
  Fail(std::move(done), "Unsupported notification operation");
}

}
