#ifndef RAY_LINUX_AC_LINUX_LAUNCH_CONFIG_H_
#define RAY_LINUX_AC_LINUX_LAUNCH_CONFIG_H_

#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "base/files/file_path.h"
#include "base/values.h"

namespace raycore {

struct LinuxPackageInfo {
  LinuxPackageInfo();
  LinuxPackageInfo(const LinuxPackageInfo&);
  ~LinuxPackageInfo();
  base::FilePath directory;
  std::optional<std::string> version;
};

struct LinuxCliEnvironment {
  LinuxCliEnvironment();
  LinuxCliEnvironment(const LinuxCliEnvironment&);
  ~LinuxCliEnvironment();
  std::optional<std::string> home;
  std::optional<std::string> bin_dir;
  std::optional<std::string> url;
  std::optional<std::string> default_home;
  bool isolated = false;
};

struct LinuxDesktopEnvironment {
  LinuxDesktopEnvironment();
  LinuxDesktopEnvironment(const LinuxDesktopEnvironment&);
  ~LinuxDesktopEnvironment();
  std::optional<std::string> autostart_directory;
  std::vector<std::string> application_directories;
  std::vector<std::string> search_path;
};

void InitializeLinuxLaunchConfig();

std::optional<std::string> WellFormedLinuxVersion(std::string_view text);

const LinuxPackageInfo& LinuxPackage();

const LinuxCliEnvironment& LinuxCli();

const LinuxDesktopEnvironment& LinuxDesktop();

base::FilePath LinuxConfigFolder(const base::FilePath& user_data_directory);

base::DictValue LinuxLaunchConfig(const base::FilePath& data_directory,
                                 const base::FilePath& user_data_directory);

}

#endif
