// Copyright 2026 Ray. Apache-2.0.

#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "base/barrier_callback.h"
#include "base/functional/bind.h"
#include "base/memory/scoped_refptr.h"
#include "base/memory/weak_ptr.h"
#include "base/task/sequenced_task_runner.h"
#include "base/values.h"
#include "chrome/browser/ray/ac_engine.h"
#include "chrome/browser/ray/ac_extension_mirror_internal.h"
#include "chrome/browser/profiles/profile.h"
#include "extensions/browser/api/declarative_net_request/composite_matcher.h"
#include "extensions/browser/api/declarative_net_request/constants.h"
#include "extensions/browser/api/declarative_net_request/file_backed_ruleset_source.h"
#include "extensions/browser/api/declarative_net_request/prefs_helper.h"
#include "extensions/browser/api/declarative_net_request/rules_monitor_service.h"
#include "extensions/browser/api/declarative_net_request/ruleset_manager.h"
#include "extensions/browser/api/declarative_net_request/utils.h"
#include "extensions/browser/extension_file_task_runner.h"
#include "extensions/browser/extensions_browser_client.h"
#include "extensions/browser/safe_browsing_delegate.h"
#include "extensions/common/api/declarative_net_request.h"
#include "extensions/common/api/declarative_net_request/constants.h"
#include "extensions/common/api/declarative_net_request/dnr_manifest_data.h"
#include "extensions/common/error_utils.h"
#include "extensions/common/extension.h"
#include "extensions/common/mojom/api_permission_id.mojom-shared.h"
#include "extensions/common/permissions/permissions_data.h"

extern void (*g_ray_dnr_rules_changed)(content::BrowserContext* context,
                                         const std::string& extension_id,
                                         const std::string& kind);

namespace ray {
namespace {

namespace dnr = extensions::declarative_net_request;

class DnrWatched : public mirror::Watched {
 public:
  using mirror::Watched::Watched;
};

void RulesChanged(content::BrowserContext* context,
                  const std::string& extension_id,
                  const std::string& kind) {
  if (!mirror::IsWatched<DnrWatched>(context, extension_id)) {
    return;
  }
  Profile* profile = mirror::PrimaryProfile(context);
  base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](base::WeakPtr<Profile> profile, std::string extension_id,
             std::string kind) {
            if (!profile) {
              return;
            }
            Emit("extensions.dnrChanged", profile.get(),
                 base::DictValue().Set("id", extension_id).Set("kind", kind));
          },
          profile->GetWeakPtr(), extension_id, kind));
}

void InstallHook() {
  if (!g_ray_dnr_rules_changed) {
    g_ray_dnr_rules_changed = &RulesChanged;
  }
}

bool HasDnr(const extensions::Extension& extension) {
  const extensions::PermissionsData* data = extension.permissions_data();
  return data->HasAPIPermission(
             extensions::mojom::APIPermissionID::kDeclarativeNetRequest) ||
         data->HasAPIPermission(extensions::mojom::APIPermissionID::
                                    kDeclarativeNetRequestWithHostAccess);
}

scoped_refptr<const extensions::Extension> DnrExtension(Call& call,
                                                        Reply& reply) {
  scoped_refptr<const extensions::Extension> extension =
      mirror::CallerExtension(call, reply);
  if (!extension) {
    return nullptr;
  }
  if (!HasDnr(*extension)) {
    reply.Error(
        "The extension doesn't have the declarativeNetRequest permission.");
    return nullptr;
  }
  InstallHook();
  return extension;
}

namespace dnr_api = extensions::api::declarative_net_request;

using Rules = std::vector<dnr_api::Rule>;

base::ListValue OptionsArgs(const Call& call) {
  const base::DictValue* options = call.args().FindDict("options");
  base::ListValue args;
  args.Append(options ? options->Clone() : base::DictValue());
  return args;
}

dnr::RulesMonitorService* ServiceFor(Call& call, Reply& reply) {
  auto* service = dnr::RulesMonitorService::Get(mirror::PrimaryProfile(call));
  if (!service) {
    reply.Error("declarativeNetRequest isn't available");
  }
  return service;
}

void Finished(Reply reply, std::optional<std::string> error) {
  if (error) {
    reply.Error(*error);
    return;
  }
  reply.Ok();
}

void NotifyAddedRules(Profile* profile,
                      const extensions::ExtensionId& id,
                      const Rules& rules) {
  extensions::SafeBrowsingDelegate* delegate =
      extensions::ExtensionsBrowserClient::Get()->GetSafeBrowsingDelegate();
  if (rules.empty() || !delegate) {
    return;
  }
  delegate->NotifyExtensionApiDeclarativeNetRequest(profile, id, rules);
}

const dnr::DNRManifestData::RulesetInfo* RulesetNamed(
    const extensions::Extension& extension,
    const std::string& public_id) {
  const dnr::DNRManifestData::ManifestIDToRulesetMap& rulesets =
      dnr::DNRManifestData::GetManifestIDToRulesetMap(extension);
  auto it = rulesets.find(public_id);
  return it == rulesets.end() ? nullptr : it->second.get();
}

