// Copyright 2026 Ray. Apache-2.0.

#ifndef CHROME_BROWSER_RAY_AC_EXTENSION_MIRROR_INTERNAL_H_
#define CHROME_BROWSER_RAY_AC_EXTENSION_MIRROR_INTERNAL_H_

#include <set>
#include <string>
#include <string_view>

#include "base/memory/scoped_refptr.h"
#include "chrome/browser/ray/ac_engine.h"
#include "extensions/common/extension.h"
#include "extensions/common/extension_id.h"
#include "extensions/common/mojom/api_permission_id.mojom-shared.h"

class Profile;

namespace content {
class BrowserContext;
}

namespace ray::mirror {

Profile* PrimaryProfile(const Call& call);

Profile* PrimaryProfile(content::BrowserContext* context);

bool ForPrivateSession(const Call& call);

scoped_refptr<const extensions::Extension> EnabledExtension(
    Profile* profile,
    const std::string& id);

scoped_refptr<const extensions::Extension> CallerExtension(Call& call,
                                                           Reply& reply);

scoped_refptr<const extensions::Extension> ExtensionFor(
    Call& call,
    Reply& reply,
    extensions::mojom::APIPermissionID permission,
    std::string_view permission_name);

class Watched : public ProfileState {
 public:
  explicit Watched(Profile* profile);
  ~Watched() override;

  void Set(const extensions::ExtensionId& id, bool on);
  bool Has(const extensions::ExtensionId& id) const;
  bool empty() const { return ids_.empty(); }

 private:
  void Release() override;

  std::set<extensions::ExtensionId> ids_;
};

template <typename T>
bool IsWatched(content::BrowserContext* context,
               const extensions::ExtensionId& id) {
  Profile* profile = PrimaryProfile(context);
  if (!profile) {
    return false;
  }
  const T* watched = ExistingStateFor<T>(profile);
  return watched && watched->Has(id);
}

}

#endif
