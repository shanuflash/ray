// Copyright 2026 Ray. Apache-2.0.

#include <map>
#include <memory>
#include <optional>
#include <set>
#include <string>
#include <utility>

#include "base/functional/bind.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/scoped_refptr.h"
#include "base/memory/weak_ptr.h"
#include "base/scoped_observation.h"
#include "base/task/sequenced_task_runner.h"
#include "base/values.h"
#include "chrome/browser/ray/ac_engine.h"
#include "chrome/browser/ray/ac_extension_mirror_internal.h"
#include "chrome/browser/profiles/profile.h"
#include "extensions/browser/api/permissions/permissions_api_helpers.h"
#include "extensions/browser/extension_install_prompt_client.h"
#include "extensions/browser/extension_management_client.h"
#include "extensions/browser/extension_prefs.h"
#include "extensions/browser/extension_util.h"
#include "extensions/browser/extensions_browser_client.h"
#include "extensions/browser/install_prompt_data.h"
#include "extensions/browser/permissions/permissions_updater.h"
#include "extensions/browser/permissions_manager.h"
#include "extensions/common/api/permissions.h"
#include "extensions/common/extension.h"
#include "extensions/common/manifest_handlers/permissions_parser.h"
#include "extensions/common/permissions/api_permission_set.h"
#include "extensions/common/mojom/manifest.mojom-shared.h"
#include "extensions/common/permissions/manifest_permission_set.h"
#include "extensions/common/permissions/permission_message_provider.h"
#include "extensions/common/permissions/permission_set.h"
#include "extensions/common/permissions/permissions_data.h"
#include "extensions/common/url_pattern.h"
#include "extensions/common/url_pattern_set.h"
#include "ui/gfx/native_ui_types.h"

