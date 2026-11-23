#include "ray/linux/ac_linux_import_zen.h"

#include <algorithm>
#include <array>
#include <cctype>
#include <climits>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <functional>
#include <limits>
#include <memory>
#include <set>
#include <tuple>
#include <utility>

#include "ray/linux/ac_linux_import_crypto.h"
#include "ray/linux/ac_linux_import_formats.h"
#include "ray/linux/ac_linux_import_sessions.h"
#include "base/json/json_reader.h"

namespace ray::linux_import {

namespace {

constexpr size_t kMaxContainersBytes = 4u * 1024 * 1024;
constexpr size_t kMaxPrefsBytes = 8u * 1024 * 1024;
constexpr size_t kMaxSessionIconBytes = 16 * 1024;
constexpr size_t kMaxSessionIconPages = 1000;
constexpr size_t kMaxSessionIconTotal = 6u * 1024 * 1024;
constexpr int kMaxFolderDepth = 32;
constexpr size_t kMaxZenFolders = 2048;
constexpr size_t kMaxStoredWorkspaceRows = 4096;
constexpr size_t kMaxWorkspaceThemeBytes = 64 * 1024;
constexpr std::string_view kPngPrefix = "data:image/png;base64,";
constexpr std::string_view kPngSignature("\x89PNG\r\n\x1a\n", 8);

const std::string* Text(const base::DictValue& dict, std::string_view key) {
  const std::string* text = dict.FindString(key);
  return text && !text->empty() ? text : nullptr;
}

std::optional<std::string> OptionalText(const base::DictValue& dict, std::string_view key) {
  const std::string* text = Text(dict, key);
  return text ? std::optional<std::string>(*text) : std::nullopt;
}

std::vector<const base::DictValue*> Objects(const base::Value* value) {
  std::vector<const base::DictValue*> out;
  if (!value || !value->is_list()) return out;
  for (const base::Value& item : value->GetList()) {
    if (item.is_dict()) out.push_back(&item.GetDict());
  }
  return out;
}

bool IsTrue(const base::DictValue& dict, std::string_view key) {
  return dict.FindBool(key) == true;
}

bool Flag(const base::DictValue& dict, std::string_view key) {
  const std::string* text = dict.FindString(key);
  return IsTrue(dict, key) || (text && *text == "true");
}

std::optional<int> Container(const base::Value* value) {
  if (!value) return std::nullopt;
  int64_t id = 0;
  if (value->is_int()) {
    id = value->GetInt();
  } else if (value->is_double()) {
    const double number = value->GetDouble();
    if (!std::isfinite(number) || number < 1 || number > INT_MAX) return std::nullopt;
    id = static_cast<int64_t>(number);
  } else if (value->is_string()) {
    std::string_view text = value->GetString();
    if (!text.empty() && text.front() == '+') text.remove_prefix(1);
    if (text.empty() || !std::all_of(text.begin(), text.end(), [](char c) { return c >= '0' && c <= '9'; }) ||
        !ParseInt64(text, &id)) {
      return std::nullopt;
    }
  } else {
    return std::nullopt;
  }
  return id > 0 && id <= INT_MAX ? std::optional<int>(static_cast<int>(id)) : std::nullopt;
}

std::vector<uint32_t> CodePoints(std::string_view text) {
  std::vector<uint32_t> out;
  size_t i = 0;
  while (i < text.size()) {
    const uint8_t lead = static_cast<uint8_t>(text[i]);
    const int extra = lead < 0x80 ? 0 : (lead >> 5) == 0x6 ? 1 : (lead >> 4) == 0xe ? 2 : (lead >> 3) == 0x1e ? 3 : -1;
    if (extra < 0 || i + static_cast<size_t>(extra) >= text.size()) {
      out.push_back(0xfffd);
      ++i;
      continue;
    }
    uint32_t code = extra == 0 ? lead : lead & (0x3f >> extra);
    bool valid = true;
    for (int k = 1; k <= extra; ++k) {
      const uint8_t next = static_cast<uint8_t>(text[i + static_cast<size_t>(k)]);
      if ((next & 0xc0) != 0x80) {
        valid = false;
        break;
      }
      code = (code << 6) | (next & 0x3f);
    }
    if (!valid) {
      out.push_back(0xfffd);
      ++i;
      continue;
    }
    out.push_back(code);
    i += static_cast<size_t>(extra) + 1;
  }
  return out;
}

bool EmojiScalar(uint32_t code) {
  constexpr std::array<std::pair<uint32_t, uint32_t>, 16> kRanges = {{
      {0xa9, 0xa9},     {0xae, 0xae},     {0x203c, 0x203c}, {0x2049, 0x2049}, {0x2122, 0x2122}, {0x2139, 0x2139},
      {0x2194, 0x21aa}, {0x231a, 0x23ff}, {0x24c2, 0x24c2}, {0x25aa, 0x27bf}, {0x2934, 0x2935}, {0x2b05, 0x2b55},
      {0x3030, 0x3030}, {0x303d, 0x303d}, {0x3297, 0x3299}, {0x1f000, 0x1faff},
  }};
  if (code <= 0x7f) return false;
  return std::any_of(kRanges.begin(), kRanges.end(),
                     [code](const auto& range) { return code >= range.first && code <= range.second; });
}

bool JoinsPrevious(uint32_t code) {
  return code == 0x200d || code == 0xfe0e || code == 0xfe0f || code == 0x20e3 || (code >= 0x1f3fb && code <= 0x1f3ff) ||
         (code >= 0xe0020 && code <= 0xe007f);
}

bool Regional(uint32_t code) {
  return code >= 0x1f1e6 && code <= 0x1f1ff;
}

size_t ClusterCount(const std::vector<uint32_t>& codes) {
  size_t count = 0;
  std::optional<uint32_t> previous;
  bool paired_regional = false;
  for (const uint32_t code : codes) {
    const bool joined = previous && (JoinsPrevious(code) || *previous == 0x200d ||
                                     (Regional(code) && Regional(*previous) && !paired_regional));
    paired_regional = joined && Regional(code);
    if (!joined) ++count;
    previous = code;
  }
  return count;
}

int ColorByte(double value) {
  return static_cast<int>(std::lround(std::clamp(value, 0.0, 1.0) * 255));
}

std::vector<std::string> Gradient(const base::Value* stops_value) {
  std::vector<const base::DictValue*> stops = Objects(stops_value);
  std::stable_partition(stops.begin(), stops.end(), [](const base::DictValue* stop) { return IsTrue(*stop, "isPrimary"); });
  std::vector<std::string> colors;
  for (const base::DictValue* stop : stops) {
    const base::Value* c = stop->Find("c");
    if (!c) continue;
    if (c->is_list()) {
      const base::ListValue& channels = c->GetList();
      if (channels.size() < 3 ||
          !std::all_of(channels.begin(), channels.end(), [](const base::Value& v) { return v.is_int() || v.is_double(); })) {
        continue;
      }
      char buffer[8];
      std::snprintf(buffer, sizeof(buffer), "#%02X%02X%02X", ColorByte(channels[0].GetDouble() / 255),
                    ColorByte(channels[1].GetDouble() / 255), ColorByte(channels[2].GetDouble() / 255));
      colors.push_back(buffer);
    } else if (c->is_string()) {
      std::string css = c->GetString();
      if (css.size() != 7 || css[0] != '#' ||
          !std::all_of(css.begin() + 1, css.end(), [](char ch) { return std::isxdigit(static_cast<unsigned char>(ch)); })) {
        continue;
      }
      std::transform(css.begin(), css.end(), css.begin(), [](char ch) { return static_cast<char>(std::toupper(static_cast<unsigned char>(ch))); });
      colors.push_back(std::move(css));
    }
  }
  return colors;
}

std::vector<std::string> ThemeGradient(const base::DictValue& space) {
  const base::DictValue* theme = space.FindDict("theme");
  return theme ? Gradient(theme->Find("gradientColors")) : std::vector<std::string>();
}

bool IsWebPage(std::string_view url) {
  auto lower = [](char c) { return static_cast<char>(std::tolower(static_cast<unsigned char>(c))); };
  std::string head(url.substr(0, 6));
  std::transform(head.begin(), head.end(), head.begin(), lower);
  return head.rfind("http:", 0) == 0 || head.rfind("https:", 0) == 0;
}

std::optional<std::string> OriginIcon(std::string_view url) {
  if (!IsWebPage(url)) return std::nullopt;
  const size_t separator = url.find("://");
  if (separator == std::string_view::npos) return std::nullopt;
  const std::string_view scheme = url.substr(0, separator);
  const std::string_view rest = url.substr(separator + 3);
  std::string_view authority = rest.substr(0, rest.find_first_of("/?#"));
  if (const size_t at = authority.rfind('@'); at != std::string_view::npos) authority.remove_prefix(at + 1);
  std::string_view host = authority;
  std::string_view port;
  if (!authority.empty() && authority.front() == '[') {
    const size_t close = authority.find(']');
    if (close == std::string_view::npos) return std::nullopt;
    host = authority.substr(0, close + 1);
    if (close + 1 < authority.size() && authority[close + 1] == ':') port = authority.substr(close + 2);
  } else if (const size_t colon = authority.find(':'); colon != std::string_view::npos) {
    host = authority.substr(0, colon);
    port = authority.substr(colon + 1);
  }
  if (host.empty()) return std::nullopt;
  std::string icon = std::string(scheme) + "://" + std::string(host);
  int64_t number = 0;
  if (!port.empty() && port.size() <= 5 &&
      std::all_of(port.begin(), port.end(), [](char c) { return c >= '0' && c <= '9'; }) && ParseInt64(port, &number)) {
    icon += ":" + std::to_string(number);
  }
  return icon + "/favicon.ico";
}

std::optional<std::string> SessionPng(const base::Value* value) {
  if (!value || !value->is_string()) return std::nullopt;
  const std::string& image = value->GetString();
  if (image.rfind(kPngPrefix, 0) != 0 || image.size() > kPngPrefix.size() + (kMaxSessionIconBytes + 2) / 3 * 4) {
    return std::nullopt;
  }
  const std::string_view encoded = std::string_view(image).substr(kPngPrefix.size());
  if (encoded.size() % 4 != 0 || encoded.find_first_of(" \r\n") != std::string_view::npos) return std::nullopt;
  std::string bytes;
  if (!Base64Decode(encoded, &bytes) || bytes.size() < kPngSignature.size() || bytes.size() > kMaxSessionIconBytes ||
      std::string_view(bytes).substr(0, kPngSignature.size()) != kPngSignature) {
    return std::nullopt;
  }
  return Base64Encode(bytes);
}

const base::DictValue* PageOf(const base::DictValue& tab, bool pinned) {
  const base::DictValue* initial_state = tab.FindDict("_zenPinnedInitialState");
  const base::DictValue* initial = initial_state ? initial_state->FindDict("entry") : nullptr;
  if (pinned && initial && Text(*initial, "url")) return initial;
  const std::vector<const base::DictValue*> entries = Objects(tab.Find("entries"));
  if (entries.empty()) return nullptr;
  const int count = static_cast<int>(entries.size());
  const int index = std::clamp(tab.FindInt("index").value_or(count), 1, count) - 1;
  return entries[static_cast<size_t>(index)];
}

const base::Value* IconOf(const base::DictValue& tab, bool pinned) {
  const base::DictValue* initial_state = pinned ? tab.FindDict("_zenPinnedInitialState") : nullptr;
  const base::Value* image = initial_state ? initial_state->Find("image") : nullptr;
  return image && !image->is_none() ? image : tab.Find("image");
}

std::string WithoutFragment(std::string_view page) {
  return std::string(page.substr(0, page.find('#')));
}

ZenSpaceDefinition DefinitionOf(const base::DictValue& space) {
  ZenSpaceDefinition definition;
  if (const std::string* id = Text(space, "uuid")) definition.id = *id;
  definition.name = OptionalText(space, "name");
  definition.colors = ThemeGradient(space);
  if (const std::string* icon = Text(space, "icon")) definition.emoji = ZenEmoji(*icon);
  definition.container = Container(space.Find("containerTabId"));
  return definition;
}

enum class Previous { kUnknown, kFirst, kAfter };

struct Folder {
  std::string name;
  std::optional<std::string> parent;
  std::optional<std::string> space;
  Previous previous = Previous::kUnknown;
  std::string previous_id;
  bool live = false;
  bool split = false;
};

struct Entry {
  std::optional<std::string> key;
  ZenNode node;
};

class FolderTree {
 public:
  FolderTree(std::map<std::string, Folder> folders, std::vector<std::string> order,
             std::map<std::string, std::vector<Entry>> pins, std::map<std::string, std::string> pin_spaces,
             std::set<std::string> omitted_spaces)
      : folders_(std::move(folders)),
        order_(std::move(order)),
        pins_(std::move(pins)),
        pin_spaces_(std::move(pin_spaces)),
        omitted_spaces_(std::move(omitted_spaces)) {
    for (const std::string& id : order_) {
      if (const std::optional<std::string>& parent = folders_.at(id).parent) children_[*parent].push_back(id);
    }
  }

