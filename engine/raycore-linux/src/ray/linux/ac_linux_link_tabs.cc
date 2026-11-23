#include "ray/linux/ac_linux_link_tabs.h"

#include <algorithm>
#include <iterator>
#include <utility>

namespace raycore {

std::optional<LinuxTabKeys> LinuxPeekSiteTabIds(const base::DictValue& input) {
  const base::ListValue* ids = input.FindList("tabIds");
  if (!ids || ids->size() > kLinuxPeekSiteTabsMax) return std::nullopt;
  LinuxTabKeys keys;
  for (const base::Value& id : *ids) {
    if (!id.is_string()) return std::nullopt;
    const std::string& key = id.GetString();
    if (key.empty() || key.size() > kLinuxTabKeyMax || key.find('\0') != std::string::npos) return std::nullopt;
    keys.insert(key);
  }
  return keys;
}

std::optional<bool> LinuxNewTabLinksInPlace(const base::DictValue& input) {
  return input.FindBool("enabled");
}

bool LinuxTabUrlBlank(std::string_view url) {
  return url.empty() || url == "about:blank";
}

std::vector<std::string> LinuxPeekSiteTabs::Set(LinuxTabKeys next) {
  std::vector<std::string> changed;
  std::set_symmetric_difference(tabs_.begin(), tabs_.end(), next.begin(), next.end(), std::back_inserter(changed));
  tabs_ = std::move(next);
  return changed;
}

void LinuxNewTabLinks::DropStale(double now) {
  std::erase_if(links_, [now](const Link& link) { return !(now >= link.at && now - link.at < kLifetime); });
}

void LinuxNewTabLinks::Note(std::string_view url, double now) {
  if (url.empty()) return;
  DropStale(now);
  links_.push_back({std::string(url), now});
  if (links_.size() > kKept) links_.erase(links_.begin(), links_.end() - kKept);
}

std::optional<std::string> LinuxNewTabLinks::TakeFor(std::string_view first, std::string_view current, double now) {
  DropStale(now);
  for (auto link = links_.begin(); link != links_.end(); ++link) {
    if (link->url != first && link->url != current) continue;
    std::string url = std::move(link->url);
    links_.erase(link);
    return url;
  }
  return std::nullopt;
}

std::optional<std::string> LinuxNewTabLinks::TakeNoted(double within, double now) {
  DropStale(now);
  if (links_.empty() || now - links_.back().at > within) return std::nullopt;
  std::string url = std::move(links_.back().url);
  links_.pop_back();
  return url;
}

LinuxLinkTabMatch MatchLinuxLinkTab(LinuxNewTabLinks& links, const LinuxLinkTabAttempt& attempt) {
  LinuxLinkTabMatch match;
  std::optional<std::string> clicked = links.TakeFor(attempt.first_url, attempt.current_url, attempt.now);
  if (!clicked && attempt.hidden) clicked = links.TakeNoted(LinuxNewTabLinks::kHiddenLifetime, attempt.now);
  if (clicked) {
    match.step = attempt.in_place ? LinuxLinkTabStep::kInPlace : LinuxLinkTabStep::kReport;
    match.clicked = std::move(*clicked);
    match.link_wait = "matched";
    return match;
  }
  const bool activated = attempt.tries > 0 || attempt.activated;
  if (activated && attempt.tries < kLinuxLinkTabTries) {
    match.step = LinuxLinkTabStep::kRetry;
    return match;
  }
  match.link_wait = attempt.tries >= kLinuxLinkTabTries ? "timedOut" : "skipped";
  return match;
}

}
