#ifndef RAY_LINUX_AC_LINUX_GEOCLUE_H_
#define RAY_LINUX_AC_LINUX_GEOCLUE_H_

#include <memory>
#include <string>

namespace device {
class LocationProvider;
}

namespace ray {

std::unique_ptr<device::LocationProvider> CreateLinuxLocationProvider();
void InstallLinuxLocationProvider();
std::string LinuxLocationPermission();

}

#endif