namespace ray {
namespace {

using extensions::APIPermissionSet;
using extensions::Extension;
using extensions::ManifestPermissionSet;
using extensions::PermissionSet;
using extensions::URLPatternSet;

std::set<std::string> Strings(const base::ListValue* list) {
  std::set<std::string> out;
  if (!list) {
    return out;
  }
  for (const base::Value& value : *list) {
    if (const std::string* text = value.GetIfString()) {
      out.insert(*text);
    }
  }
  return out;
}

base::ListValue ApiNames(const PermissionSet& set) {
  base::ListValue names;
  for (const std::string& name : set.GetAPIsAsStrings()) {
    names.Append(name);
  }
  for (const extensions::ManifestPermission* permission :
       set.manifest_permissions()) {
    names.Append(permission->name());
  }
  return names;
}

base::ListValue HostNames(const PermissionSet& set) {
  std::set<std::string> hosts;
  for (const URLPattern& pattern : set.explicit_hosts()) {
    hosts.insert(pattern.GetAsString());
  }
  for (const URLPattern& pattern : set.scriptable_hosts()) {
    hosts.insert(pattern.GetAsString());
  }
  base::ListValue list;
  for (const std::string& host : hosts) {
    list.Append(host);
  }
  return list;
}

base::DictValue GrantsOf(const Extension& extension) {
  const extensions::PermissionsData* data = extension.permissions_data();
  const PermissionSet& optional =
      extensions::PermissionsParser::GetOptionalPermissions(&extension);
  return base::DictValue()
      .Set("id", extension.id())
      .Set("apis", ApiNames(data->active_permissions()))
      .Set("hosts", HostNames(data->active_permissions()))
      .Set("withheld", HostNames(data->withheld_permissions()))
      .Set("optionalApis", ApiNames(optional))
      .Set("optionalHosts", HostNames(optional));
}

struct Asked {
  std::unique_ptr<const PermissionSet> optional;
  std::unique_ptr<const PermissionSet> withheld;
  std::unique_ptr<const PermissionSet> shown;
};

base::ListValue StringsValue(const std::set<std::string>& strings) {
  base::ListValue list;
  for (const std::string& text : strings) {
    list.Append(text);
  }
  return list;
}

std::optional<Asked> Unpack(Profile* profile,
                            const Extension& extension,
                            const std::set<std::string>& apis,
                            const std::set<std::string>& hosts,
                            std::string& error) {
  std::optional<extensions::api::permissions::Permissions> input =
      extensions::api::permissions::Permissions::FromValue(
          base::DictValue()
              .Set("permissions", StringsValue(apis))
              .Set("origins", StringsValue(hosts)));
  if (!input) {
    error = "the permissions aren't valid";
    return std::nullopt;
  }
  std::unique_ptr<extensions::permissions_api_helpers::UnpackPermissionSetResult>
      unpacked = extensions::permissions_api_helpers::UnpackPermissionSet(
          *input,
          extensions::PermissionsParser::GetRequiredPermissions(&extension),
          extensions::PermissionsParser::GetOptionalPermissions(&extension),
          extensions::util::AllowFileAccess(extension.id(), profile), &error);
  if (!unpacked) {
    return std::nullopt;
  }
  if (!unpacked->unlisted_apis.empty() || !unpacked->unlisted_hosts.is_empty()) {
    error = "Only permissions specified in the manifest may be requested.";
    return std::nullopt;
  }
  if (!unpacked->restricted_file_scheme_patterns.is_empty()) {
    error = "Extension must have file access enabled to request '" +
            unpacked->restricted_file_scheme_patterns.begin()->GetAsString() +
            "'.";
    return std::nullopt;
  }
  const PermissionSet& active =
      extension.permissions_data()->active_permissions();
  std::unique_ptr<const PermissionSet> optional =
      PermissionSet::CreateDifference(
          PermissionSet(std::move(unpacked->optional_apis),
                        ManifestPermissionSet(),
                        std::move(unpacked->optional_explicit_hosts),
                        URLPatternSet()),
          active);
  URLPatternSet explicit_hosts;
  for (const URLPattern& host : unpacked->required_explicit_hosts) {
    if (!active.explicit_hosts().ContainsPattern(host)) {
      explicit_hosts.AddPattern(host);
    }
  }
  URLPatternSet scriptable_hosts;
  for (const URLPattern& host : unpacked->required_scriptable_hosts) {
    if (!active.scriptable_hosts().ContainsPattern(host)) {
      scriptable_hosts.AddPattern(host);
    }
  }
  auto withheld = std::make_unique<const PermissionSet>(
      APIPermissionSet(), ManifestPermissionSet(), std::move(explicit_hosts),
      std::move(scriptable_hosts));
  std::unique_ptr<const PermissionSet> total =
      PermissionSet::CreateUnion(*withheld, *optional);
  if (!total->IsEmpty()) {
    extensions::ExtensionManagementClient* management =
        extensions::ExtensionsBrowserClient::Get()
            ->GetExtensionManagementClient(profile);
    if (!management ||
        !management->IsPermissionSetAllowed(&extension, *total)) {
      error = "Permissions are blocked by enterprise policy.";
      return std::nullopt;
    }
    std::unique_ptr<const PermissionSet> granted =
        extensions::ExtensionPrefs::Get(profile)->GetRuntimeGrantedPermissions(
            extension.id());
    if (granted) {
      total = PermissionSet::CreateDifference(
          *total, *PermissionSet::CreateIntersection(*granted, *optional));
    }
  }
  return Asked{std::move(optional), std::move(withheld), std::move(total)};
}

bool NeedsPrompt(const Extension& extension, const PermissionSet& shown) {
  if (extension.location() == extensions::mojom::ManifestLocation::kComponent) {
    return false;
  }
  const extensions::PermissionMessageProvider* messages =
      extensions::PermissionMessageProvider::Get();
  return !messages
              ->GetPermissionMessages(
                  messages->GetAllPermissionIDs(shown, extension.GetType()))
              .empty();
}

class GrantsWatch : public ProfileState,
                    public extensions::PermissionsManager::Observer {
 public:
  explicit GrantsWatch(Profile* profile) : ProfileState(profile) {
    if (auto* manager = extensions::PermissionsManager::Get(profile)) {
      observation_.Observe(manager);
    }
  }

  ~GrantsWatch() override { Release(); }

 private:
  void Release() override {
    observation_.Reset();
    weak_factory_.InvalidateWeakPtrs();
  }

  void OnExtensionPermissionsUpdated(
      const Extension& extension,
      const PermissionSet& permissions,
      extensions::PermissionsManager::UpdateReason reason) override {
    base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(&GrantsWatch::Changed,
                                  weak_factory_.GetWeakPtr(), extension.id()));
  }

