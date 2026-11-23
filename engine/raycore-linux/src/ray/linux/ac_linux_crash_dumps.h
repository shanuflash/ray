#ifndef RAY_LINUX_AC_LINUX_CRASH_DUMPS_H_
#define RAY_LINUX_AC_LINUX_CRASH_DUMPS_H_

#include <string_view>

#include "base/functional/callback.h"
#include "base/values.h"

namespace raycore {

bool LinuxCrashInvokes(std::string_view method);
void LinuxCrashInvoke(std::string_view method, const base::ListValue& args,
                      base::OnceCallback<void(bool, base::Value)> done);
void AnnotateLinuxCrashVersion();

}

#endif
