#ifndef RAY_LINUX_AC_LINUX_CRASH_DUMPS_CORE_H_
#define RAY_LINUX_AC_LINUX_CRASH_DUMPS_CORE_H_

#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace ray::linux_crash {

inline constexpr char kCapability[] = "crash.dumps";
inline constexpr char kListCall[] = "RayCrash.list";
inline constexpr char kReadCall[] = "RayCrash.read";
inline constexpr const char* kCrashCapabilities[] = {"crash.dumps"};
inline constexpr size_t kListMost = 32;
inline constexpr size_t kReadMaxBytes = 8 * 1024 * 1024;
inline constexpr char kVersionKey[] = "ray-ver";
inline constexpr size_t kVersionMaxBytes = 32;

struct Dump {
  std::string id;
  double time = 0;
};

bool IsReportId(std::string_view id);
std::optional<double> ListSince(size_t count, std::optional<double> first);
std::vector<Dump> Newest(std::vector<Dump> dumps, double since);
std::optional<std::string> AnnotatedVersion(std::string_view version);

}

#endif
