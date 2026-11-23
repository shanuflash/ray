#include <cassert>
#include <cstdio>
#include <limits>
#include <vector>

#include "ray/linux/ac_linux_tab_sleep.h"
#include "chrome/browser/performance_manager/policies/discard_eligibility_policy.h"
#include "chrome/browser/performance_manager/policies/page_discarding_helper.h"
#include "components/performance_manager/public/performance_manager.h"

using namespace raycore;
namespace policies = performance_manager::policies;
using performance_manager::PerformanceManager;

namespace {

base::ListValue Args(base::Value value) {
  base::ListValue list;
  list.Append(std::move(value));
  return list;
}

std::vector<int> Codes(const base::ListValue& list) {
  std::vector<int> codes;
  for (size_t index = 0; index < list.size(); ++index) {
    assert(list[index].is_int());
    codes.push_back(list[index].GetInt());
  }
  return codes;
}

struct World {
  content::WebContents contents;
  performance_manager::Graph graph;
  performance_manager::PageNode page;
  policies::DiscardEligibilityPolicy eligibility;
  policies::PageDiscardingHelper discarding;
  World() {
    graph.eligibility = &eligibility;
    graph.discarding = &discarding;
    page.graph = &graph;
    PerformanceManager::available = true;
    PerformanceManager::contents = &contents;
    PerformanceManager::page = &page;
  }
};

const std::vector<int> kUnavailable{kLinuxSleepUnavailable};

void ParsesHiddenTime() {
  assert(ParseLinuxSleepSeconds(Args(base::Value(3600))) == 3600.0);
  assert(ParseLinuxSleepSeconds(Args(base::Value(1.5))) == 1.5);
  assert(ParseLinuxSleepSeconds(Args(base::Value(0))) == 0.0);
  assert(!ParseLinuxSleepSeconds(base::ListValue()));
  assert(!ParseLinuxSleepSeconds(Args(base::Value(-1))));
  assert(!ParseLinuxSleepSeconds(Args(base::Value(std::numeric_limits<double>::infinity()))));
  assert(!ParseLinuxSleepSeconds(Args(base::Value(std::numeric_limits<double>::quiet_NaN()))));
  assert(!ParseLinuxSleepSeconds(Args(base::Value(1e9))));
  assert(!ParseLinuxSleepSeconds(Args(base::Value("3600"))));
  assert(!ParseLinuxSleepSeconds(Args(base::Value(true))));
  base::ListValue two;
  two.Append(base::Value(1));
  two.Append(base::Value(2));
  assert(!ParseLinuxSleepSeconds(two));
}

void SleepsAnEligibleTab() {
  World w;
  assert(Codes(SleepLinuxTabIfHidden(&w.contents, 3600)).empty());
  assert(w.eligibility.asked_page == &w.page);
  assert(w.eligibility.asked_reason == policies::DiscardEligibilityPolicy::DiscardReason::PROACTIVE);
  assert(w.eligibility.asked_seconds == 3600);
  assert(w.discarding.discarded.size() == 1 && w.discarding.discarded[0] == std::vector<const performance_manager::PageNode*>{&w.page});
  assert(w.discarding.reasons[0] == policies::DiscardEligibilityPolicy::DiscardReason::PROACTIVE);
}

void AnAsleepTabIsAlreadyDone() {
  World w;
  assert(Codes(SleepLinuxTabIfHidden(&w.contents, 3600)).empty());
  w.contents.discarded = true;
  PerformanceManager::page = nullptr;
  w.eligibility.result = policies::CanDiscardResult::kProtected;
  w.eligibility.reasons = {policies::CannotDiscardReason::kVisible};
  assert(Codes(SleepLinuxTabIfHidden(&w.contents, 3600)).empty());
  assert(w.discarding.discarded.size() == 1);
  PerformanceManager::available = false;
  assert(Codes(SleepLinuxTabIfHidden(&w.contents, 3600)).empty());
}

void ReportsWhatKeptIt() {
  World w;
  w.eligibility.result = policies::CanDiscardResult::kProtected;
  w.eligibility.reasons = {policies::CannotDiscardReason::kVisible, policies::CannotDiscardReason::kFormInteractions};
  assert(Codes(SleepLinuxTabIfHidden(&w.contents, 600)) == (std::vector<int>{3, 26}));
  assert(w.discarding.discarded.empty());
  w.eligibility.result = policies::CanDiscardResult::kDisallowed;
  w.eligibility.reasons = {};
  assert(Codes(SleepLinuxTabIfHidden(&w.contents, 600)) == kUnavailable);
  assert(w.discarding.discarded.empty());
}

void UnavailableWithoutChrome() {
  {
    World w;
    assert(Codes(SleepLinuxTabIfHidden(nullptr, 60)) == kUnavailable);
    PerformanceManager::available = false;
    assert(Codes(SleepLinuxTabIfHidden(&w.contents, 60)) == kUnavailable);
  }
  {
    World w;
    content::WebContents other;
    assert(Codes(SleepLinuxTabIfHidden(&other, 60)) == kUnavailable);
  }
  {
    World w;
    w.graph.eligibility = nullptr;
    assert(Codes(SleepLinuxTabIfHidden(&w.contents, 60)) == kUnavailable);
  }
  {
    World w;
    w.graph.discarding = nullptr;
    assert(Codes(SleepLinuxTabIfHidden(&w.contents, 60)) == kUnavailable && w.eligibility.asked_page == nullptr);
  }
  {
    World w;
    w.discarding.succeed = false;
    assert(Codes(SleepLinuxTabIfHidden(&w.contents, 60)) == kUnavailable && w.discarding.discarded.size() == 1);
  }
}

}

int main() {
  ParsesHiddenTime();
  SleepsAnEligibleTab();
  AnAsleepTabIsAlreadyDone();
  ReportsWhatKeptIt();
  UnavailableWithoutChrome();
  std::puts("tab sleep scenarios passed");
}
