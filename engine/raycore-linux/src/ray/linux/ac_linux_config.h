#ifndef RAY_LINUX_AC_LINUX_CONFIG_H_
#define RAY_LINUX_AC_LINUX_CONFIG_H_

#include <string>
#include <string_view>

#include "ray/linux/ac_linux_automation.h"
#include "base/files/file_path.h"
#include "base/functional/callback.h"
#include "base/values.h"

namespace raycore {

inline constexpr const char* kLinuxConfigCapabilities[] = {"RayConfig.readFile", "RayConfig.watch",
                                                           "RayConfig.writeSchemas"};

void InitLinuxConfig(LinuxModuleSink sink);
bool LinuxConfigInvokes(std::string_view method);
void LinuxConfigInvoke(const std::string& caller, const base::FilePath& user_data_directory, std::string_view method,
                       const base::ListValue& args, base::OnceCallback<void(bool, base::Value)> done);
void LinuxConfigCallerGone(const std::string& caller);

}

#endif
