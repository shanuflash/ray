#ifndef RAY_LINUX_AC_LINUX_SELF_UPDATE_H_
#define RAY_LINUX_AC_LINUX_SELF_UPDATE_H_

#include <string_view>

#include "ray/linux/ac_linux_self_update_policy.h"
#include "base/functional/callback.h"
#include "base/values.h"

namespace ray::linux_self_update {

bool Invokes(std::string_view method);

void Invoke(std::string_view method, const base::ListValue& args, base::OnceCallback<void(bool, base::Value)> done);

}

#endif