  void Changed(const extensions::ExtensionId& id) {
    scoped_refptr<const Extension> extension =
        mirror::EnabledExtension(profile(), id);
    if (!extension) {
      return;
    }
    Emit("extensions.grants", profile(), GrantsOf(*extension));
  }

  base::ScopedObservation<extensions::PermissionsManager,
                          extensions::PermissionsManager::Observer>
      observation_{this};
  base::WeakPtrFactory<GrantsWatch> weak_factory_{this};
};

void Grant(Profile* profile,
           scoped_refptr<const Extension> extension,
           std::unique_ptr<const PermissionSet> optional,
           std::unique_ptr<const PermissionSet> withheld,
           Reply reply) {
  auto answer = base::BindOnce(
      [](base::WeakPtr<Profile> profile, std::string id, Reply reply) {
        scoped_refptr<const Extension> extension =
            mirror::EnabledExtension(profile.get(), id);
        if (!extension) {
          reply.Error("the extension went away");
          return;
        }
        reply.Send(GrantsOf(*extension).Set("granted", true));
      },
      profile->GetWeakPtr(), extension->id(), std::move(reply));
  auto runtime = base::BindOnce(
      [](base::WeakPtr<Profile> profile,
         scoped_refptr<const Extension> extension,
         std::unique_ptr<const PermissionSet> withheld,
         base::OnceClosure answer) {
        if (!profile || withheld->IsEmpty()) {
          std::move(answer).Run();
          return;
        }
        extensions::PermissionsUpdater(profile.get())
            .GrantRuntimePermissions(*extension, *withheld, std::move(answer));
      },
      profile->GetWeakPtr(), extension, std::move(withheld), std::move(answer));
  if (optional->IsEmpty()) {
    std::move(runtime).Run();
    return;
  }
  extensions::PermissionsUpdater(profile).GrantOptionalPermissions(
      *extension, *optional, std::move(runtime));
}

class GrantPrompts : public ProfileState {
 public:
  using ProfileState::ProfileState;

  void Ask(scoped_refptr<const Extension> extension, Asked asked, Reply reply) {
    std::unique_ptr<extensions::ExtensionInstallPromptClient> prompt =
        extensions::ExtensionsBrowserClient::Get()
            ->CreateInstallPromptForNativeWindow(
                gfx::NativeWindow(), *profile(),
                std::make_unique<extensions::InstallPromptData>(
                    extensions::InstallPromptData::PERMISSIONS_PROMPT));
    if (!prompt) {
      reply.Error("Ray can't ask for permissions right now.");
      return;
    }
    const int key = ++next_key_;
    extensions::ExtensionInstallPromptClient* raw = prompt.get();
    prompts_.emplace(key, std::move(prompt));
    const Extension* shown_for = extension.get();
    std::unique_ptr<const PermissionSet> shown = std::move(asked.shown);
    raw->ConfirmPermissions(
        base::BindOnce(&GrantPrompts::Answered, weak_factory_.GetWeakPtr(),
                       key, std::move(extension), std::move(asked.optional),
                       std::move(asked.withheld), std::move(reply)),
        shown_for, std::move(shown));
  }

