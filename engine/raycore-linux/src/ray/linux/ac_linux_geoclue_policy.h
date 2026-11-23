#ifndef RAY_LINUX_AC_LINUX_GEOCLUE_POLICY_H_
#define RAY_LINUX_AC_LINUX_GEOCLUE_POLICY_H_

#include <cmath>
#include <map>
#include <optional>
#include <string>
#include <string_view>

namespace ray::linux_geoclue {

inline constexpr char kService[] = "org.freedesktop.GeoClue2";
inline constexpr char kManagerPath[] = "/org/freedesktop/GeoClue2/Manager";
inline constexpr char kManager[] = "org.freedesktop.GeoClue2.Manager";
inline constexpr char kClient[] = "org.freedesktop.GeoClue2.Client";
inline constexpr char kLocation[] = "org.freedesktop.GeoClue2.Location";
inline constexpr char kProperties[] = "org.freedesktop.DBus.Properties";
inline constexpr char kDesktopId[] = "ray";
inline constexpr unsigned kAccuracyExact = 8;
inline constexpr unsigned kAccuracyCity = 4;
inline constexpr int kCallTimeoutMs = 10000;
inline constexpr int kFirstFixSeconds = 10;
inline constexpr int kIdleStopSeconds = 300;
inline constexpr int kRetryUnavailableSeconds = 60;
inline constexpr double kDefaultAccuracyMeters = 1000;

struct Fix {
  double latitude = 0;
  double longitude = 0;
  double accuracy = kDefaultAccuracyMeters;
  std::optional<double> altitude;
  std::optional<double> heading;
  std::optional<double> speed;
  double acquired_seconds = 0;
};

inline bool Usable(double value) {
  return std::isfinite(value) && value > -1e300;
}

inline std::optional<Fix> FixFrom(const std::map<std::string, double>& values) {
  const auto value = [&values](const char* name) -> std::optional<double> {
    const auto found = values.find(name);
    if (found == values.end() || !Usable(found->second)) return std::nullopt;
    return found->second;
  };
  const std::optional<double> latitude = value("Latitude");
  const std::optional<double> longitude = value("Longitude");
  if (!latitude || !longitude || std::abs(*latitude) > 90 || std::abs(*longitude) > 180) {
    return std::nullopt;
  }
  Fix fix;
  fix.latitude = *latitude;
  fix.longitude = *longitude;
  if (const auto accuracy = value("Accuracy"); accuracy && *accuracy >= 0) fix.accuracy = *accuracy;
  fix.altitude = value("Altitude");
  if (const auto heading = value("Heading"); heading && *heading >= 0 && *heading <= 360) fix.heading = heading;
  if (const auto speed = value("Speed"); speed && *speed >= 0) fix.speed = speed;
  return fix;
}

inline unsigned AccuracyLevel(bool high_accuracy) {
  return high_accuracy ? kAccuracyExact : kAccuracyCity;
}

enum class Retune { kNothing, kRemember, kRequestAndRestart, kRequestAndRestartWhenStarted };

inline Retune RetuneFor(bool active, bool requested_high, bool wanted_high, bool have_client, bool running) {
  if (!active || requested_high == wanted_high) return Retune::kNothing;
  if (!have_client) return Retune::kRemember;
  return running ? Retune::kRequestAndRestart : Retune::kRequestAndRestartWhenStarted;
}

inline bool DeniedByDesktop(std::string_view reason) {
  return reason.find("AccessDenied") != std::string_view::npos ||
         reason.find("not allowed") != std::string_view::npos ||
         reason.find("disabled") != std::string_view::npos;
}

}

#endif
