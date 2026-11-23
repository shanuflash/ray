#include "ray/linux/ac_linux_launch_urls.h"

#include <utility>

#include "ray/core/ac_launch_switches.h"
#include "ray/linux/ac_linux_open_urls.h"
#include "base/command_line.h"
#include "base/files/file_path.h"
#include "base/logging.h"
#include "base/no_destructor.h"
#include "url/gurl.h"

namespace ray {

namespace {

linux_open_urls::Inbox& Pending() {
  static base::NoDestructor<linux_open_urls::Inbox> inbox;
  return *inbox;
}

LinuxOpenUrlsSink& Sink() {
  static base::NoDestructor<LinuxOpenUrlsSink> sink;
  return *sink;
}

}

LinuxOpenUrlsSink::LinuxOpenUrlsSink() = default;
LinuxOpenUrlsSink::LinuxOpenUrlsSink(LinuxOpenUrlsSink&&) = default;
LinuxOpenUrlsSink& LinuxOpenUrlsSink::operator=(LinuxOpenUrlsSink&&) = default;
LinuxOpenUrlsSink::~LinuxOpenUrlsSink() = default;

void SetLinuxOpenUrlsSink(LinuxOpenUrlsSink sink) {
  Sink() = std::move(sink);
}

bool TakeLinuxLaunchUrls(const base::CommandLine& command_line, const std::vector<GURL>& urls, bool process_startup) {
  linux_open_urls::Launch launch;
  launch.background = raycore::BackgroundInstance();
  launch.process_startup = process_startup;
  launch.has_window = !process_startup && Sink().has_window && Sink().has_window.Run();
  for (const auto& [name, value] : command_line.GetSwitches()) launch.switches.push_back(name);
  for (const GURL& url : urls) {
    if (!url.is_valid()) return false;
    launch.urls.push_back(url.spec());
  }
  if (!linux_open_urls::ShellTakesLaunch(launch)) return false;
  if (Pending().Add(launch.urls) != launch.urls.size()) {
    LOG(WARNING) << "Ray dropped links from another app: too many are waiting for a window";
  }
  if (Sink().arrived) Sink().arrived.Run();
  return true;
}

base::CommandLine LinuxLaunchWithoutUrls(const base::CommandLine& command_line) {
  base::CommandLine launch(command_line.GetProgram());
  for (const auto& [name, value] : command_line.GetSwitches()) launch.AppendSwitchNative(name, value);
  return launch;
}

bool LinuxOpenUrlsPending() {
  return !Pending().empty();
}

std::vector<std::string> TakeLinuxOpenUrls() {
  return Pending().Take();
}

}
