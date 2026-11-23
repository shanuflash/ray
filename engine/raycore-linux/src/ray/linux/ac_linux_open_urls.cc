#include "ray/linux/ac_linux_open_urls.h"

#include <algorithm>
#include <utility>

namespace ray::linux_open_urls {

namespace {

constexpr std::string_view kChromiumSwitches[] = {
    "app",          "app-id",       "incognito",         "guest",        "kiosk",
    "new-window",   "headless",     "no-startup-window", "silent-launch", "profile-directory",
    "profile-email", "load-and-launch-app", "install-chrome-app",
};

constexpr std::string_view kShellSchemes[] = {"http", "https", "file"};

char Lower(char c) {
  return c >= 'A' && c <= 'Z' ? static_cast<char>(c - 'A' + 'a') : c;
}

bool Printable(std::string_view text) {
  return std::ranges::none_of(text, [](char c) {
    const unsigned char byte = static_cast<unsigned char>(c);
    return byte <= 0x20 || byte == 0x7f;
  });
}

}

bool SwitchKeepsChromiumOpening(std::string_view name) {
  return std::ranges::find(kChromiumSwitches, name) != std::end(kChromiumSwitches);
}

bool SchemeGoesToShell(std::string_view url) {
  const size_t colon = url.find(':');
  if (colon == std::string_view::npos || colon == 0) return false;
  std::string scheme(url.substr(0, colon));
  std::ranges::transform(scheme, scheme.begin(), Lower);
  if (std::ranges::find(kShellSchemes, std::string_view(scheme)) == std::end(kShellSchemes)) return false;
  return url.substr(colon + 1).starts_with("//");
}

bool ShellTakesLaunch(const Launch& launch) {
  if (launch.background || launch.urls.empty() || launch.urls.size() > kLaunchUrls) return false;
  if (!launch.process_startup && !launch.has_window) return false;
  if (std::ranges::any_of(launch.switches, SwitchKeepsChromiumOpening)) return false;
  return std::ranges::all_of(launch.urls, [](const std::string& url) {
    return !url.empty() && url.size() <= kUrlBytes && Printable(url) && SchemeGoesToShell(url);
  });
}

Inbox::Inbox() = default;
Inbox::~Inbox() = default;

size_t Inbox::Add(const std::vector<std::string>& urls) {
  size_t added = 0;
  for (const std::string& url : urls) {
    if (urls_.size() >= kPendingUrls) break;
    urls_.push_back(url);
    ++added;
  }
  return added;
}

std::vector<std::string> Inbox::Take() {
  return std::exchange(urls_, {});
}

}
