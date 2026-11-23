#ifndef RAY_LINUX_AC_LINUX_SELF_UPDATE_POLICY_H_
#define RAY_LINUX_AC_LINUX_SELF_UPDATE_POLICY_H_

#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <string_view>

namespace ray::linux_self_update_policy {

inline constexpr const char* kSelfUpdateCapabilities[] = {"RayUpdates.installKind", "RayUpdates.update",
                                                          "RayUpdates.status", "RayUpdates.claimOutcome",
                                                          "RayUpdates.restart"};

inline constexpr std::string_view kReleaseDownloads = "https://github.com/ray-browser/ray/releases/download/";
inline constexpr std::string_view kRedirectHosts[] = {"github.com", "objects.githubusercontent.com",
                                                      "release-assets.githubusercontent.com"};
inline constexpr std::string_view kFeedPrefix = "http://127.0.0.1:";
inline constexpr std::string_view kHelperName = "ray-update";
inline constexpr std::string_view kUpdatesFolder = "Updates";
inline constexpr std::string_view kManifestHeader = "ray-linux-update 1";
inline constexpr std::string_view kNoHelper = "unsupported noHelper";
inline constexpr std::string_view kHelperFailed = "unsupported helperFailed";
inline constexpr std::string_view kHelperSearchPath = "/usr/sbin:/usr/bin:/sbin:/bin";
inline constexpr std::string_view kPkexecPaths[] = {"/usr/bin/pkexec", "/bin/pkexec"};

inline constexpr size_t kMaxManifestBytes = 4096;
inline constexpr size_t kSignatureBytes = 64;
inline constexpr uint64_t kMaxPackageBytes = 512ull * 1024 * 1024;
inline constexpr uint64_t kDiskHeadroomBytes = 64ull * 1024 * 1024;
inline constexpr size_t kMaxVersionLength = 64;
inline constexpr size_t kMaxKindLineLength = 64;
inline constexpr int kSmallFileTimeoutSeconds = 30;
inline constexpr int kPackageTimeoutSeconds = 60 * 60;
inline constexpr int kKindDeadlineSeconds = 10;
inline constexpr int kInstallDeadlineSeconds = 10 * 60;

inline constexpr std::string_view kVersionReason = "version";
inline constexpr std::string_view kKindReason = "kind";
inline constexpr std::string_view kNetworkReason = "network";
inline constexpr std::string_view kManifestReason = "manifest";
inline constexpr std::string_view kTooLargeReason = "tooLarge";
inline constexpr std::string_view kBusyReason = "busy";
inline constexpr std::string_view kDiskReason = "disk";
inline constexpr std::string_view kMissingReason = "missing";
inline constexpr std::string_view kPolkitReason = "polkit";
inline constexpr std::string_view kTimeoutReason = "timeout";
inline constexpr std::string_view kInstallReason = "install";
inline constexpr std::string_view kHelperReasons[] = {"usage", "missing", "manifest", "signature", "notNewer",
                                                      "kind",  "checksum", "install", "busy",     "timeout"};
inline constexpr std::string_view kDiscardingReasons[] = {"signature", "checksum", "manifest", "notNewer"};

enum class Kind { kDeb, kTarball, kAppImage };

inline bool IsDigit(char c) {
  return c >= '0' && c <= '9';
}

inline bool AllDigits(std::string_view text) {
  if (text.empty()) return false;
  for (const char c : text) {
    if (!IsDigit(c)) return false;
  }
  return true;
}

inline bool ValidVersion(std::string_view version) {
  if (version.empty() || version.size() > kMaxVersionLength) return false;
  std::string_view rest = version;
  for (int part = 0; part < 3; ++part) {
    size_t digits = 0;
    while (digits < rest.size() && IsDigit(rest[digits])) ++digits;
    if (digits == 0) return false;
    rest.remove_prefix(digits);
    if (part == 2) break;
    if (rest.empty() || rest.front() != '.') return false;
    rest.remove_prefix(1);
  }
  if (rest.empty()) return true;
  constexpr std::string_view kNightly = "-nightly.";
  if (rest.substr(0, kNightly.size()) != kNightly) return false;
  return AllDigits(rest.substr(kNightly.size()));
}

inline std::optional<Kind> InstallableKind(std::string_view kind) {
  if (kind == "deb") return Kind::kDeb;
  if (kind == "tarball") return Kind::kTarball;
  if (kind == "appimage") return Kind::kAppImage;
  return std::nullopt;
}

inline std::string_view KindName(Kind kind) {
  switch (kind) {
    case Kind::kDeb: return "deb";
    case Kind::kTarball: return "tarball";
    case Kind::kAppImage: return "appimage";
  }
  return "";
}

inline std::string_view PackageSuffix(Kind kind) {
  switch (kind) {
    case Kind::kDeb: return ".deb";
    case Kind::kTarball: return ".tar.xz";
    case Kind::kAppImage: return ".AppImage";
  }
  return "";
}

inline bool ThroughPkexec(Kind kind) {
  return kind != Kind::kAppImage;
}

inline bool ValidKindLine(std::string_view line) {
  if (line.size() > kMaxKindLineLength) return false;
  if (InstallableKind(line) || line == "managed") return true;
  constexpr std::string_view kUnsupported = "unsupported ";
  if (line.substr(0, kUnsupported.size()) != kUnsupported) return false;
  const std::string_view reason = line.substr(kUnsupported.size());
  if (reason.empty()) return false;
  for (const char c : reason) {
    if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || IsDigit(c))) return false;
  }
  return true;
}

