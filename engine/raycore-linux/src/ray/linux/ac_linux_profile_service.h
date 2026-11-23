#ifndef RAY_LINUX_AC_LINUX_PROFILE_SERVICE_H_
#define RAY_LINUX_AC_LINUX_PROFILE_SERVICE_H_

#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "ray/linux/ac_linux_profiles.h"
#include "base/functional/callback.h"

class Profile;

namespace raycore {

using LinuxProfileDone = base::OnceCallback<void(Profile*, linux_profiles::ProfileError)>;

bool SetLinuxAppProfile(Profile* profile);
Profile* LinuxProfile(std::string_view id);
bool LinuxProfileHosts(std::string_view id, const Profile* window_profile);
void ResolveLinuxProfile(std::string_view id, LinuxProfileDone done);
std::optional<std::string> LinuxProfileName(const Profile* profile);
std::optional<std::string> LinuxProfileNameForPath(std::string_view path);
bool ReleaseLinuxProfile(std::string_view id);
std::vector<std::string> LoadedLinuxProfiles();
using LinuxProfileDataDeleted =
    base::OnceCallback<void(linux_profiles::ProfileError, std::vector<std::string> remaining)>;
void DeleteLinuxProfileData(std::string_view id, LinuxProfileDataDeleted done);
void SetLinuxProfileLoadedListener(base::RepeatingCallback<void(const std::string&)> listener);

}

#endif