std::string InvalidRuleset(const std::string& public_id) {
  return extensions::ErrorUtils::FormatErrorMessage(
      dnr::kInvalidRulesetIDError, public_id);
}

template <typename Params>
void UpdateRules(Call& call, bool dynamic) {
  Reply reply = call.TakeReply();
  scoped_refptr<const extensions::Extension> extension =
      DnrExtension(call, reply);
  if (!extension) {
    return;
  }
  auto params = Params::Create(OptionsArgs(call));
  if (!params) {
    reply.Error("the rule update isn't valid");
    return;
  }
  std::vector<int> remove =
      std::move(params->options.remove_rule_ids).value_or(std::vector<int>());
  Rules add = std::move(params->options.add_rules).value_or(Rules());
  if (remove.empty() && add.empty()) {
    reply.Ok();
    return;
  }
  dnr::RulesMonitorService* service = ServiceFor(call, reply);
  if (!service) {
    return;
  }
  NotifyAddedRules(mirror::PrimaryProfile(call), extension->id(), add);
  auto done = base::BindOnce(&Finished, std::move(reply));
  if (dynamic) {
    service->UpdateDynamicRules(*extension, std::move(remove), std::move(add),
                                std::move(done));
  } else {
    service->UpdateSessionRules(*extension, std::move(remove), std::move(add),
                                std::move(done));
  }
}

base::ListValue RulesValue(
    const std::vector<extensions::api::declarative_net_request::Rule>& rules) {
  base::ListValue list;
  for (const auto& rule : rules) {
    list.Append(rule.ToValue());
  }
  return list;
}

}
}

AC_PROFILE_CALL(ac_extension_dnr_get_dynamic_rules,
                ray::OffTheRecord::kAllow) {
  ray::Reply reply = call.TakeReply();
  scoped_refptr<const extensions::Extension> extension =
      ray::DnrExtension(call, reply);
  if (!extension) {
    return;
  }
  auto source = ray::dnr::FileBackedRulesetSource::CreateDynamic(
      ray::mirror::PrimaryProfile(call), extension->id());
  extensions::GetExtensionFileTaskRunner()->PostTaskAndReplyWithResult(
      FROM_HERE,
      base::BindOnce(
          [](const ray::dnr::FileBackedRulesetSource& source) {
            return source.ReadJSONRules();
          },
          std::move(source)),
      base::BindOnce(
          [](ray::Reply reply, ray::dnr::ReadJSONRulesResult result) {
            using Status = ray::dnr::ReadJSONRulesResult::Status;
            if (result.status == Status::kFileReadError ||
                result.status == Status::kRulesetFileSizeLimitExceeded) {
              reply.Error(ray::dnr::kInternalErrorGettingDynamicRules);
              return;
            }
            reply.Send(base::DictValue().Set(
                "rules", ray::RulesValue(result.rules)));
          },
          std::move(reply)));
}

AC_PROFILE_CALL(ac_extension_dnr_get_session_rules,
                ray::OffTheRecord::kAllow) {
  ray::Reply reply = call.TakeReply();
  scoped_refptr<const extensions::Extension> extension =
      ray::DnrExtension(call, reply);
  if (!extension) {
    return;
  }
  auto* service =
      ray::dnr::RulesMonitorService::Get(ray::mirror::PrimaryProfile(call));
  if (!service) {
    reply.Error("declarativeNetRequest isn't available");
    return;
  }
  reply.Send(base::DictValue().Set(
      "rules", service->GetSessionRulesValue(extension->id()).Clone()));
}

AC_PROFILE_CALL(ac_extension_dnr_get_enabled_rulesets,
                ray::OffTheRecord::kAllow) {
  ray::Reply reply = call.TakeReply();
  scoped_refptr<const extensions::Extension> extension =
      ray::DnrExtension(call, reply);
  if (!extension) {
    return;
  }
  auto* service =
      ray::dnr::RulesMonitorService::Get(ray::mirror::PrimaryProfile(call));
  if (!service) {
    reply.Error("declarativeNetRequest isn't available");
    return;
  }
  base::ListValue ids;
  const ray::dnr::CompositeMatcher* matcher =
      service->ruleset_manager()->GetMatcherForExtension(extension->id());
  if (matcher) {
    for (const std::string& id :
         ray::dnr::GetPublicRulesetIDs(*extension, *matcher)) {
      if (!id.empty() && id[0] != ray::dnr::kReservedRulesetIDPrefix) {
        ids.Append(id);
      }
    }
  }
  reply.Send(base::DictValue().Set("rulesets", std::move(ids)));
}

AC_PROFILE_CALL(ac_extension_dnr_watch, ray::OffTheRecord::kAllow) {
  ray::Reply reply = call.TakeReply();
  const std::string id = call.String("id");
  if (id.empty()) {
    reply.Error("id is missing");
    return;
  }
  ray::InstallHook();
  ray::StateFor<ray::DnrWatched>(ray::mirror::PrimaryProfile(call))
      .Set(id, call.Bool("on", true));
  reply.Ok();
}