inline std::string_view LastLine(std::string_view output) {
  while (!output.empty() && (output.back() == '\n' || output.back() == '\r')) output.remove_suffix(1);
  const size_t newline = output.rfind('\n');
  std::string_view line = newline == std::string_view::npos ? output : output.substr(newline + 1);
  if (!line.empty() && line.back() == '\r') line.remove_suffix(1);
  return line;
}

inline std::string ManifestName(std::string_view version) {
  return "Ray-" + std::string(version) + "-linux-update.txt";
}

inline std::string SignatureName(std::string_view version) {
  return ManifestName(version) + ".sig";
}

inline std::string PackageName(std::string_view version, Kind kind) {
  return "Ray-" + std::string(version) + "-linux-x64" + std::string(PackageSuffix(kind));
}

inline bool ValidPackageName(std::string_view name, std::string_view version, Kind kind) {
  return ValidVersion(version) && name == PackageName(version, kind);
}

struct Package {
  std::string name;
  uint64_t size = 0;
};

struct ManifestRead {
  std::optional<Package> package;
  std::string_view reason;
};

inline std::optional<uint64_t> PackageSize(std::string_view text) {
  if (!AllDigits(text) || text.size() > 19 || (text.size() > 1 && text.front() == '0')) return std::nullopt;
  uint64_t size = 0;
  for (const char c : text) size = size * 10 + static_cast<uint64_t>(c - '0');
  if (size == 0) return std::nullopt;
  return size;
}

inline bool Sha256Hex(std::string_view text) {
  if (text.size() != 64) return false;
  for (const char c : text) {
    if (!(IsDigit(c) || (c >= 'a' && c <= 'f'))) return false;
  }
  return true;
}

