// Copyright 2026 Ray. Apache-2.0.

#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "base/functional/bind.h"
#include "base/memory/scoped_refptr.h"
#include "base/values.h"
#include "chrome/browser/ray/ac_engine.h"
#include "chrome/browser/ray/ac_extension_mirror_internal.h"
#include "chrome/browser/profiles/profile.h"
#include "extensions/browser/api/storage/storage_area_namespace.h"
#include "extensions/browser/api/storage/storage_frontend.h"
#include "extensions/browser/api/storage/storage_utils.h"
#include "extensions/common/api/storage.h"
#include "extensions/common/extension.h"
#include "extensions/common/mojom/api_permission_id.mojom-shared.h"

extern void (*g_ray_extension_storage_changed)(
    content::BrowserContext* context,
    const std::string& extension_id,
    const char* area,
    const base::Value& changes);

namespace ray {
namespace {

using extensions::StorageAreaNamespace;
using extensions::StorageFrontend;

constexpr size_t kMaxReplyBytes = 25 * 1024 * 1024;

class StorageWatched : public mirror::Watched {
 public:
  using mirror::Watched::Watched;
};

void StorageChanged(content::BrowserContext* context,
                    const std::string& extension_id,
                    const char* area,
                    const base::Value& changes) {
  if (!mirror::IsWatched<StorageWatched>(context, extension_id)) {
    return;
  }
  Profile* profile = mirror::PrimaryProfile(context);
  const StorageAreaNamespace storage_area =
      extensions::StorageAreaFromString(area);
  const bool content_may_read =
      storage_area == StorageAreaNamespace::kInvalid ||
      extensions::storage_utils::GetAccessLevelForArea(
          extension_id, *profile, storage_area) !=
          extensions::api::storage::AccessLevel::kTrustedContexts;
  Emit("extensions.storageChanged", profile,
       base::DictValue()
           .Set("id", extension_id)
           .Set("area", area)
           .Set("contentMayRead", content_may_read)
           .Set("changes", changes.Clone()));
}

void InstallHook() {
  if (!g_ray_extension_storage_changed) {
    g_ray_extension_storage_changed = &StorageChanged;
  }
}

struct Area {
  scoped_refptr<const extensions::Extension> extension;
  StorageAreaNamespace area = StorageAreaNamespace::kInvalid;
  StorageFrontend* frontend = nullptr;
};

std::optional<Area> AreaFor(Call& call, Reply& reply, bool writes) {
  scoped_refptr<const extensions::Extension> extension = mirror::ExtensionFor(
      call, reply, extensions::mojom::APIPermissionID::kStorage, "storage");
  if (!extension) {
    return std::nullopt;
  }
  const StorageAreaNamespace area =
      extensions::StorageAreaFromString(call.String("area"));
  if (area == StorageAreaNamespace::kInvalid) {
    reply.Error("unknown storage area");
    return std::nullopt;
  }
  if (writes && area == StorageAreaNamespace::kManaged) {
    reply.Error("This is a read-only store.");
    return std::nullopt;
  }
  Profile* profile = mirror::PrimaryProfile(call);
  if (call.Bool("content") &&
      extensions::storage_utils::GetAccessLevelForArea(
          extension->id(), *profile, area) ==
          extensions::api::storage::AccessLevel::kTrustedContexts) {
    reply.Error("Access to storage is not allowed from this context.");
    return std::nullopt;
  }
  StorageFrontend* frontend = StorageFrontend::Get(profile);
  if (!frontend) {
    reply.Error("storage isn't available");
    return std::nullopt;
  }
  if (area != StorageAreaNamespace::kSession &&
      !frontend->IsStorageEnabled(
          extensions::StorageAreaToSettingsNamespace(area))) {
    reply.Error("this storage area isn't available");
    return std::nullopt;
  }
  InstallHook();
  return Area{std::move(extension), area, frontend};
}

std::optional<std::vector<std::string>> StringList(const base::ListValue& list) {
  std::vector<std::string> keys;
  keys.reserve(list.size());
  for (const base::Value& value : list) {
    if (const std::string* key = value.GetIfString()) {
      keys.push_back(*key);
    }
  }
  return keys;
}

struct Keys {
  bool valid = true;
  std::optional<std::vector<std::string>> keys;
  std::optional<base::DictValue> defaults;
};

Keys KeysOf(const base::Value* input, bool allow_defaults) {
  Keys out;
  if (!input || input->is_none()) {
    return out;
  }
  if (input->is_string()) {
    out.keys = std::vector<std::string>(1, input->GetString());
  } else if (input->is_list()) {
    out.keys = StringList(input->GetList());
  } else if (allow_defaults && input->is_dict()) {
    std::vector<std::string> keys;
    for (const auto [key, value] : input->GetDict()) {
      keys.push_back(key);
    }
    out.keys = std::move(keys);
    out.defaults = input->GetDict().Clone();
  } else {
    out.valid = false;
  }
  return out;
}

void Finished(Reply reply, StorageFrontend::ResultStatus status) {
  if (!status.success) {
    reply.Error(status.error.value_or("storage failed"));
    return;
  }
  reply.Ok();
}

}
}