  const std::vector<std::string>& order() const { return order_; }
  bool Placed(const std::string& id) const { return placed_.contains(id); }

  bool Omitted(const std::string& id) const {
    const std::optional<std::string> space = SpaceOf(id);
    return space && omitted_spaces_.contains(*space);
  }

  std::vector<std::string> Roots() const {
    std::vector<std::string> roots;
    for (const std::string& id : order_) {
      const Folder& folder = folders_.at(id);
      if (!folder.parent || !folders_.contains(*folder.parent)) roots.push_back(id);
    }
    return roots;
  }

  void Insert(std::vector<Entry>& list, std::vector<Entry> added, const std::string& after) const {
    const auto found = folders_.find(after);
    const Previous previous = found == folders_.end() ? Previous::kUnknown : found->second.previous;
    size_t at = list.size();
    if (previous == Previous::kFirst) {
      at = 0;
    } else if (previous == Previous::kAfter) {
      for (size_t i = list.size(); i > 0; --i) {
        if (list[i - 1].key == found->second.previous_id) {
          at = i;
          break;
        }
      }
    }
    list.insert(list.begin() + static_cast<long>(at), std::make_move_iterator(added.begin()),
                std::make_move_iterator(added.end()));
  }

  std::vector<Entry> Build(const std::string& id, int depth, bool* emptied = nullptr) {
    const auto found = folders_.find(id);
    if (found == folders_.end() || found->second.live || !placed_.insert(id).second) return {};
    bool lost_children = false;
    std::vector<Entry> inside = Contents(id, depth, &lost_children);
    if (inside.empty() && lost_children) {
      if (emptied) *emptied = true;
      return {};
    }
    if (found->second.split) return inside;
    ZenNode node;
    node.folder = true;
    node.title = found->second.name;
    for (Entry& entry : inside) node.children.push_back(std::move(entry.node));
    std::vector<Entry> out;
    out.push_back(Entry{id, std::move(node)});
    return out;
  }

