#include "ray/linux/ac_linux_idle_profile_engine.h"

#include <algorithm>
#include <vector>

#include "base/memory/weak_ptr.h"
#include "base/time/time.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/download/download_core_service.h"
#include "chrome/browser/download/download_core_service_factory.h"
#include "chrome/browser/lifetime/browser_shutdown.h"
#include "chrome/browser/performance_manager/policies/cannot_discard_reason.h"
#include "chrome/browser/performance_manager/policies/discard_eligibility_policy.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/profiles/profile_manager.h"
#include "chrome/browser/resource_coordinator/lifecycle_unit_state.mojom.h"
#include "chrome/browser/resource_coordinator/tab_lifecycle_unit_external.h"
#include "components/performance_manager/public/graph/graph.h"
#include "components/performance_manager/public/graph/page_node.h"
#include "components/performance_manager/public/performance_manager.h"
#include "content/public/browser/web_contents.h"

namespace raycore {

bool LinuxTabSleepsOrCanSleep(content::WebContents* contents, bool sleep) {
  namespace policies = performance_manager::policies;
  using performance_manager::PerformanceManager;
  if (!contents) return false;
  if (contents->WasDiscarded()) return true;
  if (contents->NeedToFireBeforeUnload() || !PerformanceManager::IsAvailable()) return false;
  base::WeakPtr<performance_manager::PageNode> page = PerformanceManager::GetPrimaryPageNodeForWebContents(contents);
  if (!page) return false;
  auto* eligibility = policies::DiscardEligibilityPolicy::GetFromGraph(page->GetGraph());
  if (!eligibility) return false;
  std::vector<policies::CannotDiscardReason> kept_by;
  const bool eligible = eligibility->CanDiscardWithCustomRecentVisibilityWindow(
                            page.get(), policies::DiscardEligibilityPolicy::DiscardReason::PROACTIVE,
                            base::TimeDelta(), &kept_by) == policies::CanDiscardResult::kEligible;
  const bool only_its_strips_active_tab =
      !kept_by.empty() && std::ranges::all_of(kept_by, [](policies::CannotDiscardReason kept) {
        return kept == policies::CannotDiscardReason::kActiveTab;
      });
  if (!eligible && !only_its_strips_active_tab) return false;
  if (!sleep) return true;
  auto* unit = resource_coordinator::TabLifecycleUnitExternal::FromWebContents(contents);
  return unit && unit->DiscardTab(::mojom::LifecycleUnitDiscardReason::EXTERNAL) && contents->WasDiscarded();
}

std::optional<std::string> LinuxProfileHeldOpenBy(Profile* profile) {
  if (!profile || !profile->IsRegularProfile() || profile->ShutdownStarted() || browser_shutdown::IsTryingToQuit() ||
      profile->GetBaseName() == ProfileManager::GetInitialProfileDir()) {
    return "profile";
  }
  if (profile->HasAnyOffTheRecordProfile()) return "private";
  DownloadCoreService* downloads = DownloadCoreServiceFactory::GetForBrowserContext(profile);
  if (downloads && downloads->BlockingShutdownCount() > 0) return "download";
  return std::nullopt;
}

std::string ReleaseLinuxIdleProfile(Profile* profile) {
  base::WeakPtr<Profile> weak = profile ? profile->GetWeakPtr() : nullptr;
  if (weak && !weak->ShutdownStarted() && g_browser_process && g_browser_process->profile_manager()) {
    g_browser_process->profile_manager()->ClearFirstBrowserWindowKeepAlive(weak.get());
  }
  return !weak || weak->ShutdownStarted() ? "released" : "pending";
}

}
