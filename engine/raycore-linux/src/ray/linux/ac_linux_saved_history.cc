#include "ray/linux/ac_linux_saved_history.h"

namespace raycore::linux_saved_history {

namespace {

std::string_view WithoutFragment(std::string_view url) {
  const size_t hash = url.find('#');
  return hash == std::string_view::npos ? url : url.substr(0, hash);
}

std::string_view Trimmed(std::string_view text) {
  constexpr std::string_view kSpace = " \t\r\n\f\v";
  const size_t first = text.find_first_not_of(kSpace);
  if (first == std::string_view::npos) return {};
  return text.substr(first, text.find_last_not_of(kSpace) - first + 1);
}

}

bool ReadsSavedHistory(const SavedHistoryRequest& request) {
  return !request.off_the_record && !request.temporary && !request.user_initiated && !request.already_read &&
         !request.key.empty() && request.adoption.empty() && !request.url.empty() &&
         !request.url.starts_with("about:");
}

std::string SavedHistoryFileName(std::string_view key) {
  constexpr char kDigits[] = "0123456789ABCDEF";
  std::string name;
  name.reserve(key.size() * 2);
  for (const char c : key) {
    const auto byte = static_cast<unsigned char>(c);
    name.push_back(kDigits[byte >> 4]);
    name.push_back(kDigits[byte & 0xF]);
  }
  return name;
}

bool SamePage(std::string_view a, std::string_view b) {
  return !a.empty() && !b.empty() && WithoutFragment(a) == WithoutFragment(b);
}

std::optional<std::string> MarkerGeneration(bool marker_exists, const std::optional<std::string>& marker) {
  if (marker_exists && !marker) return std::nullopt;
  return std::string(Trimmed(marker.value_or(std::string())));
}

std::optional<std::string> RestorableState(const std::optional<SavedTabHistory>& saved, size_t bytes,
                                           std::string_view url, const std::optional<std::string>& generation) {
  if (!saved || bytes == 0 || bytes > kMaxSavedHistoryBytes || saved->version != 1 || saved->state.empty()) {
    return std::nullopt;
  }
  if (!SamePage(saved->url, url) && !SamePage(saved->virtual_url, url)) return std::nullopt;
  if (!generation || !saved->generation || *saved->generation != *generation) return std::nullopt;
  return saved->state;
}

}