 private:
  void Release() override {
    weak_factory_.InvalidateWeakPtrs();
    prompts_.clear();
  }

  void Answered(
      int key,
      scoped_refptr<const Extension> extension,
      std::unique_ptr<const PermissionSet> optional,
      std::unique_ptr<const PermissionSet> withheld,
      Reply reply,
      extensions::ExtensionInstallPromptClient::DoneCallbackPayload payload) {
    auto it = prompts_.find(key);
    if (it != prompts_.end()) {
      base::SequencedTaskRunner::GetCurrentDefault()->DeleteSoon(
          FROM_HERE, std::move(it->second));
      prompts_.erase(it);
    }
    if (payload.result !=
        extensions::ExtensionInstallPromptClient::Result::ACCEPTED) {
      scoped_refptr<const Extension> now =
          mirror::EnabledExtension(profile(), extension->id());
      if (!now) {
        reply.Error("the extension went away");
        return;
      }
      reply.Send(GrantsOf(*now).Set("granted", false));
      return;
    }
    scoped_refptr<const Extension> now =
        mirror::EnabledExtension(profile(), extension->id());
    if (!now) {
      reply.Error("the extension went away");
      return;
    }
    if (now.get() != extension.get()) {
      reply.Send(GrantsOf(*now).Set("granted", false));
      return;
    }
    Grant(profile(), std::move(extension), std::move(optional),
          std::move(withheld), std::move(reply));
  }

  std::map<int, std::unique_ptr<extensions::ExtensionInstallPromptClient>>
      prompts_;
  int next_key_ = 0;
  base::WeakPtrFactory<GrantPrompts> weak_factory_{this};
};

}
}

AC_PROFILE_CALL(ac_extension_grants_get, ray::OffTheRecord::kAllow) {
  ray::Reply reply = call.TakeReply();
  Profile* profile = ray::mirror::PrimaryProfile(call);
  ray::StateFor<ray::GrantsWatch>(profile);
  const bool for_private = ray::mirror::ForPrivateSession(call);
  base::ListValue all;
  const base::ListValue* ids = call.args().FindList("ids");
  for (const std::string& id : ray::Strings(ids)) {
    scoped_refptr<const extensions::Extension> extension =
        ray::mirror::EnabledExtension(profile, id);
    if (extension &&
        (!for_private ||
         extensions::util::IsIncognitoEnabled(extension->id(), profile))) {
      all.Append(ray::GrantsOf(*extension));
    }
  }
  reply.Send(base::DictValue().Set("grants", std::move(all)));
}

AC_PROFILE_CALL(ac_extension_grants_request, ray::OffTheRecord::kAllow) {
  ray::Reply reply = call.TakeReply();
  scoped_refptr<const extensions::Extension> extension =
      ray::mirror::CallerExtension(call, reply);
  if (!extension) {
    return;
  }
  Profile* profile = ray::mirror::PrimaryProfile(call);
  std::string error;
  std::optional<ray::Asked> asked = ray::Unpack(
      profile, *extension, ray::Strings(call.args().FindList("apis")),
      ray::Strings(call.args().FindList("hosts")), error);
  if (!asked) {
    reply.Error(error);
    return;
  }
  ray::StateFor<ray::GrantsWatch>(profile);
  if (asked->shown->IsEmpty() &&
      asked->optional->IsEmpty() && asked->withheld->IsEmpty()) {
    reply.Send(ray::GrantsOf(*extension).Set("granted", true));
    return;
  }
  if (ray::NeedsPrompt(*extension, *asked->shown)) {
    ray::StateFor<ray::GrantPrompts>(profile).Ask(
        std::move(extension), std::move(*asked), std::move(reply));
    return;
  }
  ray::Grant(profile, std::move(extension), std::move(asked->optional),
               std::move(asked->withheld), std::move(reply));
}
