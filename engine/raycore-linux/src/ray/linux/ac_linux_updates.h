#ifndef RAY_LINUX_AC_LINUX_UPDATES_H_
#define RAY_LINUX_AC_LINUX_UPDATES_H_

#include <optional>
#include <string>

#include "ray/linux/ac_linux_self_update_policy.h"
#include "ray/linux/ac_linux_updates_policy.h"
#include "base/functional/callback.h"

namespace ray::linux_updates {

using FetchReply = base::OnceCallback<void(int status, std::string body)>;

void Fetch(linux_updates_policy::Source source, FetchReply reply);

const std::optional<linux_self_update_policy::Feed>& UpdateFeed();

}

#endif
