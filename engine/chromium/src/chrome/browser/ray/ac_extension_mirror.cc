// Copyright 2026 Ray. Apache-2.0.

#include "chrome/browser/ray/ac_extension_mirror_internal.h"

#include <utility>

#include "base/strings/strcat.h"
#include "chrome/browser/profiles/profile.h"
#include "extensions/browser/extension_registry.h"
#include "extensions/browser/extension_util.h"
#include "extensions/common/permissions/permissions_data.h"

namespace ray::mirror {

Profile* PrimaryProfile(const Call& call) {
  return call.profile() ? call.profile()->GetOriginalProfile() : nullptr;
}

Profile* PrimaryProfile(content::BrowserContext* context) {
  return context ? Profile::FromBrowserContext(context)->GetOriginalProfile()
                 : nullptr;
}

bool ForPrivateSession(const Call& call) {
  return call.Bool("incognito") ||
         (call.profile() && call.profile()->IsOffTheRecord());
}

scoped_refptr<const extensions::Extension> EnabledExtension(
    Profile* profile,
    const std::string& id) {
  if (!profile || id.empty()) {
    return nullptr;
  }
  auto* registry = extensions::ExtensionRegistry::Get(profile);
  if (!registry) {
    return nullptr;
  }
  return base::WrapRefCounted(registry->enabled_extensions().GetByID(id));
}

scoped_refptr<const extensions::Extension> CallerExtension(Call& call,
                                                           Reply& reply) {
  Profile* profile = PrimaryProfile(call);
  scoped_refptr<const extensions::Extension> extension =
      EnabledExtension(profile, call.String("id"));
  if (!extension) {
    reply.Error("the extension isn't enabled in Chromium");
    return nullptr;
  }
  if (ForPrivateSession(call) &&
      !extensions::util::IsIncognitoEnabled(extension->id(), profile)) {
    reply.Error("the extension isn't allowed in private windows");
    return nullptr;
  }
  return extension;
}

scoped_refptr<const extensions::Extension> ExtensionFor(
    Call& call,
    Reply& reply,
    extensions::mojom::APIPermissionID permission,
    std::string_view permission_name) {
  scoped_refptr<const extensions::Extension> extension =
      CallerExtension(call, reply);
  if (!extension) {
    return nullptr;
  }
  if (!extension->permissions_data()->HasAPIPermission(permission)) {
    reply.Error(base::StrCat(
        {"The extension doesn't have the ", permission_name, " permission."}));
    return nullptr;
  }
  return extension;
}

Watched::Watched(Profile* profile) : ProfileState(profile) {}

Watched::~Watched() = default;

void Watched::Set(const extensions::ExtensionId& id, bool on) {
  if (on) {
    ids_.insert(id);
  } else {
    ids_.erase(id);
  }
}

bool Watched::Has(const extensions::ExtensionId& id) const {
  return ids_.contains(id);
}

void Watched::Release() {
  ids_.clear();
}

}