AC_PROFILE_CALL(ac_extension_storage_get, ray::OffTheRecord::kAllow) {
  ray::Reply reply = call.TakeReply();
  std::optional<ray::Area> area = ray::AreaFor(call, reply, false);
  if (!area) {
    return;
  }
  ray::Keys keys = ray::KeysOf(call.args().Find("keys"), true);
  if (!keys.valid) {
    reply.Error("keys must be null, a string, a list or an object");
    return;
  }
  area->frontend->GetValues(
      area->extension, area->area, std::move(keys.keys),
      base::BindOnce(
          [](ray::Reply reply, std::optional<base::DictValue> defaults,
             extensions::StorageFrontend::GetResult result) {
            if (!result.status.success || !result.data) {
              reply.Error(result.status.error.value_or("storage failed"));
              return;
            }
            base::DictValue values =
                defaults ? std::move(*defaults) : base::DictValue();
            values.Merge(std::move(*result.data));
            if (values.EstimateMemoryUsage() > ray::kMaxReplyBytes) {
              reply.Error(
                  "The data is too large for a single get(). Use getKeys() "
                  "and read it in smaller batches.");
              return;
            }
            reply.Send(base::DictValue().Set("values", std::move(values)));
          },
          std::move(reply), std::move(keys.defaults)));
}

AC_PROFILE_CALL(ac_extension_storage_get_keys, ray::OffTheRecord::kAllow) {
  ray::Reply reply = call.TakeReply();
  std::optional<ray::Area> area = ray::AreaFor(call, reply, false);
  if (!area) {
    return;
  }
  area->frontend->GetKeys(
      area->extension, area->area,
      base::BindOnce(
          [](ray::Reply reply,
             extensions::StorageFrontend::GetKeysResult result) {
            if (!result.status.success || !result.data) {
              reply.Error(result.status.error.value_or("storage failed"));
              return;
            }
            reply.Send(
                base::DictValue().Set("keys", std::move(*result.data)));
          },
          std::move(reply)));
}

AC_PROFILE_CALL(ac_extension_storage_set, ray::OffTheRecord::kAllow) {
  ray::Reply reply = call.TakeReply();
  std::optional<ray::Area> area = ray::AreaFor(call, reply, true);
  if (!area) {
    return;
  }
  const base::DictValue* values = call.args().FindDict("values");
  if (!values) {
    reply.Error("values must be an object");
    return;
  }
  area->frontend->Set(area->extension, area->area, values->Clone(),
                      base::BindOnce(&ray::Finished, std::move(reply)));
}

AC_PROFILE_CALL(ac_extension_storage_remove, ray::OffTheRecord::kAllow) {
  ray::Reply reply = call.TakeReply();
  std::optional<ray::Area> area = ray::AreaFor(call, reply, true);
  if (!area) {
    return;
  }
  ray::Keys keys = ray::KeysOf(call.args().Find("keys"), false);
  if (!keys.valid || !keys.keys) {
    reply.Error("keys must be a string or a list");
    return;
  }
  area->frontend->Remove(area->extension, area->area, *keys.keys,
                         base::BindOnce(&ray::Finished, std::move(reply)));
}

AC_PROFILE_CALL(ac_extension_storage_clear, ray::OffTheRecord::kAllow) {
  ray::Reply reply = call.TakeReply();
  std::optional<ray::Area> area = ray::AreaFor(call, reply, true);
  if (!area) {
    return;
  }
  area->frontend->Clear(area->extension, area->area,
                        base::BindOnce(&ray::Finished, std::move(reply)));
}

AC_PROFILE_CALL(ac_extension_storage_get_bytes_in_use,
                ray::OffTheRecord::kAllow) {
  ray::Reply reply = call.TakeReply();
  std::optional<ray::Area> area = ray::AreaFor(call, reply, false);
  if (!area) {
    return;
  }
  ray::Keys keys = ray::KeysOf(call.args().Find("keys"), false);
  if (!keys.valid) {
    reply.Error("keys must be null, a string or a list");
    return;
  }
  area->frontend->GetBytesInUse(
      area->extension, area->area, std::move(keys.keys),
      base::BindOnce(
          [](ray::Reply reply, size_t bytes) {
            reply.Send(
                base::DictValue().Set("bytes", static_cast<double>(bytes)));
          },
          std::move(reply)));
}

AC_PROFILE_CALL(ac_extension_storage_set_access_level,
                ray::OffTheRecord::kAllow) {
  ray::Reply reply = call.TakeReply();
  if (call.Bool("content")) {
    reply.Error("Context cannot set the storage access level");
    return;
  }
  std::optional<ray::Area> area = ray::AreaFor(call, reply, false);
  if (!area) {
    return;
  }
  const extensions::api::storage::AccessLevel level =
      extensions::api::storage::ParseAccessLevel(call.String("accessLevel"));
  if (level == extensions::api::storage::AccessLevel::kNone) {
    reply.Error("unknown access level");
    return;
  }
  extensions::storage_utils::SetAccessLevelForArea(
      area->extension->id(), *ray::mirror::PrimaryProfile(call), area->area,
      level);
  reply.Ok();
}

AC_PROFILE_CALL(ac_extension_storage_watch, ray::OffTheRecord::kAllow) {
  ray::Reply reply = call.TakeReply();
  Profile* profile = ray::mirror::PrimaryProfile(call);
  const std::string id = call.String("id");
  if (id.empty()) {
    reply.Error("id is missing");
    return;
  }
  ray::InstallHook();
  ray::StateFor<ray::StorageWatched>(profile).Set(id, call.Bool("on", true));
  reply.Ok();
}
