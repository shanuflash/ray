#ifndef RAY_LINUX_AC_LINUX_LAUNCH_URLS_H_
#define RAY_LINUX_AC_LINUX_LAUNCH_URLS_H_

#include <string>
#include <vector>

#include "base/command_line.h"
#include "base/functional/callback.h"

class GURL;

namespace ray {

struct LinuxOpenUrlsSink {
  LinuxOpenUrlsSink();
  LinuxOpenUrlsSink(LinuxOpenUrlsSink&&);
  LinuxOpenUrlsSink& operator=(LinuxOpenUrlsSink&&);
  ~LinuxOpenUrlsSink();
  base::RepeatingCallback<bool()> has_window;
  base::RepeatingClosure arrived;
};

void SetLinuxOpenUrlsSink(LinuxOpenUrlsSink sink);
bool TakeLinuxLaunchUrls(const base::CommandLine& command_line, const std::vector<GURL>& urls, bool process_startup);
base::CommandLine LinuxLaunchWithoutUrls(const base::CommandLine& command_line);
bool LinuxOpenUrlsPending();
std::vector<std::string> TakeLinuxOpenUrls();

}

#endif
