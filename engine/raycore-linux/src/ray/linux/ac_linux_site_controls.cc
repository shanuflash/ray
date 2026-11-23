#include "ray/linux/ac_linux_site_controls.h"

#include "ray/linux/ac_linux_private_services.h"

#include <algorithm>
#include <cmath>
#include <initializer_list>
#include <set>
#include <utility>

namespace linux_site_controls {
namespace {

constexpr std::string_view kSettingTypes[] = {
    "popups", "camera", "microphone", "location", "notifications", "sound", "autoplay", "javascript",
    "images", "clipboard", "automaticDownloads", "cookies", "midi", "sensors", "windowManagement",
    "localFonts", "idleDetection", "storageAccess", "fileSystem", "keyboardLock", "pointerLock",
    "cameraPanTiltZoom",
};

constexpr std::string_view kSettingValues[] = {"allow", "block", "ask", "default"};

constexpr std::string_view kBrowsingDataTypes[] = {"history", "siteData", "cache", "downloads"};

constexpr std::string_view kServiceCalls[] = {
    "sites.settings", "sites.setSetting", "sites.origins", "sites.reset", "sites.clearData",
    "profiles.clearBrowsingData",
};

constexpr std::string_view kBlockerCalls[] = {
    "contentBlocker.state", "contentBlocker.setEnabled", "contentBlocker.setListEnabled",
    "contentBlocker.isAllowed", "contentBlocker.setAllowed", "contentBlocker.devFailNextMessage",
    "contentBlocker.devDelayNextLoad", "contentBlocker.hiddenElements", "contentBlocker.hideElements",
    "contentBlocker.restoreElements", "contentBlocker.addList", "contentBlocker.removeList",
};

constexpr std::string_view kNamedProfileCalls[] = {
    "contentBlocker.hiddenElements", "contentBlocker.hideElements", "contentBlocker.restoreElements",
};

constexpr std::string_view kPrivateIdPrefix = "incognito:";
constexpr std::string_view kPrivateHiding = "a private window keeps its hidden elements for the session";

constexpr size_t kMaxOrigin = 2048;
constexpr size_t kMaxHost = 253;
constexpr size_t kMaxListId = 128;
constexpr double kMaxSinceMs = 8.64e15;

template <typename List>
bool Contains(const List& list, std::string_view value) {
  return std::find(std::begin(list), std::end(list), value) != std::end(list);
}

Failure Invalid(std::string message) { return Failure{"ERR_SITE_REQUEST", std::move(message)}; }

Failure BlockerInvalid(std::string message) {
  return Failure{"ERR_CONTENT_BLOCKER_REQUEST", std::move(message)};
}

Failure BadReply(std::string message) { return Failure{"ERR_BAD_REPLY", std::move(message)}; }

bool OnlyKeys(const base::DictValue& args, std::initializer_list<std::string_view> allowed) {
  for (const auto [key, value] : args) {
    if (std::find(allowed.begin(), allowed.end(), key) == allowed.end()) return false;
  }
  return true;
}

const std::string* String(const base::DictValue& args, std::string_view key) {
  const base::Value* value = args.Find(key);
  return value && value->is_string() ? &value->GetString() : nullptr;
}

std::optional<bool> Bool(const base::DictValue& args, std::string_view key) {
  const base::Value* value = args.Find(key);
  if (!value || !value->is_bool()) return std::nullopt;
  return value->GetBool();
}

bool LabelChar(char c) {
  return (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-' || c == '_';
}

bool ValidHostname(std::string_view host) {
  if (host.empty() || host.size() > kMaxHost || host.front() == '.' || host.back() == '.') return false;
  size_t label = 0;
  for (char c : host) {
    if (c == '.') {
      if (label == 0) return false;
      label = 0;
      continue;
    }
    if (!LabelChar(c) || ++label > 63) return false;
  }
  return label > 0;
}

bool ValidIpv6Literal(std::string_view host) {
  if (host.size() < 4 || host.front() != '[' || host.back() != ']') return false;
  const std::string_view inner = host.substr(1, host.size() - 2);
  if (inner.size() > 45) return false;
  int colons = 0;
  for (char c : inner) {
    const bool hex = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
    if (c == ':') ++colons;
    else if (!hex && c != '.') return false;
  }
  return colons >= 2;
}

bool ValidPort(std::string_view port) {
  if (port.empty() || port.size() > 5 || port.front() == '0') return false;
  int value = 0;
  for (char c : port) {
    if (c < '0' || c > '9') return false;
    value = value * 10 + (c - '0');
  }
  return value > 0 && value <= 65535;
}

std::optional<Failure> RequireOrigin(const base::DictValue& args) {
  const std::string* origin = String(args, "origin");
  if (!origin || !ValidOrigin(*origin)) return Invalid("origin must be an http(s) origin");
  return std::nullopt;
}

std::optional<Failure> CheckEngine(const base::DictValue& args) {
  const base::Value* engine = args.Find("engine");
  if (!engine) return std::nullopt;
  if (!engine->is_string()) return Invalid("engine must be a string");
  if (engine->GetString() != "chromium")
    return Failure{"ERR_UNKNOWN_CALL", "This page engine is unavailable on Linux"};
  return std::nullopt;
}

int Count(const base::Value* value) {
  if (!value || !(value->is_int() || value->is_double())) return 0;
  const double number = value->GetDouble();
  if (!std::isfinite(number) || number <= 0) return 0;
  return number >= 2147483647.0 ? 2147483647 : static_cast<int>(number);
}

bool HostChar(char c) {
  return (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '.' || c == '-';
}

bool FilterText(std::string_view filter) {
  return !filter.empty() && filter.size() <= kMaxHidingFilterBytes &&
         filter.find_first_of(std::string_view("\n\r\0", 3)) == std::string_view::npos;
}

bool HidingRule(std::string_view filter) {
  if (!FilterText(filter)) return false;
  const size_t marker = filter.find("##");
  if (marker == std::string_view::npos || marker == 0) return false;
  for (char c : filter.substr(0, marker)) {
    if (!HostChar(c)) return false;
  }
  const std::string_view selector = filter.substr(marker + 2);
  if (selector.empty() || std::string_view("+^ \t\f\v").find(selector.front()) != std::string_view::npos) return false;
  return selector.find_first_of("{}") == std::string_view::npos;
}

std::optional<std::vector<std::string>> HidingFilters(const base::DictValue& args, bool rules_only) {
  if (!OnlyKeys(args, {"filters"})) return std::nullopt;
  const base::Value* value = args.Find("filters");
  if (!value || !value->is_list() || value->GetList().size() > kMaxHidingFilters) return std::nullopt;
  std::vector<std::string> filters;
  for (const base::Value& item : value->GetList()) {
    if (!item.is_string()) return std::nullopt;
    const std::string& filter = item.GetString();
    if (rules_only ? !HidingRule(filter) : !FilterText(filter)) return std::nullopt;
    filters.push_back(filter);
  }
  return filters;
}

base::DictValue Stats(bool ready, bool enabled) {
  return base::DictValue()
      .Set("ready", base::Value(ready))
      .Set("enabled", base::Value(enabled))
      .Set("parseMs", base::Value(0))
      .Set("lookups", base::Value(0))
      .Set("averageLookupMicros", base::Value(0))
      .Set("maxLookupMicros", base::Value(0));
}

}

bool Handles(std::string_view name) {
  return Contains(kServiceCalls, name) || IsContentBlockerCall(name);
}

bool IsContentBlockerCall(std::string_view name) { return Contains(kBlockerCalls, name); }

bool ServesNamedProfile(std::string_view name) { return Contains(kNamedProfileCalls, name); }

std::vector<std::string_view> Capabilities() {
  std::vector<std::string_view> names(std::begin(kServiceCalls), std::end(kServiceCalls));
  for (const std::string_view name : kBlockerCalls) {
    if (name != "contentBlocker.devDelayNextLoad") names.push_back(name);
  }
  return names;
}

std::variant<ProfileRoute, Failure> RouteProfile(std::string_view name, std::string_view requested, bool private_page) {
  if (ServesNamedProfile(name)) {
    const bool private_id = private_page || requested.starts_with(kPrivateIdPrefix);
    if (name == "contentBlocker.hideElements" && private_id)
      return Failure{"ERR_PROFILE_PRIVATE", std::string(kPrivateHiding)};
    return ProfileRoute::kRegistry;
  }
  if (IsContentBlockerCall(name)) return ProfileRoute::kApp;
  if (private_page || requested.starts_with("incognito:")) {
    if (raycore::linux_private_services::ServesPrivateSession(name)) return ProfileRoute::kPrivate;
    return Failure{"ERR_PROFILE_PRIVATE", "Private sessions keep no site settings or browsing data"};
  }
  return ProfileRoute::kRegistry;
}

std::string TargetProfileId(std::string_view name, std::string_view requested) {
  if (!ServesNamedProfile(name) || !requested.starts_with(kPrivateIdPrefix)) return std::string(requested);
  const size_t at = requested.find('@');
  return std::string(at == std::string_view::npos ? requested : requested.substr(at + 1));
}

bool ValidOrigin(std::string_view origin) {
  if (origin.size() > kMaxOrigin) return false;
  std::string_view rest;
  if (origin.starts_with("https://")) rest = origin.substr(8);
  else if (origin.starts_with("http://")) rest = origin.substr(7);
  else return false;
  std::string_view host = rest;
  std::string_view port;
  if (rest.starts_with("[")) {
    const size_t close = rest.find(']');
    if (close == std::string_view::npos) return false;
    host = rest.substr(0, close + 1);
    const std::string_view after = rest.substr(close + 1);
    if (!after.empty()) {
      if (after.front() != ':') return false;
      port = after.substr(1);
      if (!ValidPort(port)) return false;
    }
    return ValidIpv6Literal(host);
  }
  const size_t colon = rest.find(':');
  if (colon != std::string_view::npos) {
    host = rest.substr(0, colon);
    port = rest.substr(colon + 1);
    if (!ValidPort(port)) return false;
  }
  return ValidHostname(host);
}

std::optional<std::string> NormalizeHost(std::string_view host) {
  std::string lowered(host);
  for (char& c : lowered) {
    if (c >= 'A' && c <= 'Z') c = static_cast<char>(c - 'A' + 'a');
  }
  if (!ValidHostname(lowered)) return std::nullopt;
  return lowered;
}

bool ValidListId(std::string_view id) {
  if (ValidListUrl(id)) return true;
  if (id.empty() || id.size() > kMaxListId) return false;
  for (char c : id) {
    const bool ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
                    c == '-' || c == '_' || c == '.';
    if (!ok) return false;
  }
  return true;
}

bool ValidListUrl(std::string_view url) {
  if (url.size() > kMaxListUrl) return false;
  const auto lowered_prefix = [url](std::string_view prefix) {
    if (url.size() < prefix.size()) return false;
    for (size_t i = 0; i < prefix.size(); ++i) {
      char c = url[i];
      if (c >= 'A' && c <= 'Z') c = static_cast<char>(c - 'A' + 'a');
      if (c != prefix[i]) return false;
    }
    return true;
  };
  size_t host = 0;
  if (lowered_prefix("https://")) host = 8;
  else if (lowered_prefix("http://")) host = 7;
  else return false;
  if (host >= url.size() || url[host] == '/') return false;
  for (char c : url) {
    if (c <= ' ' || c >= 0x7f) return false;
  }
  return true;
}

std::variant<ServiceRequest, Failure> PrepareServiceCall(std::string_view name,
                                                         const base::DictValue& args) {
  if (name == "sites.settings") {
    if (!OnlyKeys(args, {"origin", "engine"})) return Invalid("unexpected site settings arguments");
    if (auto failure = CheckEngine(args)) return *failure;
    if (auto failure = RequireOrigin(args)) return *failure;
    return ServiceRequest{"ac_site_settings_get",
                          base::DictValue().Set("origin", *String(args, "origin"))};
  }
  if (name == "sites.setSetting") {
    if (!OnlyKeys(args, {"origin", "type", "value", "engine"}))
      return Invalid("unexpected site setting arguments");
    if (auto failure = CheckEngine(args)) return *failure;
    if (auto failure = RequireOrigin(args)) return *failure;
    const std::string* type = String(args, "type");
    const std::string* value = String(args, "value");
    if (!type || !Contains(kSettingTypes, *type)) return Invalid("unknown site setting type");
    if (!value || !Contains(kSettingValues, *value)) return Invalid("unknown site setting value");
    return ServiceRequest{"ac_site_settings_set", base::DictValue()
                                                      .Set("origin", *String(args, "origin"))
                                                      .Set("type", *type)
                                                      .Set("value", *value)};
  }
  if (name == "sites.origins") {
    if (args.size() != 0) return Invalid("sites.origins takes no arguments");
    return ServiceRequest{"ac_site_settings_origins", base::DictValue()};
  }
  if (name == "sites.reset" || name == "sites.clearData") {
    const bool known = name == "sites.reset" ? OnlyKeys(args, {"origin"}) : OnlyKeys(args, {"origin", "engine"});
    if (!known) return Invalid("unexpected site arguments");
    if (auto failure = CheckEngine(args)) return *failure;
    if (auto failure = RequireOrigin(args)) return *failure;
    return ServiceRequest{name == "sites.reset" ? "ac_site_settings_reset" : "ac_site_data_clear",
                          base::DictValue().Set("origin", *String(args, "origin"))};
  }
  if (name == "profiles.clearBrowsingData") {
    if (!OnlyKeys(args, {"types", "since"})) return Invalid("unexpected browsing data arguments");
    const base::Value* types = args.Find("types");
    if (!types || !types->is_list() || types->GetList().size() == 0 ||
        types->GetList().size() > std::size(kBrowsingDataTypes))
      return Invalid("types must list the data to clear");
    std::set<std::string> seen;
    base::ListValue chosen;
    for (const base::Value& type : types->GetList()) {
      if (!type.is_string() || !Contains(kBrowsingDataTypes, type.GetString()))
        return Invalid("unknown browsing data type");
      if (!seen.insert(type.GetString()).second) return Invalid("duplicate browsing data type");
      chosen.Append(base::Value(type.GetString()));
    }
    base::DictValue service;
    service.Set("types", base::Value(std::move(chosen)));
    const base::Value* since = args.Find("since");
    if (since && !since->is_none()) {
      if (!(since->is_int() || since->is_double())) return Invalid("since must be a time in milliseconds");
      const double ms = since->GetDouble();
      if (!std::isfinite(ms) || ms < 0 || ms > kMaxSinceMs) return Invalid("since must be a time in milliseconds");
      if (ms > 0) service.Set("since", base::Value(ms));
    }
    return ServiceRequest{"ac_browsing_data_clear", std::move(service)};
  }
  return Failure{"ERR_UNKNOWN_CALL", "This call is unavailable on Linux"};
}

std::variant<base::Value, Failure> CompleteServiceCall(std::string_view name,
                                                       const base::Value& reply) {
  if (!reply.is_dict()) return BadReply("The engine reply is not an object");
  const base::DictValue& dict = reply.GetDict();
  if (const base::Value* error = dict.Find("error")) {
    auto failure = raycore::linux_private_services::EngineFailure(error->is_string() ? error->GetString() : "");
    return Failure{std::move(failure.code), std::move(failure.message)};
  }
  if (name == "sites.settings") {
    const base::DictValue* settings = dict.FindDict("settings");
    if (!settings) return BadReply("Missing site settings");
    base::DictValue out;
    for (const auto [type, entry] : *settings) {
      if (!Contains(kSettingTypes, type) || !entry.is_dict()) continue;
      const std::string* value = String(entry.GetDict(), "value");
      const std::optional<bool> is_default = Bool(entry.GetDict(), "isDefault");
      if (!value || !Contains(kSettingValues, *value) || !is_default)
        return BadReply("Malformed site setting");
      out.Set(type, base::DictValue().Set("value", *value).Set("isDefault", base::Value(*is_default)));
    }
    return base::Value(std::move(out));
  }
  if (name == "sites.origins") {
    const base::Value* origins = dict.Find("origins");
    if (!origins || !origins->is_list()) return BadReply("Missing site origins");
    base::ListValue out;
    for (const base::Value& origin : origins->GetList()) {
      if (origin.is_string() && ValidOrigin(origin.GetString())) out.Append(base::Value(origin.GetString()));
    }
    return base::Value(std::move(out));
  }
  if (name == "sites.setSetting" || name == "sites.reset") return base::Value();
  if (name == "sites.clearData") {
    const base::Value* cookies = dict.Find("cookies");
    const std::optional<bool> storage = Bool(dict, "storage");
    if (!cookies || !storage || !(cookies->is_int() || (cookies->is_bool() && !cookies->GetBool())))
      return BadReply("Malformed site data reply");
    return base::Value(base::DictValue()
                           .Set("cookies", cookies->Clone())
                           .Set("storage", base::Value(*storage)));
  }
  if (name == "profiles.clearBrowsingData") {
    const std::optional<bool> ok = Bool(dict, "ok");
    if (!ok) return BadReply("Malformed browsing data reply");
    if (!*ok) return Failure{"ERR_CLEAR_INCOMPLETE", "Some browsing data could not be cleared"};
    return base::Value();
  }
  return Failure{"ERR_UNKNOWN_CALL", "This call is unavailable on Linux"};
}

std::variant<BlockerRequest, Failure> PrepareBlockerCall(std::string_view name,
                                                         const base::DictValue& args) {
  BlockerRequest request;
  if (name == "contentBlocker.state") {
    if (args.size() != 0) return BlockerInvalid("contentBlocker.state takes no arguments");
    request.op = BlockerOp::kState;
    return request;
  }
  if (name == "contentBlocker.hiddenElements") {
    if (args.size() != 0) return BlockerInvalid("contentBlocker.hiddenElements takes no arguments");
    request.op = BlockerOp::kHiddenElements;
    return request;
  }
  if (name == "contentBlocker.hideElements" || name == "contentBlocker.restoreElements") {
    const bool hide = name == "contentBlocker.hideElements";
    std::optional<std::vector<std::string>> filters = HidingFilters(args, hide);
    if (!filters) return BlockerInvalid(hide ? "filters must be a list of hiding rules" : "filters must be a list of filters");
    request.op = hide ? BlockerOp::kHideElements : BlockerOp::kRestoreElements;
    request.filters = std::move(*filters);
    return request;
  }
  if (name == "contentBlocker.devFailNextMessage") {
    if (args.size() != 0) return BlockerInvalid("contentBlocker.devFailNextMessage takes no arguments");
    request.op = BlockerOp::kFailNext;
    return request;
  }
  if (name == "contentBlocker.devDelayNextLoad") {
    return Failure{std::string(kUnavailableCode), "Delaying the content blocker's load is unavailable on Linux"};
  }
  if (name == "contentBlocker.setEnabled") {
    const std::optional<bool> enabled = Bool(args, "enabled");
    if (!OnlyKeys(args, {"enabled"}) || !enabled) return BlockerInvalid("enabled must be a boolean");
    request.op = BlockerOp::kSetEnabled;
    request.flag = *enabled;
    return request;
  }
  if (name == "contentBlocker.setListEnabled") {
    const std::string* id = String(args, "id");
    const std::optional<bool> enabled = Bool(args, "enabled");
    if (!OnlyKeys(args, {"id", "enabled"}) || !id || !ValidListId(*id) || !enabled)
      return BlockerInvalid("a filter list id and boolean are required");
    request.op = BlockerOp::kSetList;
    request.id = *id;
    request.flag = *enabled;
    return request;
  }
  if (name == "contentBlocker.addList") {
    const std::string* url = String(args, "url");
    if (!OnlyKeys(args, {"url"}) || !url || !ValidListUrl(*url))
      return BlockerInvalid("url must be an http or https address of a filter list");
    request.op = BlockerOp::kAddList;
    request.url = *url;
    return request;
  }
  if (name == "contentBlocker.removeList") {
    const std::string* id = String(args, "id");
    if (!OnlyKeys(args, {"id"}) || !id || !ValidListId(*id)) return BlockerInvalid("a filter list id is required");
    request.op = BlockerOp::kRemoveList;
    request.id = *id;
    return request;
  }
  if (name == "contentBlocker.isAllowed" || name == "contentBlocker.setAllowed") {
    const bool set = name == "contentBlocker.setAllowed";
    const std::string* host = String(args, "host");
    const std::optional<bool> allowed = Bool(args, "allowed");
    if (!(set ? OnlyKeys(args, {"host", "allowed"}) : OnlyKeys(args, {"host"})) || !host ||
        (set && !allowed))
      return BlockerInvalid("a host is required");
    std::optional<std::string> normalized = NormalizeHost(*host);
    if (!normalized) return BlockerInvalid("host must be a plain host name");
    request.op = set ? BlockerOp::kSetAllowed : BlockerOp::kIsAllowed;
    request.host = std::move(*normalized);
    request.flag = set && *allowed;
    return request;
  }
  return Failure{"ERR_UNKNOWN_CALL", "This call is unavailable on Linux"};
}

namespace {

std::optional<std::vector<std::string>> StringList(const base::DictValue& dict, std::string_view key, size_t limit) {
  const base::Value* value = dict.Find(key);
  if (!value || !value->is_list() || value->GetList().size() > limit) return std::nullopt;
  std::vector<std::string> items;
  for (const base::Value& item : value->GetList()) {
    if (!item.is_string()) return std::nullopt;
    items.push_back(item.GetString());
  }
  return items;
}

bool ValidDirective(std::string_view directive) {
  return !directive.empty() && directive.size() <= kMaxDirectiveBytes &&
         directive.find_first_of(std::string_view("\n\r\0", 3)) == std::string_view::npos;
}

base::Value StringsValue(const std::vector<std::string>& items) {
  base::ListValue list;
  for (const std::string& item : items) list.Append(base::Value(item));
  return base::Value(std::move(list));
}

}

std::optional<BlockerSettings> ParseBlockerSettings(const base::Value& value) {
  if (!value.is_dict()) return std::nullopt;
  const base::DictValue& dict = value.GetDict();
  std::optional<std::vector<std::string>> lists = StringList(dict, "lists", kMaxFollowedLists);
  std::optional<std::vector<std::string>> imported = StringList(dict, "imported", kMaxFollowedLists);
  std::optional<std::vector<std::string>> whitelist = StringList(dict, "whitelist", kMaxFollowedDirectives);
  const std::optional<bool> auto_update = Bool(dict, "autoUpdate");
  if (!lists || !imported || !whitelist || !auto_update) return std::nullopt;
  std::erase_if(*lists, [](const std::string& id) { return !ValidListId(id); });
  std::erase_if(*imported, [](const std::string& url) { return !ValidListUrl(url); });
  for (const std::string& directive : *whitelist) {
    if (!ValidDirective(directive)) return std::nullopt;
  }
  return BlockerSettings{std::move(*lists), std::move(*imported), std::move(*whitelist), *auto_update};
}

base::DictValue BlockerSettingsValue(const BlockerSettings& settings) {
  return base::DictValue()
      .Set("lists", StringsValue(settings.lists))
      .Set("imported", StringsValue(settings.imported))
      .Set("whitelist", StringsValue(settings.whitelist))
      .Set("autoUpdate", base::Value(settings.auto_update));
}

bool HoldsNavigationTo(std::string_view scheme) {
  for (const std::string_view exempt : {"chrome-extension", "chrome", "chrome-untrusted", "devtools", "about"}) {
    if (scheme == exempt) return false;
  }
  return true;
}

bool ShouldHoldNavigations(bool leader) {
  return !leader;
}

bool HoldUntilFirstCopy(bool leader, bool new_profile) {
  return !leader && new_profile;
}

int64_t InheritRetryDelayMs(int attempt) {
  return int64_t{1000} << std::clamp(attempt, 0, kInheritAttempts);
}

bool Mutates(BlockerOp op) {
  return op == BlockerOp::kSetEnabled || op == BlockerOp::kSetList || op == BlockerOp::kSetAllowed ||
         op == BlockerOp::kAddList || op == BlockerOp::kRemoveList;
}

bool AnswersWithoutBlocker(const BlockerRequest& request) {
  return (request.op == BlockerOp::kHideElements || request.op == BlockerOp::kRestoreElements) &&
         request.filters.empty();
}

std::optional<Failure> PrivateBlockerRefusal(std::string_view name, const base::DictValue& args,
                                             bool private_window) {
  if (!private_window || !IsContentBlockerCall(name)) return std::nullopt;
  const auto request = PrepareBlockerCall(name, args);
  const auto* prepared = std::get_if<BlockerRequest>(&request);
  if (!prepared || !Mutates(prepared->op)) return std::nullopt;
  return Failure{"ERR_PROFILE_PRIVATE", "Private windows can't change the content blocker"};
}

std::string_view BridgeOpName(BlockerOp op) {
  switch (op) {
    case BlockerOp::kState: return "state";
    case BlockerOp::kSetEnabled: return "setEnabled";
    case BlockerOp::kSetList: return "setList";
    case BlockerOp::kIsAllowed: return "isAllowed";
    case BlockerOp::kSetAllowed: return "setAllowed";
    case BlockerOp::kFailNext: return "failNext";
    case BlockerOp::kSettings: return "settings";
    case BlockerOp::kFollow: return "follow";
    case BlockerOp::kHiddenElements: return "hiddenElements";
    case BlockerOp::kHideElements: return "hideElements";
    case BlockerOp::kRestoreElements: return "restoreElements";
    case BlockerOp::kAddList: return "addList";
    case BlockerOp::kRemoveList: return "removeList";
  }
  return "state";
}

std::string Category(std::string_view list_id, std::string_view group) {
  if (group == "custom") return "custom";
  if (group == "regions") return "regional";
  if (list_id.find("cookie") != std::string_view::npos) return "cookies";
  if (group == "privacy" || list_id == "ublock-privacy") return "trackers";
  if (group == "malware" || list_id == "ublock-badware") return "security";
  if (group == "annoyances" || group == "social") return "annoyances";
  return "ads";
}

base::DictValue UnavailableBlockerState(std::string_view version, std::string_view error) {
  base::DictValue stats = Stats(false, false);
  stats.Set("error", error.empty() ? std::string_view("unavailable") : error);
  return base::DictValue()
      .Set("enabled", base::Value(false))
      .Set("version", version)
      .Set("lists", base::Value(base::ListValue()))
      .Set("allowedHosts", base::Value(base::ListValue()))
      .Set("stats", std::move(stats));
}

base::DictValue BlockerState(const base::DictValue& read, std::string_view version) {
  const base::Value* lists = read.Find("lists");
  if (!lists || !lists->is_list()) return UnavailableBlockerState(version, "no answer");
  base::ListValue out;
  std::set<std::string> ids;
  for (const base::Value& entry : lists->GetList()) {
    if (!entry.is_dict()) continue;
    const base::DictValue& list = entry.GetDict();
    const std::string* id = String(list, "id");
    if (!id || !ValidListId(*id) || !ids.insert(*id).second) continue;
    const std::string* title = String(list, "title");
    const std::string* group = String(list, "group");
    out.Append(base::Value(base::DictValue()
        .Set("id", *id)
        .Set("title", title && !title->empty() ? std::string_view(*title) : std::string_view(*id))
        .Set("category", Category(*id, group ? std::string_view(*group) : std::string_view()))
        .Set("enabled", base::Value(Bool(list, "enabled").value_or(false)))
        .Set("defaultOn", base::Value(Bool(list, "defaultOn").value_or(false)))
        .Set("filters", base::Value(Count(list.Find("filters"))))
        .Set("failed", base::Value(Bool(list, "failed").value_or(false)))));
  }
  base::ListValue hosts;
  std::set<std::string> seen;
  if (const base::Value* allowed = read.Find("allowedHosts"); allowed && allowed->is_list()) {
    for (const base::Value& host : allowed->GetList()) {
      if (!host.is_string()) continue;
      std::optional<std::string> normalized = NormalizeHost(host.GetString());
      if (normalized && seen.insert(*normalized).second) hosts.Append(base::Value(*normalized));
    }
  }
  const bool on = Bool(read, "enabled").value_or(false);
  base::DictValue stats = Stats(true, on);
  stats.Set("networkFilters", base::Value(Count(read.Find("networkFilters"))));
  stats.Set("cosmeticFilters", base::Value(Count(read.Find("cosmeticFilters"))));
  return base::DictValue()
      .Set("enabled", base::Value(on))
      .Set("version", version)
      .Set("lists", base::Value(std::move(out)))
      .Set("allowedHosts", base::Value(std::move(hosts)))
      .Set("stats", std::move(stats));
}

std::variant<base::Value, Failure> CompleteBlockerCall(const BlockerRequest& request,
                                                       const base::Value* value,
                                                       const std::string* error,
                                                       std::string_view version) {
  if (request.op == BlockerOp::kState) {
    if (error) return base::Value(UnavailableBlockerState(version, *error));
    if (!value || !value->is_dict()) return base::Value(UnavailableBlockerState(version, "no answer"));
    return base::Value(BlockerState(value->GetDict(), version));
  }
  if (error) return Failure{std::string(kUnavailableCode), *error};
  if (request.op == BlockerOp::kSettings) {
    std::optional<BlockerSettings> settings = value ? ParseBlockerSettings(*value) : std::nullopt;
    if (!settings) return BadReply("The content blocker's settings can't be copied");
    return base::Value(BlockerSettingsValue(*settings));
  }
  if (request.op == BlockerOp::kIsAllowed) {
    if (!value || !value->is_bool()) return BadReply("The content blocker gave no answer");
    return base::Value(value->GetBool());
  }
  if (request.op == BlockerOp::kAddList) {
    const base::DictValue* added = value && value->is_dict() ? &value->GetDict() : nullptr;
    const std::string* id = added ? String(*added, "id") : nullptr;
    const std::optional<bool> custom = added ? Bool(*added, "custom") : std::nullopt;
    const std::optional<bool> existed = added ? Bool(*added, "existed") : std::nullopt;
    const std::optional<bool> failed = added ? Bool(*added, "failed") : std::nullopt;
    const base::Value* filters = added ? added->Find("filters") : nullptr;
    if (!id || !ValidListId(*id) || !custom || !existed || !failed || !filters ||
        !(filters->is_int() || filters->is_double()))
      return BadReply("The content blocker didn't say which list it added");
    return base::Value(base::DictValue()
                           .Set("id", *id)
                           .Set("custom", base::Value(*custom))
                           .Set("existed", base::Value(*existed))
                           .Set("filters", base::Value(Count(filters)))
                           .Set("failed", base::Value(*failed)));
  }
  if (request.op == BlockerOp::kHiddenElements) {
    if (!value || !value->is_list()) return BadReply("The content blocker gave no hidden elements");
    base::ListValue filters;
    for (const base::Value& filter : value->GetList()) {
      if (filter.is_string() && HidingRule(filter.GetString())) filters.Append(base::Value(filter.GetString()));
    }
    return base::Value(std::move(filters));
  }
  return base::Value();
}

bool RetriableBridgeError(std::string_view error) {
  for (const std::string_view sign : {"no reply", "no answer", "context invalidated", "not the extension page",
                                      "renderer ", "closed", "bridge not ready"}) {
    if (error.find(sign) != std::string_view::npos) return true;
  }
  return false;
}

bool ValidBundledVersion(std::string_view version) {
  if (version.empty() || version.size() > 32) return false;
  for (char c : version) {
    if (!((c >= '0' && c <= '9') || c == '.')) return false;
  }
  return true;
}

std::string SendScript(std::string_view request_literal) {
  std::string script =
      "(() => {"
      "const root = document.documentElement;"
      "if (!root || root.getAttribute('data-ray-bridge') !== 'ready') return 'bridge not ready';"
      "root.removeAttribute('data-ray-reply');"
      "root.setAttribute('data-ray-request', ";
  script.append(request_literal);
  script.append(");return 'sent';})()");
  return script;
}

std::string PollScript() {
  return "(() => { const root = document.documentElement; "
         "return root ? root.getAttribute('data-ray-reply') : null; })()";
}

base::DictValue BridgeRequest(const PendingCall& call, int64_t now_ms) {
  base::DictValue args;
  switch (call.request.op) {
    case BlockerOp::kSetEnabled: args.Set("enabled", base::Value(call.request.flag)); break;
    case BlockerOp::kSetList:
      args.Set("id", call.request.id);
      args.Set("enabled", base::Value(call.request.flag));
      break;
    case BlockerOp::kIsAllowed: args.Set("host", call.request.host); break;
    case BlockerOp::kSetAllowed:
      args.Set("host", call.request.host);
      args.Set("allowed", base::Value(call.request.flag));
      break;
    case BlockerOp::kFollow: args = BlockerSettingsValue(call.request.settings); break;
    case BlockerOp::kAddList: args.Set("url", call.request.url); break;
    case BlockerOp::kRemoveList: args.Set("id", call.request.id); break;
    case BlockerOp::kHideElements:
    case BlockerOp::kRestoreElements: args.Set("filters", StringsValue(call.request.filters)); break;
    case BlockerOp::kHiddenElements:
    case BlockerOp::kState:
    case BlockerOp::kFailNext:
    case BlockerOp::kSettings: break;
  }
  const int64_t left = std::max<int64_t>(0, call.deadline_ms - now_ms);
  return base::DictValue()
      .Set("ticket", base::Value(call.ticket))
      .Set("op", BridgeOpName(call.request.op))
      .Set("args", std::move(args))
      .Set("deadlineMs", base::Value(static_cast<int>(std::min<int64_t>(left, BlockerQueue::kCallMs))))
      .Set("failNext", base::Value(call.fail_next));
}

std::optional<BridgeReply> ParseBridgeReply(const base::Value& parsed, int expected_ticket) {
  if (!parsed.is_dict()) return std::nullopt;
  const base::DictValue& dict = parsed.GetDict();
  const base::Value* ticket = dict.Find("ticket");
  if (!ticket || !ticket->is_int() || ticket->GetInt() != expected_ticket) return std::nullopt;
  BridgeReply reply;
  reply.ticket = expected_ticket;
  if (const base::Value* error = dict.Find("error")) {
    reply.error = error->is_string() && !error->GetString().empty() ? error->GetString()
                                                                     : std::string("no answer");
    return reply;
  }
  const base::Value* value = dict.Find("value");
  if (!value) {
    reply.error = "no answer";
    return reply;
  }
  reply.value = value->Clone();
  return reply;
}

std::optional<int> BlockerQueue::Enqueue(BlockerRequest request, int64_t now_ms) {
  if (calls_.size() >= kMaxQueued) return std::nullopt;
  PendingCall call;
  call.ticket = next_ticket_ = next_ticket_ >= 2147483646 ? 1 : next_ticket_ + 1;
  call.request = std::move(request);
  call.deadline_ms = now_ms + kCallMs;
  call.attempts_left = kAttempts;
  call.fail_next = std::exchange(fail_next_, false);
  calls_.push_back(std::move(call));
  return calls_.back().ticket;
}

BlockerQueue::Step BlockerQueue::Next(int64_t now_ms) {
  if (calls_.empty()) return Step::kIdle;
  if (in_flight_ || now_ms < retry_at_ms_) return Step::kWait;
  if (!page_ready_) {
    if (page_opening_) return Step::kWait;
    page_opening_ = true;
    return Step::kOpenPage;
  }
  return Step::kSend;
}

void BlockerQueue::PageReady() {
  page_ready_ = true;
  page_opening_ = false;
}

std::optional<BlockerQueue::Outcome> BlockerQueue::PageGone(std::string_view reason, int64_t now_ms) {
  const bool affected = in_flight_ || page_opening_;
  page_ready_ = false;
  page_opening_ = false;
  if (!affected || calls_.empty()) return std::nullopt;
  return Fail(reason, now_ms);
}

void BlockerQueue::Sent() { in_flight_ = true; }

BlockerQueue::Outcome BlockerQueue::Finish(std::optional<std::string> error, base::Value value,
                                           int64_t now_ms) {
  in_flight_ = false;
  Outcome outcome;
  outcome.call = std::move(calls_.front());
  calls_.pop_front();
  outcome.error = std::move(error);
  outcome.value = std::move(value);
  if (calls_.empty()) idle_since_ms_ = now_ms;
  return outcome;
}

std::optional<BlockerQueue::Outcome> BlockerQueue::Answer(BridgeReply reply, int64_t now_ms) {
  if (!in_flight_ || calls_.empty() || reply.ticket != calls_.front().ticket) return std::nullopt;
  if (reply.error) return Fail(*reply.error, now_ms);
  return Finish(std::nullopt, std::move(reply.value), now_ms);
}

std::optional<BlockerQueue::Outcome> BlockerQueue::Fail(std::string_view error, int64_t now_ms) {
  if (calls_.empty()) return std::nullopt;
  PendingCall& call = calls_.front();
  if (error.ends_with("failed (dev)")) call.fail_next = false;
  const bool timed_out = error.find("timed out") != std::string_view::npos;
  if (!timed_out && call.attempts_left > 0 && now_ms < call.deadline_ms && RetriableBridgeError(error)) {
    --call.attempts_left;
    in_flight_ = false;
    page_ready_ = false;
    page_opening_ = false;
    retry_at_ms_ = now_ms + kRetryMs;
    Outcome outcome;
    outcome.call = call;
    outcome.error = std::string(error);
    outcome.retry = true;
    outcome.reset_page = true;
    return outcome;
  }
  Outcome outcome = Finish(std::string(error), base::Value(), now_ms);
  outcome.reset_page = timed_out || RetriableBridgeError(error);
  if (outcome.reset_page) {
    page_ready_ = false;
    page_opening_ = false;
  }
  return outcome;
}

std::optional<BlockerQueue::Outcome> BlockerQueue::Expired(int64_t now_ms) {
  if (calls_.empty() || now_ms <= calls_.front().deadline_ms + kGraceMs) return std::nullopt;
  Outcome outcome = Finish(std::string("the call timed out"), base::Value(), now_ms);
  outcome.reset_page = true;
  page_ready_ = false;
  page_opening_ = false;
  return outcome;
}

std::vector<PendingCall> BlockerQueue::Drain() {
  std::vector<PendingCall> drained;
  while (!calls_.empty()) {
    drained.push_back(std::move(calls_.front()));
    calls_.pop_front();
  }
  in_flight_ = false;
  page_ready_ = false;
  page_opening_ = false;
  return drained;
}

bool BlockerQueue::IdleFor(int64_t now_ms) const {
  return calls_.empty() && page_ready_ && now_ms - idle_since_ms_ >= kPageIdleMs;
}

}
