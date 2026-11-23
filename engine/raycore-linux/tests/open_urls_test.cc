#include <cassert>
#include <cstdio>
#include <string>
#include <vector>

#include "ray/linux/ac_linux_open_urls.cc"

namespace open_urls = ray::linux_open_urls;

namespace {

open_urls::Launch Running(std::vector<std::string> urls, std::vector<std::string> switches = {}) {
  open_urls::Launch launch;
  launch.urls = std::move(urls);
  launch.switches = std::move(switches);
  launch.has_window = true;
  return launch;
}

void Policy() {
  assert(open_urls::ShellTakesLaunch(Running({"https://example.com/"})));
  assert(open_urls::ShellTakesLaunch(Running({"http://example.com/a?b=c#d", "HTTPS://EXAMPLE.COM/", "file:///home/me/page.html"})));
  assert(open_urls::ShellTakesLaunch(Running({"https://example.com/"}, {"user-data-dir", "enable-features", "ozone-platform"})));
  assert(!open_urls::ShellTakesLaunch(Running({})));
  for (const char* refused : {"", "example.com", "about:blank", "chrome://settings/", "javascript:alert(1)", "data:text/html,x",
                              "view-source:https://example.com/", "mailto:someone@example.com", "https:example.com",
                              "https://exa mple.com/", "https://example.com/\n", ":https://example.com/", "ftp://example.com/"}) {
    assert(!open_urls::ShellTakesLaunch(Running({refused})));
    assert(!open_urls::ShellTakesLaunch(Running({"https://example.com/", refused})));
  }
  assert(!open_urls::ShellTakesLaunch(Running({std::string("https://example.com/\0x", 22)})));
  assert(open_urls::ShellTakesLaunch(Running({"https://example.com/" + std::string(open_urls::kUrlBytes - 20, 'a')})));
  assert(!open_urls::ShellTakesLaunch(Running({"https://example.com/" + std::string(open_urls::kUrlBytes - 19, 'a')})));
  assert(open_urls::ShellTakesLaunch(Running(std::vector<std::string>(open_urls::kLaunchUrls, "https://example.com/"))));
  assert(!open_urls::ShellTakesLaunch(Running(std::vector<std::string>(open_urls::kLaunchUrls + 1, "https://example.com/"))));
  for (const char* chromium : {"app", "app-id", "incognito", "guest", "kiosk", "new-window", "headless", "no-startup-window",
                               "silent-launch", "profile-directory", "profile-email", "load-and-launch-app",
                               "install-chrome-app"}) {
    assert(open_urls::SwitchKeepsChromiumOpening(chromium));
    assert(!open_urls::ShellTakesLaunch(Running({"https://example.com/"}, {"user-data-dir", chromium})));
  }
  assert(!open_urls::SwitchKeepsChromiumOpening("user-data-dir"));
  assert(!open_urls::SwitchKeepsChromiumOpening("--incognito"));
  assert(!open_urls::SwitchKeepsChromiumOpening(""));
}

void Instances() {
  open_urls::Launch background = Running({"https://example.com/"});
  background.background = true;
  assert(!open_urls::ShellTakesLaunch(background));
  background.process_startup = true;
  assert(!open_urls::ShellTakesLaunch(background));

  open_urls::Launch windowless = Running({"https://example.com/"});
  windowless.has_window = false;
  assert(!open_urls::ShellTakesLaunch(windowless));

  open_urls::Launch starting = windowless;
  starting.process_startup = true;
  assert(open_urls::ShellTakesLaunch(starting));
  starting.switches = {"incognito"};
  assert(!open_urls::ShellTakesLaunch(starting));
}

void Pending() {
  open_urls::Inbox inbox;
  assert(inbox.empty() && inbox.pending() == 0 && inbox.Take().empty());
  assert(inbox.Add({"https://one.example/", "https://two.example/"}) == 2);
  assert(inbox.Add({"https://three.example/"}) == 1);
  assert(!inbox.empty() && inbox.pending() == 3);
  const std::vector<std::string> taken = inbox.Take();
  assert((taken == std::vector<std::string>{"https://one.example/", "https://two.example/", "https://three.example/"}));
  assert(inbox.empty() && inbox.Take().empty());

  assert(inbox.Add(std::vector<std::string>(open_urls::kPendingUrls - 1, "https://many.example/")) == open_urls::kPendingUrls - 1);
  assert(inbox.Add({"https://last.example/", "https://dropped.example/"}) == 1);
  assert(inbox.Add({"https://dropped.example/"}) == 0);
  assert(inbox.pending() == open_urls::kPendingUrls);
  assert(inbox.Take().back() == "https://last.example/");
  assert(inbox.Add({"https://again.example/"}) == 1);
}

}

int main(int argc, char** argv) {
  assert(argc == 2);
  const std::string scenario = argv[1];
  if (scenario == "policy") Policy();
  else if (scenario == "instances") Instances();
  else if (scenario == "pending") Pending();
  else return 2;
  std::puts("ok");
  return 0;
}