  std::optional<std::string> SpaceOf(const std::string& id, int depth = 0) const {
    const auto found = folders_.find(id);
    if (depth >= kMaxFolderDepth || found == folders_.end()) return std::nullopt;
    if (found->second.space) return found->second.space;
    if (const auto pinned = pin_spaces_.find(id); pinned != pin_spaces_.end()) return pinned->second;
    return found->second.parent ? SpaceOf(*found->second.parent, depth + 1) : std::nullopt;
  }

 private:
  std::vector<Entry> Contents(const std::string& id, int depth, bool* lost_children) {
    std::vector<Entry> list;
    if (auto pinned = pins_.find(id); pinned != pins_.end()) list = std::move(pinned->second);
    if (depth >= kMaxFolderDepth) return list;
    const auto children = children_.find(id);
    if (children == children_.end()) return list;
    for (const std::string& child : children->second) {
      if (placed_.contains(child)) continue;
      if (Omitted(child)) {
        placed_.insert(child);
        *lost_children = true;
        continue;
      }
      Insert(list, Build(child, depth + 1, lost_children), child);
    }
    return list;
  }

  std::map<std::string, Folder> folders_;
  std::vector<std::string> order_;
  std::map<std::string, std::vector<std::string>> children_;
  std::map<std::string, std::vector<Entry>> pins_;
  std::map<std::string, std::string> pin_spaces_;
  std::set<std::string> omitted_spaces_;
  std::set<std::string> placed_;
};

size_t SpaceIndex(const std::vector<ZenSpace>& spaces, const std::optional<std::string>& id,
                  std::optional<int> container = std::nullopt) {
  if (id) {
    for (size_t i = 0; i < spaces.size(); ++i) {
      if (spaces[i].id == *id) return i;
    }
  }
  if (container) {
    for (size_t i = 0; i < spaces.size(); ++i) {
      if (spaces[i].container == container) return i;
    }
  }
  return 0;
}

std::vector<ZenSpaceDefinition> PlacesWorkspaces(const std::string& profile, ScratchDirectory& scratch,
                                                 const ImportObserver& observer) {
  const std::string places = Join(profile, "places.sqlite");
  if (!IsFile(places)) return {};
  FileRead status = FileRead::kOk;
  std::unique_ptr<Database> db = Database::Snapshot(places, scratch, observer, &status);
  if (!db || !db->HasTable("zen_workspaces")) return {};
  Statement statement(db->get(), "SELECT * FROM zen_workspaces");
  const int uuid = statement.Column("uuid");
  const int name = statement.Column("name");
  const int icon = statement.Column("icon");
  const int container = statement.Column("container_id");
  const int theme = statement.Column("theme_colors");
  const int position = statement.Column("position");
  const int created = statement.Column("created_at");
  std::vector<std::tuple<int64_t, int64_t, size_t, ZenSpaceDefinition>> rows;
  size_t scanned = 0;
  while (statement.Step() && ++scanned <= kMaxStoredWorkspaceRows) {
    if (statement.IsNull(uuid)) continue;
    ZenSpaceDefinition space;
    space.id = statement.Text(uuid);
    if (space.id.empty() || !ValidUtf8(space.id)) continue;
    if (!statement.IsNull(name) && !statement.Text(name).empty()) space.name = statement.Text(name);
    if (!statement.IsNull(icon)) space.emoji = ZenEmoji(statement.Text(icon));
    if (const int64_t id = statement.Int(container); id > 0 && id <= INT_MAX) space.container = static_cast<int>(id);
    const std::string theme_colors = statement.IsNull(theme) ? std::string() : statement.Text(theme);
    if (!theme_colors.empty() && theme_colors.size() <= kMaxWorkspaceThemeBytes) {
      if (std::optional<base::Value> colors = base::JSONReader::Read(theme_colors, base::JSON_PARSE_RFC)) {
        space.colors = Gradient(&*colors);
      }
    }
    rows.emplace_back(statement.IsNull(position) ? std::numeric_limits<int64_t>::max() : statement.Int(position),
                      statement.IsNull(created) ? 0 : statement.Int(created), rows.size(), std::move(space));
  }
  std::sort(rows.begin(), rows.end(), [](const auto& a, const auto& b) {
    return std::tie(std::get<0>(a), std::get<1>(a), std::get<2>(a)) < std::tie(std::get<0>(b), std::get<1>(b), std::get<2>(b));
  });
  std::vector<ZenSpaceDefinition> out;
  for (auto& row : rows) out.push_back(std::move(std::get<3>(row)));
  return out;
}

std::optional<Failure> ReadSession(const std::string& path, std::string* json) {
  std::string compressed;
  const FileRead read = ReadFileLimited(path, kMaxSessionBytes, &compressed);
  if (read != FileRead::kOk) {
    return Failure{read == FileRead::kTooLarge ? "tooLarge" : "unreadable", "Couldn't read Zen's session store"};
  }
  if (compressed.size() > 12 && compressed.compare(0, 8, std::string_view("mozLz40\0", 8)) == 0) {
    const size_t size = static_cast<uint8_t>(compressed[8]) | (static_cast<size_t>(static_cast<uint8_t>(compressed[9])) << 8) |
                        (static_cast<size_t>(static_cast<uint8_t>(compressed[10])) << 16) |
                        (static_cast<size_t>(static_cast<uint8_t>(compressed[11])) << 24);
    if (size > kMaxJsonBytes) return Failure{"tooLarge", "Zen's session store is too large"};
  }
  if (!DecompressMozLz4(compressed, json)) return Failure{"unreadable", "Couldn't decompress Zen's session store"};
  return std::nullopt;
}

base::DictValue NodeValue(const ZenNode& node) {
  base::DictValue value;
  value.Set("type", node.folder ? "folder" : "url");
  value.Set("title", node.title);
  if (node.folder) {
    base::ListValue children;
    for (const ZenNode& child : node.children) children.Append(NodeValue(child));
    value.Set("children", std::move(children));
  } else {
    value.Set("url", node.url);
    if (node.page_title) value.Set("pageTitle", *node.page_title);
  }
  return value;
}

base::DictValue TabValue(const ZenTab& tab, bool pinned) {
  base::DictValue value;
  value.Set("url", tab.url);
  value.Set("title", tab.title);
  value.Set("pinned", pinned);
  value.Set("windowIndex", 0);
  value.Set("active", false);
  if (tab.custom_title) value.Set("customTitle", *tab.custom_title);
  if (tab.last_active) value.Set("lastActive", *tab.last_active);
  if (tab.container) value.Set("container", *tab.container);
  return value;
}

int LinkCount(const ZenNode& node) {
  if (!node.folder) return 1;
  int count = 0;
  for (const ZenNode& child : node.children) count += LinkCount(child);
  return count;
}

}

std::optional<std::string> ZenEmoji(std::string_view icon) {
  if (icon.empty() || icon.find('/') != std::string_view::npos || icon.find(':') != std::string_view::npos) {
    return std::nullopt;
  }
  const std::vector<uint32_t> codes = CodePoints(icon);
  if (ClusterCount(codes) > 4 || std::none_of(codes.begin(), codes.end(), EmojiScalar)) return std::nullopt;
  return std::string(icon);
}

std::optional<Failure> ParseZenSession(std::string_view json, const std::vector<ZenSpaceDefinition>& stored,
                                       ZenSidebar* out) {
  std::optional<base::DictValue> top = base::JSONReader::ReadDict(json, base::JSON_PARSE_RFC);
  if (!top) return Failure{"unreadable", "Zen's session store is malformed"};
  std::vector<const base::DictValue*> windows;
  if (!top->Find("windows")) {
    windows.push_back(&*top);
  } else {
    for (const base::DictValue* window : Objects(top->Find("windows"))) {
      if (!IsTrue(*window, "isPopup") && !IsTrue(*window, "isTaskbarTab") && !IsTrue(*window, "isPrivate")) {
        windows.push_back(window);
      }
    }
  }

  ZenSidebar sidebar;
  std::vector<ZenSpaceDefinition> declared;
  for (const base::DictValue* window : windows) {
    for (const base::DictValue* space : Objects(window->Find("spaces"))) declared.push_back(DefinitionOf(*space));
  }
  std::set<std::string> space_ids;
  std::set<std::string> omitted_spaces;
  for (const ZenSpaceDefinition& definition : declared.empty() ? stored : declared) {
    if (definition.id.empty() || space_ids.contains(definition.id)) continue;
    if (definition.id.size() > kMaxZenSpaceIdBytes || sidebar.spaces.size() >= kMaxZenSpaceIds) {
      omitted_spaces.insert(definition.id);
      continue;
    }
    space_ids.insert(definition.id);
    ZenSpace space;
    space.id = definition.id;
    space.name = definition.name.value_or("Space " + std::to_string(sidebar.spaces.size() + 1));
    space.colors = definition.colors;
    space.emoji = definition.emoji;
    space.container = definition.container;
    sidebar.spaces.push_back(std::move(space));
  }
  if (sidebar.spaces.empty()) {
    *out = std::move(sidebar);
    return std::nullopt;
  }

  std::set<std::string> listed_ids;
  std::vector<std::pair<std::string, const base::DictValue*>> listed_folders;
  std::map<std::string, std::vector<std::string>> folder_children;
  std::vector<std::string> excluded;
  for (const base::DictValue* window : windows) {
    for (const base::DictValue* f : Objects(window->Find("folders"))) {
      const std::string* id = Text(*f, "id");
      if (!id || !listed_ids.insert(*id).second) continue;
      listed_folders.emplace_back(*id, f);
      if (const std::optional<std::string> parent = OptionalText(*f, "parentId")) folder_children[*parent].push_back(*id);
      if (const std::optional<std::string> space = OptionalText(*f, "workspaceId"); space && omitted_spaces.contains(*space)) {
        excluded.push_back(*id);
      }
    }
  }
  std::set<std::string> omitted_folders(excluded.begin(), excluded.end());
  while (!excluded.empty()) {
    const std::string id = std::move(excluded.back());
    excluded.pop_back();
    const auto children = folder_children.find(id);
    if (children == folder_children.end()) continue;
    for (const std::string& child : children->second) {
      if (omitted_folders.insert(child).second) excluded.push_back(child);
    }
  }

  std::map<std::string, Folder> folders;
  std::vector<std::string> folder_order;
  for (const auto& [id, f] : listed_folders) {
    if (folder_order.size() >= kMaxZenFolders) break;
    if (omitted_folders.contains(id)) continue;
    Folder folder;
    folder.name = OptionalText(*f, "name").value_or("Folder");
    folder.parent = OptionalText(*f, "parentId");
    folder.space = OptionalText(*f, "workspaceId");
    if (const base::DictValue* previous = f->FindDict("prevSiblingInfo")) {
      const std::string* previous_id = Text(*previous, "id");
      folder.previous = previous_id ? Previous::kAfter : Previous::kFirst;
      if (previous_id) folder.previous_id = *previous_id;
    }
    folder.live = IsTrue(*f, "isLiveFolder");
    folder.split = IsTrue(*f, "splitViewGroup");
    folders.emplace(id, std::move(folder));
    folder_order.push_back(id);
  }

  std::set<std::string> seen_tabs;
  std::set<std::string> essential_pages;
  std::map<size_t, std::vector<Entry>> root_pins;
  std::map<std::string, std::vector<Entry>> folder_pins;
  std::map<std::string, std::string> folder_space;
  std::set<std::string> icon_pages;

  size_t taken = 0;
  for (const base::DictValue* window : windows) {
    for (const base::DictValue* tab : Objects(window->Find("tabs"))) {
      if (taken >= kMaxImportedTabs) break;
      if (IsTrue(*tab, "zenIsEmpty") || IsTrue(*tab, "zenIsGlance") || Text(*tab, "zenLiveFolderItemId")) continue;
      std::optional<std::string> sync_id = OptionalText(*tab, "zenSyncId");
      if (!sync_id) sync_id = OptionalText(*tab, "zenPinnedId");
      if (sync_id && !seen_tabs.insert(*sync_id).second) continue;
      const bool essential = Flag(*tab, "zenEssential");
      const bool pinned = essential || IsTrue(*tab, "pinned");
      const base::DictValue* page = PageOf(*tab, pinned);
      const std::string* url = page ? Text(*page, "url") : nullptr;
      if (!url) continue;
      const std::optional<std::string> tab_space = OptionalText(*tab, "zenWorkspace");
      const std::optional<std::string> tab_group = OptionalText(*tab, "groupId");
      if (!essential && tab_space && omitted_spaces.contains(*tab_space)) {
        if (pinned && tab_group && folders.contains(*tab_group) && !folder_space.contains(*tab_group)) {
          folder_space[*tab_group] = *tab_space;
        }
        continue;
      }
      if (pinned && !essential && tab_group && omitted_folders.contains(*tab_group)) continue;
      ++taken;
      const std::string* page_title = page->FindString("title");
      const std::string title = page_title ? *page_title : std::string();
      const std::optional<std::string> label = OptionalText(*tab, "zenStaticLabel");
      const std::optional<std::string> workspace = OptionalText(*tab, "zenWorkspace");
      const std::optional<int> tab_container = Container(tab->Find("userContextId"));
      if (!icon_pages.contains(*url)) {
        std::optional<std::string> png = SessionPng(IconOf(*tab, pinned));
        std::optional<std::string> icon = png ? OriginIcon(*url) : std::nullopt;
        if (png && icon) {
          icon_pages.insert(*url);
          sidebar.favicons.push_back(ZenFavicon{*url, std::move(*icon), std::move(*png)});
        }
      }

      if (essential) {
        if (essential_pages.insert(std::to_string(tab_container.value_or(0)) + " " + *url).second) {
          sidebar.essentials.push_back(ZenTab{*url, title, label, tab_container, std::nullopt});
        }
      } else if (pinned) {
        ZenNode link;
        link.title = label.value_or(title);
        link.url = *url;
        if (label) link.page_title = title;
        const std::optional<std::string> group = OptionalText(*tab, "groupId");
        if (group && folders.contains(*group)) {
          folder_pins[*group].push_back(Entry{sync_id, std::move(link)});
          if (workspace && !folder_space.contains(*group)) folder_space[*group] = *workspace;
        } else {
          root_pins[SpaceIndex(sidebar.spaces, workspace, tab_container)].push_back(Entry{sync_id, std::move(link)});
        }
      } else {
        sidebar.spaces[SpaceIndex(sidebar.spaces, workspace, tab_container)].tabs.push_back(
            ZenTab{*url, title, label, std::nullopt, tab->FindDouble("lastAccessed")});
      }
    }
  }

  FolderTree tree(std::move(folders), std::move(folder_order), std::move(folder_pins), std::move(folder_space), omitted_spaces);
  std::vector<std::string> visit = tree.Roots();
  visit.insert(visit.end(), tree.order().begin(), tree.order().end());
  for (const std::string& id : visit) {
    if (tree.Placed(id)) continue;
    if (tree.Omitted(id)) continue;
    const size_t index = SpaceIndex(sidebar.spaces, tree.SpaceOf(id));
    std::vector<Entry>& list = root_pins[index];
    tree.Insert(list, tree.Build(id, 0), id);
  }
  for (auto& [index, list] : root_pins) {
    std::vector<ZenNode> nodes;
    for (Entry& entry : list) nodes.push_back(std::move(entry.node));
    sidebar.spaces[index].pinned = std::move(nodes);
  }
  *out = std::move(sidebar);
  return std::nullopt;
}

std::vector<std::string> ZenSessionFiles(const std::string& profile) {
  const std::string backups = Join(profile, "zen-sessions-backup");
  std::vector<std::string> dated;
  for (const std::string& name : ListDirectory(backups)) {
    if (name.rfind("zen-sessions-", 0) == 0 && name.size() > 21 && name.compare(name.size() - 8, 8, ".jsonlz4") == 0) {
      dated.push_back(name);
    }
  }
  std::sort(dated.begin(), dated.end(), std::greater<>());
  std::vector<std::string> candidates = {Join(profile, "zen-sessions.jsonlz4"), Join(backups, "clean.jsonlz4")};
  for (const std::string& name : dated) candidates.push_back(Join(backups, name));
  if (std::string firefox = FirefoxSessionFile(profile); !firefox.empty()) candidates.push_back(std::move(firefox));
  std::vector<std::string> files;
  for (std::string& candidate : candidates) {
    if (IsFile(candidate)) files.push_back(std::move(candidate));
  }
  return files;
}

bool ZenSeparateEssentials(std::string_view prefs) {
  constexpr std::string_view kKey = "\"zen.workspaces.separate-essentials\"";
  size_t start = 0;
  while (start <= prefs.size()) {
    size_t end = prefs.find_first_of("\r\n", start);
    if (end == std::string_view::npos) end = prefs.size();
    const std::string_view line = prefs.substr(start, end - start);
    if (line.rfind("user_pref(", 0) == 0 && line.find(kKey) != std::string_view::npos) {
      std::string compact;
      for (char c : line) {
        if (c != ' ') compact.push_back(c);
      }
      return compact.find(std::string(kKey) + ",false)") == std::string::npos;
    }
    start = end + 1;
  }
  return true;
}

std::map<int, std::string> ZenContainerNames(const std::string& profile) {
  std::map<int, std::string> names;
  std::string text;
  if (ReadFileLimited(Join(profile, "containers.json"), kMaxContainersBytes, &text) != FileRead::kOk) return names;
  std::optional<base::DictValue> top = base::JSONReader::ReadDict(text, base::JSON_PARSE_RFC);
  if (!top) return names;
  for (const base::DictValue* identity : Objects(top->Find("identities"))) {
    if (identity->FindBool("public") == false) continue;
    const base::Value* id_value = identity->Find("userContextId");
    if (!id_value || !(id_value->is_int() || id_value->is_double())) continue;
    const double id = std::trunc(id_value->GetDouble());
    if (id < INT_MIN || id > INT_MAX) continue;
    std::optional<std::string> name = OptionalText(*identity, "name");
    if (!name) {
      std::optional<std::string> l10n = OptionalText(*identity, "l10nId");
      if (!l10n) l10n = OptionalText(*identity, "l10nID");
      if (l10n == "user-context-personal") name = "Personal";
      else if (l10n == "user-context-work") name = "Work";
      else if (l10n == "user-context-banking") name = "Banking";
      else if (l10n == "user-context-shopping") name = "Shopping";
    }
    if (name) names[static_cast<int>(id)] = std::move(*name);
  }
  return names;
}

std::optional<Failure> LoadZenSidebar(const std::string& profile, ScratchDirectory& scratch,
                                      const ImportObserver& observer, ZenSidebar* out) {
  const std::vector<std::string> files = ZenSessionFiles(profile);
  if (files.empty()) return Failure{"empty", "No Zen session in this profile"};
  std::string prefs;
  const bool separate = ReadFileLimited(Join(profile, "prefs.js"), kMaxPrefsBytes, &prefs) != FileRead::kOk ||
                        ZenSeparateEssentials(prefs);
  std::optional<Failure> failure;
  bool parsed = false;
  std::vector<ZenSpaceDefinition> stored;
  for (int pass = 0; pass < 2; ++pass) {
    for (const std::string& file : files) {
      if (observer.Cancelled()) return Failure{"cancelled", "Import cancelled"};
      std::string json;
      std::optional<Failure> problem = ReadSession(file, &json);
      ZenSidebar sidebar;
      if (!problem) problem = ParseZenSession(json, stored, &sidebar);
      if (problem) {
        if (!failure) failure = std::move(problem);
        continue;
      }
      parsed = true;
      sidebar.separate_essentials = separate;
      if (!sidebar.spaces.empty()) {
        *out = std::move(sidebar);
        return std::nullopt;
      }
    }
    if (pass > 0) break;
    stored = PlacesWorkspaces(profile, scratch, observer);
    if (stored.empty()) break;
  }
  if (!parsed && failure) return failure;
  *out = ZenSidebar();
  out->separate_essentials = separate;
  return std::nullopt;
}

int ZenLinkCount(const std::vector<ZenNode>& nodes) {
  int count = 0;
  for (const ZenNode& node : nodes) count += LinkCount(node);
  return count;
}

std::vector<const ZenSpace*> SelectZenSpaces(const ZenSidebar& sidebar,
                                             const std::optional<std::vector<std::string>>& space_ids) {
  std::vector<const ZenSpace*> spaces;
  for (const ZenSpace& space : sidebar.spaces) {
    if (!space_ids || std::find(space_ids->begin(), space_ids->end(), space.id) != space_ids->end()) {
      spaces.push_back(&space);
    }
  }
  return spaces;
}

base::ListValue ZenSpaceSummaries(const ZenSidebar& sidebar, const std::map<int, std::string>& containers) {
  base::ListValue out;
  for (const ZenSpace& space : sidebar.spaces) {
    base::DictValue summary;
    summary.Set("id", space.id);
    summary.Set("name", space.name);
    if (!space.colors.empty()) summary.Set("color", space.colors.front());
    if (space.emoji) summary.Set("emoji", *space.emoji);
    summary.Set("pinnedCount", ZenLinkCount(space.pinned));
    summary.Set("tabCount", static_cast<int>(space.tabs.size()));
    if (space.container) {
      summary.Set("container", *space.container);
      if (const auto name = containers.find(*space.container); name != containers.end()) {
        summary.Set("containerName", name->second);
      }
    }
    out.Append(std::move(summary));
  }
  return out;
}

base::ListValue ZenSpaceSuggestions(const std::vector<const ZenSpace*>& spaces, std::string_view profile_id,
                                    bool pinned, bool tabs) {
  base::ListValue out;
  for (const ZenSpace* space : spaces) {
    base::DictValue suggestion;
    suggestion.Set("id", space->id);
    suggestion.Set("name", space->name);
    if (!space->colors.empty()) {
      suggestion.Set("color", space->colors.front());
      base::ListValue colors;
      for (const std::string& color : space->colors) colors.Append(color);
      suggestion.Set("colors", std::move(colors));
    }
    if (space->emoji) suggestion.Set("emoji", *space->emoji);
    suggestion.Set("profileId", profile_id);
    base::ListValue pinned_nodes;
    if (pinned) {
      for (const ZenNode& node : space->pinned) pinned_nodes.Append(NodeValue(node));
    }
    suggestion.Set("pinned", std::move(pinned_nodes));
    base::ListValue open;
    if (tabs) {
      for (const ZenTab& tab : space->tabs) open.Append(TabValue(tab, false));
    }
    suggestion.Set("tabs", std::move(open));
    if (space->container) suggestion.Set("container", *space->container);
    out.Append(std::move(suggestion));
  }
  return out;
}

base::ListValue ZenOpenTabs(const std::vector<const ZenSpace*>& spaces) {
  base::ListValue out;
  for (const ZenSpace* space : spaces) {
    for (const ZenTab& tab : space->tabs) out.Append(TabValue(tab, false));
  }
  return out;
}

base::ListValue ZenEssentials(const ZenSidebar& sidebar) {
  base::ListValue out;
  for (const ZenTab& tab : sidebar.essentials) out.Append(TabValue(tab, true));
  return out;
}

base::ListValue ZenSessionFavicons(const ZenSidebar& sidebar, const std::vector<std::string>& pages) {
  std::set<std::string> wanted;
  for (const std::string& page : pages) wanted.insert(WithoutFragment(page));
  std::set<std::string> seen;
  base::ListValue out;
  size_t total = 0;
  for (const ZenFavicon& favicon : sidebar.favicons) {
    if (out.size() >= kMaxSessionIconPages) break;
    const std::string key = WithoutFragment(favicon.page);
    if (!wanted.contains(key) || !seen.insert(key).second) continue;
    if (total + favicon.png.size() > kMaxSessionIconTotal) continue;
    total += favicon.png.size();
    base::DictValue icon;
    icon.Set("page", favicon.page);
    icon.Set("icon", favicon.icon);
    icon.Set("png", favicon.png);
    out.Append(std::move(icon));
  }
  return out;
}

bool RequestedSpaceIds(const base::Value* given, std::optional<std::vector<std::string>>* out) {
  out->reset();
  if (!given || given->is_none()) return true;
  if (!given->is_list() || given->GetList().size() > kMaxZenSpaceIds) return false;
  std::vector<std::string> ids;
  for (const base::Value& id : given->GetList()) {
    if (!id.is_string() || id.GetString().empty() || id.GetString().size() > kMaxZenSpaceIdBytes ||
        !ValidUtf8(id.GetString())) {
      return false;
    }
    if (std::find(ids.begin(), ids.end(), id.GetString()) == ids.end()) ids.push_back(id.GetString());
  }
  *out = std::move(ids);
  return true;
}

}
