#ifndef RAY_LINUX_AC_LINUX_NOTIFICATIONS_H_
#define RAY_LINUX_AC_LINUX_NOTIFICATIONS_H_

#include <string_view>

#include "base/functional/callback.h"
#include "base/values.h"

class Profile;

namespace raycore {

using LinuxNotificationSink = base::RepeatingCallback<void(int owner, bool clicked, base::Value response)>;

void InitLinuxNotifications(LinuxNotificationSink sink);
bool LinuxNotificationsInvokes(std::string_view method);
void LinuxNotificationsInvoke(std::string_view method, const base::ListValue& args, Profile* profile, int owner,
                              base::OnceCallback<void(bool, base::Value)> done);

}

#endif
