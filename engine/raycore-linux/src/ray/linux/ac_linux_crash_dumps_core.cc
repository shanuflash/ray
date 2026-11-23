#include "ray/linux/ac_linux_crash_dumps_core.h"

#include <algorithm>
#include <cmath>
#include <set>
#include <utility>

namespace ray::linux_crash {

namespace {

bool LowerHex(char c) {
  return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
}

}

bool IsReportId(std::string_view id) {
  if (id.size() != 36) return false;
  for (size_t i = 0; i < id.size(); ++i) {
    const bool dash = i == 8 || i == 13 || i == 18 || i == 23;
    if (dash ? id[i] != '-' : !LowerHex(id[i])) return false;
  }
  return true;
}

std::optional<double> ListSince(size_t count, std::optional<double> first) {
  if (count != 1 || !first) return std::nullopt;
  const double since = *first;
  if (!std::isfinite(since) || since < 0) return std::nullopt;
  return since;
}

std::vector<Dump> Newest(std::vector<Dump> dumps, double since) {
  std::vector<Dump> kept;
  std::set<std::string> seen;
  for (Dump& dump : dumps) {
    if (!IsReportId(dump.id) || !seen.insert(dump.id).second) continue;
    if (!std::isfinite(dump.time) || dump.time <= since) continue;
    kept.push_back(std::move(dump));
  }
  std::stable_sort(kept.begin(), kept.end(), [](const Dump& a, const Dump& b) { return a.time < b.time; });
  if (kept.size() > kListMost) kept.erase(kept.begin(), kept.end() - kListMost);
  return kept;
}

std::optional<std::string> AnnotatedVersion(std::string_view version) {
  if (version.empty() || version.size() > kVersionMaxBytes) return std::nullopt;
  for (const char c : version) {
    const bool allowed = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || c == '.' || c == '-';
    if (!allowed) return std::nullopt;
  }
  return std::string(version);
}

}
