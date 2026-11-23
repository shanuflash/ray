#include "ray/linux/ac_linux_tab_sleep.h"

#include <cmath>
#include <utility>
#include <vector>

#include "base/memory/weak_ptr.h"
#include "base/time/time.h"
#include "chrome/browser/performance_manager/policies/cannot_discard_reason.h"
#include "chrome/browser/performance_manager/policies/discard_eligibility_policy.h"
#include "chrome/browser/performance_manager/policies/page_discarding_helper.h"
#include "components/performance_manager/public/graph/graph.h"
#include "components/performance_manager/public/graph/page_node.h"
#include "components/performance_manager/public/performance_manager.h"
#include "content/public/browser/web_contents.h"

namespace raycore {

namespace {

base::ListValue Unavailable() {
  base::ListValue codes;
  codes.Append(base::Value(kLinuxSleepUnavailable));
  return codes;
}

}

std::optional<double> ParseLinuxSleepSeconds(const base::ListValue& args) {
  if (args.size() != 1 || !(args[0].is_int() || args[0].is_double())) return std::nullopt;
  const double seconds = args[0].GetDouble();
  if (!std::isfinite(seconds) || seconds < 0 || seconds > kLinuxSleepLongestHiddenSeconds) return std::nullopt;
  return seconds;
}

base::ListValue SleepLinuxTabIfHidden(content::WebContents* contents, double seconds) {
  namespace policies = performance_manager::policies;
  using performance_manager::PerformanceManager;
  if (!contents) return Unavailable();
  if (contents->WasDiscarded()) return base::ListValue();
  if (!PerformanceManager::IsAvailable()) return Unavailable();
  base::WeakPtr<performance_manager::PageNode> page = PerformanceManager::GetPrimaryPageNodeForWebContents(contents);
  if (!page) return Unavailable();
  performance_manager::Graph* graph = page->GetGraph();
  auto* eligibility = policies::DiscardEligibilityPolicy::GetFromGraph(graph);
  auto* discarding = policies::PageDiscardingHelper::GetFromGraph(graph);
  if (!eligibility || !discarding) return Unavailable();
  const auto reason = policies::DiscardEligibilityPolicy::DiscardReason::PROACTIVE;
  std::vector<policies::CannotDiscardReason> kept_by;
  if (eligibility->CanDiscardWithCustomRecentVisibilityWindow(page.get(), reason, base::Seconds(seconds), &kept_by) !=
      policies::CanDiscardResult::kEligible) {
    if (kept_by.empty()) return Unavailable();
    base::ListValue codes;
    for (policies::CannotDiscardReason kept : kept_by) codes.Append(base::Value(static_cast<int>(kept)));
    return codes;
  }
  if (!discarding->ImmediatelyDiscardMultiplePages({page.get()}, reason)) return Unavailable();
  return base::ListValue();
}

}
