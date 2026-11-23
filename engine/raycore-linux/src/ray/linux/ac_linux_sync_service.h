#ifndef RAY_LINUX_AC_LINUX_SYNC_SERVICE_H_
#define RAY_LINUX_AC_LINUX_SYNC_SERVICE_H_

#include <string>
#include <string_view>

#include "base/functional/callback.h"
#include "base/values.h"

class Profile;

namespace ray {

class LinuxShellWebView;

struct LinuxSyncCaller {
  std::string key;
  bool private_window = false;
  bool utility = false;
};

bool LinuxSyncInvokes(std::string_view method);
void AppendLinuxSyncCapabilities(base::ListValue& capabilities);
void LinuxSyncInvoke(const LinuxSyncCaller& caller, Profile* app_profile, LinuxShellWebView* shell,
                     const std::string& method, const base::ListValue& values,
                     base::OnceCallback<void(bool, base::Value)> done);

}

#endif
