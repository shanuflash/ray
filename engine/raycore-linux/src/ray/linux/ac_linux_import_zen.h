#ifndef RAY_LINUX_AC_LINUX_IMPORT_ZEN_H_
#define RAY_LINUX_AC_LINUX_IMPORT_ZEN_H_

#include <map>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "ray/linux/ac_linux_import_readers.h"
#include "ray/linux/ac_linux_import_storage.h"
#include "base/values.h"

namespace ray::linux_import {

inline constexpr size_t kMaxZenSpaceIds = 256;
inline constexpr size_t kMaxZenSpaceIdBytes = 256;

struct ZenNode {
  bool folder = false;
  std::string title;
  std::string url;
  std::optional<std::string> page_title;
  std::vector<ZenNode> children;
};

struct ZenTab {
  std::string url;
  std::string title;
  std::optional<std::string> custom_title;
  std::optional<int> container;
  std::optional<double> last_active;
};

struct ZenSpace {
  std::string id;
  std::string name;
  std::vector<std::string> colors;
  std::optional<std::string> emoji;
  std::optional<int> container;
  std::vector<ZenNode> pinned;
  std::vector<ZenTab> tabs;
};

struct ZenFavicon {
  std::string page;
  std::string icon;
  std::string png;
};

struct ZenSidebar {
  std::vector<ZenSpace> spaces;
  std::vector<ZenTab> essentials;
  std::vector<ZenFavicon> favicons;
  bool separate_essentials = true;
};

struct ZenSpaceDefinition {
  std::string id;
  std::optional<std::string> name;
  std::vector<std::string> colors;
  std::optional<std::string> emoji;
  std::optional<int> container;
};

std::optional<Failure> ParseZenSession(std::string_view json, const std::vector<ZenSpaceDefinition>& stored,
                                       ZenSidebar* out);
std::optional<Failure> LoadZenSidebar(const std::string& profile, ScratchDirectory& scratch,
                                      const ImportObserver& observer, ZenSidebar* out);
std::vector<std::string> ZenSessionFiles(const std::string& profile);
bool ZenSeparateEssentials(std::string_view prefs);
std::map<int, std::string> ZenContainerNames(const std::string& profile);
std::optional<std::string> ZenEmoji(std::string_view icon);

int ZenLinkCount(const std::vector<ZenNode>& nodes);
std::vector<const ZenSpace*> SelectZenSpaces(const ZenSidebar& sidebar,
                                             const std::optional<std::vector<std::string>>& space_ids);
base::ListValue ZenSpaceSummaries(const ZenSidebar& sidebar, const std::map<int, std::string>& containers);
base::ListValue ZenSpaceSuggestions(const std::vector<const ZenSpace*>& spaces, std::string_view profile_id,
                                    bool pinned, bool tabs);
base::ListValue ZenOpenTabs(const std::vector<const ZenSpace*>& spaces);
base::ListValue ZenEssentials(const ZenSidebar& sidebar);
base::ListValue ZenSessionFavicons(const ZenSidebar& sidebar, const std::vector<std::string>& pages);

bool RequestedSpaceIds(const base::Value* given, std::optional<std::vector<std::string>>* out);

}

#endif