AC_PROFILE_CALL(ac_extension_dnr_get_disabled_rule_ids,
                ray::OffTheRecord::kAllow) {
  ray::Reply reply = call.TakeReply();
  scoped_refptr<const extensions::Extension> extension =
      ray::DnrExtension(call, reply);
  if (!extension) {
    return;
  }
  ray::dnr::RulesMonitorService* service = ray::ServiceFor(call, reply);
  if (!service) {
    return;
  }
  const ray::dnr::DNRManifestData::ManifestIDToRulesetMap& rulesets =
      ray::dnr::DNRManifestData::GetManifestIDToRulesetMap(*extension);
  using Disabled = std::pair<std::string, std::vector<int>>;
  auto collect = base::BarrierCallback<Disabled>(
      rulesets.size(),
      base::BindOnce(
          [](ray::Reply reply, std::vector<Disabled> found) {
            base::DictValue all;
            for (auto& [public_id, ids] : found) {
              base::ListValue list;
              for (int id : ids) {
                list.Append(id);
              }
              all.Set(public_id, std::move(list));
            }
            reply.Send(base::DictValue().Set("rulesets", std::move(all)));
          },
          std::move(reply)));
  for (const auto& [public_id, info] : rulesets) {
    service->GetDisabledRuleIds(
        *extension, info->id,
        base::BindOnce(
            [](std::string public_id,
               base::OnceCallback<void(Disabled)> collect,
               std::vector<int> ids) {
              std::move(collect).Run({std::move(public_id), std::move(ids)});
            },
            public_id, collect));
  }
}

AC_PROFILE_CALL(ac_extension_dnr_update_dynamic_rules,
                ray::OffTheRecord::kAllow) {
  ray::UpdateRules<ray::dnr_api::UpdateDynamicRules::Params>(call, true);
}

AC_PROFILE_CALL(ac_extension_dnr_update_session_rules,
                ray::OffTheRecord::kAllow) {
  ray::UpdateRules<ray::dnr_api::UpdateSessionRules::Params>(call, false);
}

AC_PROFILE_CALL(ac_extension_dnr_update_enabled_rulesets,
                ray::OffTheRecord::kAllow) {
  ray::Reply reply = call.TakeReply();
  scoped_refptr<const extensions::Extension> extension =
      ray::DnrExtension(call, reply);
  if (!extension) {
    return;
  }
  auto params =
      ray::dnr_api::UpdateEnabledRulesets::Params::Create(
          ray::OptionsArgs(call));
  if (!params) {
    reply.Error("the ruleset update isn't valid");
    return;
  }
  std::set<ray::dnr::RulesetID> enable;
  for (const std::string& public_id :
       params->options.enable_ruleset_ids.value_or(
           std::vector<std::string>())) {
    const auto* info = ray::RulesetNamed(*extension, public_id);
    if (!info) {
      reply.Error(ray::InvalidRuleset(public_id));
      return;
    }
    enable.insert(info->id);
  }
  std::set<ray::dnr::RulesetID> disable;
  for (const std::string& public_id :
       params->options.disable_ruleset_ids.value_or(
           std::vector<std::string>())) {
    const auto* info = ray::RulesetNamed(*extension, public_id);
    if (!info) {
      reply.Error(ray::InvalidRuleset(public_id));
      return;
    }
    if (!enable.contains(info->id)) {
      disable.insert(info->id);
    }
  }
  if (enable.empty() && disable.empty()) {
    reply.Ok();
    return;
  }
  ray::dnr::RulesMonitorService* service = ray::ServiceFor(call, reply);
  if (!service) {
    return;
  }
  service->UpdateEnabledStaticRulesets(
      *extension, std::move(disable), std::move(enable),
      base::BindOnce(&ray::Finished, std::move(reply)));
}

AC_PROFILE_CALL(ac_extension_dnr_update_static_rules,
                ray::OffTheRecord::kAllow) {
  ray::Reply reply = call.TakeReply();
  scoped_refptr<const extensions::Extension> extension =
      ray::DnrExtension(call, reply);
  if (!extension) {
    return;
  }
  auto params =
      ray::dnr_api::UpdateStaticRules::Params::Create(
          ray::OptionsArgs(call));
  if (!params) {
    reply.Error("the static rule update isn't valid");
    return;
  }
  const auto* info =
      ray::RulesetNamed(*extension, params->options.ruleset_id);
  if (!info) {
    reply.Error(ray::InvalidRuleset(params->options.ruleset_id));
    return;
  }
  ray::dnr::PrefsHelper::RuleIdsToUpdate ids(
      params->options.disable_rule_ids, params->options.enable_rule_ids);
  if (ids.Empty()) {
    reply.Ok();
    return;
  }
  ray::dnr::RulesMonitorService* service = ray::ServiceFor(call, reply);
  if (!service) {
    return;
  }
  service->UpdateStaticRules(*extension, info->id, std::move(ids),
                             base::BindOnce(&ray::Finished, std::move(reply)));
}
