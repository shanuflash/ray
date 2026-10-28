#ifndef RAY_CORE_AC_LAUNCH_SWITCHES_H_
#define RAY_CORE_AC_LAUNCH_SWITCHES_H_

#include <optional>
#include <string>
#include <string_view>

namespace base {
class CommandLine;
}

namespace raycore {

inline constexpr char kBackgroundSwitch[] = "ray-background";
inline constexpr char kDataDirSwitch[] = "ray-data-dir";
inline constexpr char kTestSwitch[] = "ray-test";
inline constexpr char kTraceSwitch[] = "ray-trace";
inline constexpr char kSwitchesSwitch[] = "ray-switches";

bool BackgroundInstance();

std::optional<std::string> InstanceValue(std::string_view key);

bool SignedForDistribution();

bool TestInstance();

std::optional<std::string> TestValue(std::string_view key);

bool TestFlag(std::string_view key);

bool Traced(std::string_view area);

std::optional<bool> SwitchOverride(std::string_view name);

bool SwitchOn(std::string_view name);

bool ExperimentOn(std::string_view name);

void PassSwitchesToGpuProcess(base::CommandLine* gpu_command_line);

void DecideTestGateAtStartup();

}

#endif
