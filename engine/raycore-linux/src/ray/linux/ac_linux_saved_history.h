#ifndef RAY_LINUX_AC_LINUX_SAVED_HISTORY_H_
#define RAY_LINUX_AC_LINUX_SAVED_HISTORY_H_

#include <cstddef>
#include <optional>
#include <string>
#include <string_view>

namespace raycore::linux_saved_history {

inline constexpr char kTabHistoryDir[] = "Ray Tab History";
inline constexpr char kTabHistoryMarker[] = "Ray Tab History Cleared";
inline constexpr char kReadArg[] = "savedHistoryRead";
inline constexpr size_t kMaxSavedHistoryBytes = 32 * 1024 * 1024;

struct SavedHistoryRequest {
  bool off_the_record = false;
  bool temporary = false;
  bool user_initiated = false;
  bool already_read = false;
  std::string key;
  std::string adoption;
  std::string url;
};

struct SavedTabHistory {
  std::optional<int> version;
  std::string url;
  std::string virtual_url;
  std::optional<std::string> generation;
  std::string state;
};

bool ReadsSavedHistory(const SavedHistoryRequest& request);
std::string SavedHistoryFileName(std::string_view key);
bool SamePage(std::string_view a, std::string_view b);
std::optional<std::string> MarkerGeneration(bool marker_exists, const std::optional<std::string>& marker);
std::optional<std::string> RestorableState(const std::optional<SavedTabHistory>& saved, size_t bytes,
                                           std::string_view url, const std::optional<std::string>& generation);

}

#endif