inline ManifestRead PackageInManifest(std::string_view manifest, std::string_view version, Kind kind) {
  if (manifest.size() > kMaxManifestBytes) return {std::nullopt, kTooLargeReason};
  if (!ValidVersion(version) || manifest.empty() || manifest.back() != '\n') return {std::nullopt, kManifestReason};
  if (manifest.find('\r') != std::string_view::npos || manifest.find('\0') != std::string_view::npos) {
    return {std::nullopt, kManifestReason};
  }
  std::string_view rest = manifest;
  const auto next_line = [&rest]() {
    const size_t newline = rest.find('\n');
    const std::string_view line = rest.substr(0, newline);
    rest.remove_prefix(newline + 1);
    return line;
  };
  if (next_line() != kManifestHeader) return {std::nullopt, kManifestReason};
  if (rest.empty() || next_line() != "version " + std::string(version)) return {std::nullopt, kManifestReason};
  std::optional<Package> found;
  int last_kind = -1;
  while (!rest.empty()) {
    std::string_view line = next_line();
    std::string_view fields[4];
    for (int index = 0; index < 4; ++index) {
      const size_t space = line.find(' ');
      if (index < 3 && space == std::string_view::npos) return {std::nullopt, kManifestReason};
      if (index == 3 && space != std::string_view::npos) return {std::nullopt, kManifestReason};
      fields[index] = line.substr(0, space);
      line = index < 3 ? line.substr(space + 1) : std::string_view();
    }
    const std::optional<Kind> line_kind = InstallableKind(fields[0]);
    if (!line_kind || static_cast<int>(*line_kind) <= last_kind) return {std::nullopt, kManifestReason};
    last_kind = static_cast<int>(*line_kind);
    if (!ValidPackageName(fields[1], version, *line_kind) || !Sha256Hex(fields[2])) {
      return {std::nullopt, kManifestReason};
    }
    const std::optional<uint64_t> size = PackageSize(fields[3]);
    if (!size) return {std::nullopt, kManifestReason};
    if (*line_kind == kind) found = Package{std::string(fields[1]), *size};
  }
  if (!found) return {std::nullopt, kKindReason};
  if (found->size > kMaxPackageBytes) return {std::nullopt, kTooLargeReason};
  return {std::move(found), ""};
}

inline int CompareNumbers(std::string_view a, std::string_view b) {
  while (a.size() > 1 && a.front() == '0') a.remove_prefix(1);
  while (b.size() > 1 && b.front() == '0') b.remove_prefix(1);
  if (a.size() != b.size()) return a.size() < b.size() ? -1 : 1;
  return a < b ? -1 : (a > b ? 1 : 0);
}

struct VersionParts {
  std::string_view numbers[3];
  std::optional<std::string_view> nightly;
};

inline std::optional<VersionParts> SplitVersion(std::string_view version) {
  if (!ValidVersion(version)) return std::nullopt;
  VersionParts parts;
  const size_t dash = version.find('-');
  std::string_view core = version.substr(0, dash);
  for (int index = 0; index < 3; ++index) {
    const size_t dot = core.find('.');
    parts.numbers[index] = core.substr(0, dot);
    core = dot == std::string_view::npos ? std::string_view() : core.substr(dot + 1);
  }
  if (dash != std::string_view::npos) parts.nightly = version.substr(version.rfind('.') + 1);
  return parts;
}

inline std::optional<int> CompareVersions(std::string_view a, std::string_view b) {
  const std::optional<VersionParts> left = SplitVersion(a);
  const std::optional<VersionParts> right = SplitVersion(b);
  if (!left || !right) return std::nullopt;
  for (int index = 0; index < 3; ++index) {
    if (const int order = CompareNumbers(left->numbers[index], right->numbers[index])) return order;
  }
  if (left->nightly && right->nightly) return CompareNumbers(*left->nightly, *right->nightly);
  if (left->nightly) return -1;
  if (right->nightly) return 1;
  return 0;
}

inline bool DiscardsDownload(std::string_view reason) {
  for (const std::string_view discarding : kDiscardingReasons) {
    if (reason == discarding) return true;
  }
  return false;
}

enum class Phase { kIdle, kDownloading, kInstalling, kReady, kFailed };

inline std::string_view PhaseName(Phase phase) {
  switch (phase) {
    case Phase::kIdle: return "idle";
    case Phase::kDownloading: return "downloading";
    case Phase::kInstalling: return "installing";
    case Phase::kReady: return "ready";
    case Phase::kFailed: return "failed";
  }
  return "";
}

struct UpdateState {
  Phase phase = Phase::kIdle;
  std::string version;
  std::string reason;
  int run = 0;
  bool claimed = false;
};

inline bool Busy(const UpdateState& state) {
  return state.phase == Phase::kDownloading || state.phase == Phase::kInstalling;
}

inline bool BeginRun(UpdateState& state, std::string_view version) {
  if (Busy(state) || state.phase == Phase::kReady) return false;
  if (!ValidVersion(version)) {
    state = UpdateState{Phase::kFailed, "", std::string(kVersionReason), state.run + 1, false};
    return false;
  }
  state = UpdateState{Phase::kDownloading, std::string(version), "", state.run + 1, false};
  return true;
}

inline void Downloaded(UpdateState& state, int run) {
  if (state.run == run && state.phase == Phase::kDownloading) state.phase = Phase::kInstalling;
}

inline void Finished(UpdateState& state, int run, bool ok, std::string_view reason) {
  if (state.run != run || !Busy(state)) return;
  state.phase = ok ? Phase::kReady : Phase::kFailed;
  state.reason = ok ? "" : std::string(reason);
}

inline bool ClaimOutcome(UpdateState& state, int run) {
  if (run <= 0 || run != state.run || state.claimed) return false;
  if (state.phase != Phase::kReady && state.phase != Phase::kFailed) return false;
  state.claimed = true;
  return true;
}

struct Feed {
  std::string base;
  int port = 0;
};

inline std::optional<Feed> FeedOverride(std::string_view value) {
  if (value.substr(0, kFeedPrefix.size()) != kFeedPrefix || value.size() < kFeedPrefix.size() + 2) return std::nullopt;
  if (value.back() != '/') return std::nullopt;
  const std::string_view port_text = value.substr(kFeedPrefix.size(), value.size() - kFeedPrefix.size() - 1);
  if (!AllDigits(port_text) || port_text.size() > 5 || port_text.front() == '0') return std::nullopt;
  int port = 0;
  for (const char c : port_text) port = port * 10 + (c - '0');
  if (port < 1 || port > 65535) return std::nullopt;
  return Feed{std::string(value), port};
}

inline std::string ReleasesUrl(const Feed& feed) {
  return feed.base + "releases.json";
}

inline std::string DownloadUrl(std::string_view version, std::string_view name, const std::optional<Feed>& feed) {
  const std::string base = feed ? feed->base : std::string(kReleaseDownloads);
  return base + "v" + std::string(version) + "/" + std::string(name);
}

inline bool AllowedRedirect(std::string_view scheme, std::string_view host, int port,
                            const std::optional<Feed>& feed) {
  if (scheme == "https" && port == 443) {
    for (const std::string_view allowed : kRedirectHosts) {
      if (host == allowed) return true;
    }
  }
  return feed && scheme == "http" && host == "127.0.0.1" && port == feed->port;
}

struct InstallOutcome {
  bool ok = false;
  std::string detail;
};

inline InstallOutcome InstallOutcomeFor(std::string_view version, bool timed_out, int exit_code,
                                        std::string_view last_line, bool through_pkexec) {
  if (timed_out) return {false, std::string(kTimeoutReason)};
  if (exit_code == 0 && last_line == "installed " + std::string(version)) return {true, std::string(version)};
  constexpr std::string_view kFailed = "failed ";
  if (last_line.substr(0, kFailed.size()) == kFailed) {
    const std::string_view reason = last_line.substr(kFailed.size());
    for (const std::string_view known : kHelperReasons) {
      if (reason == known) return {false, std::string(reason)};
    }
  }
  if (through_pkexec && (exit_code == 126 || exit_code == 127)) return {false, std::string(kPolkitReason)};
  return {false, std::string(kInstallReason)};
}

}

#endif
