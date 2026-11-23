#import "ray/core/public/RayCore.h"

#include <algorithm>
#include <set>
#include <vector>

#include "base/memory/weak_ptr.h"
#include "base/time/time.h"
#include "base/types/expected.h"
#include "chrome/browser/ray/ac_tab_restore.h"
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
#include "chrome/browser/ui/browser.h"
#include "chrome/browser/ui/browser_window.h"
#include "chrome/browser/ui/browser_window/public/global_browser_collection.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "chrome/browser/ui/unload_controller.h"
#include "components/performance_manager/public/graph/graph.h"
#include "components/performance_manager/public/graph/page_node.h"
#include "components/performance_manager/public/performance_manager.h"
#include "content/public/browser/web_contents.h"
#include "ray/core/ac_browser.h"
#import "ray/core/raycore_api_internal.h"
#import "ray/core/raycore_internal.h"

using raycore::NS;

namespace {

const char* HeldOpenBy(Profile* profile) {
  if (!profile->IsRegularProfile() || browser_shutdown::IsTryingToQuit() ||
      raycore::IsNotifyingAny() || raycore::IsProfileDying(profile) ||
      raycore::IsProfileDeleting(profile) ||
      profile->GetBaseName() == ProfileManager::GetInitialProfileDir()) {
    return "profile";
  }
  if (profile->HasAnyOffTheRecordProfile()) {
    return "private";
  }
  DownloadCoreService* downloads =
      DownloadCoreServiceFactory::GetForBrowserContext(profile);
  return downloads && downloads->BlockingShutdownCount() > 0 ? "download" : nullptr;
}

bool SleepsOrCanSleep(content::WebContents* contents, bool sleep) {
  namespace policies = performance_manager::policies;
  using performance_manager::PerformanceManager;
  raycore::TabBridge* bridge = raycore::TabBridge::FromWebContents(contents);
  if (bridge && bridge->closing_after_unload()) {
    return false;
  }
  if (contents->WasDiscarded()) {
    return true;
  }
  if (contents->NeedToFireBeforeUnload()) {
    return false;
  }
  if (!PerformanceManager::IsAvailable()) {
    return false;
  }
  base::WeakPtr<performance_manager::PageNode> page =
      PerformanceManager::GetPrimaryPageNodeForWebContents(contents);
  if (!page) {
    return false;
  }
  auto* eligibility =
      policies::DiscardEligibilityPolicy::GetFromGraph(page->GetGraph());
  if (!eligibility) {
    return false;
  }
  std::vector<policies::CannotDiscardReason> kept_by;
  const bool eligible =
      eligibility->CanDiscardWithCustomRecentVisibilityWindow(
          page.get(), policies::DiscardEligibilityPolicy::DiscardReason::PROACTIVE,
          base::TimeDelta(), &kept_by) == policies::CanDiscardResult::kEligible;
  const bool only_its_strips_active_tab =
      !kept_by.empty() &&
      std::ranges::all_of(kept_by, [](policies::CannotDiscardReason kept) {
        return kept == policies::CannotDiscardReason::kActiveTab;
      });
  if (!eligible && !only_its_strips_active_tab) {
    return false;
  }
  if (!sleep) {
    return true;
  }
  auto* unit =
      resource_coordinator::TabLifecycleUnitExternal::FromWebContents(contents);
  return unit &&
         unit->DiscardTab(::mojom::LifecycleUnitDiscardReason::EXTERNAL) &&
         contents->WasDiscarded();
}

enum class IdleTabs { kNone, kSleep };

using IdleBrowsers = std::vector<base::WeakPtr<BrowserWindowInterface>>;

base::expected<IdleBrowsers, const char*> IdleBrowsersOf(
    Profile* profile,
    IdleTabs tabs,
    const std::set<content::WebContents*>& hosted = {}) {
  if (const char* held = HeldOpenBy(profile)) {
    return base::unexpected(held);
  }
  IdleBrowsers idle;
  std::vector<content::WebContents*> pages;
  bool in_use = false;
  GlobalBrowserCollection::GetInstance()->ForEach([&](BrowserWindowInterface* window) {
    if (window->GetProfile() != profile) {
      return true;
    }
    raycore::WindowHost* host = raycore::WindowHost::ForBrowser(window);
    Browser* browser = host ? host->ExistingBrowserFor(profile) : nullptr;
    if (!browser || browser != window ||
        (host->IsActiveBrowser(browser) && !host->internal())) {
      in_use = true;
      return false;
    }
    if (host->closing() || browser->IsDeleteScheduled() ||
        UnloadController::From(browser)->is_attempting_to_close_browser()) {
      return true;
    }
    TabStripModel* model = browser->GetTabStripModel();
    for (int i = 0; i < model->count(); ++i) {
      pages.push_back(model->GetWebContentsAt(i));
    }
    idle.push_back(window->GetWeakPtr());
    return true;
  });
  if (in_use) {
    return base::unexpected("window");
  }
  if (tabs == IdleTabs::kNone && !pages.empty()) {
    return base::unexpected("tab");
  }
  for (content::WebContents* page : pages) {
    if (!hosted.contains(page)) {
      return base::unexpected("tab");
    }
    if (!ray::CanKeepTabHistory(page)) {
      return base::unexpected("history");
    }
    if (!SleepsOrCanSleep(page, false)) {
      return base::unexpected("page");
    }
  }
  bool settling = false;
  for (content::WebContents* page : pages) {
    settling |= !page->WasDiscarded();
    if (!SleepsOrCanSleep(page, true)) {
      return base::unexpected("page");
    }
    settling |= !ray::KeepTabHistory(page);
  }
  if (settling) {
    return base::unexpected("sleeping");
  }
  return idle;
}

}

@implementation RayCoreEngine (IdleProfiles)

- (NSString*)sleepIdleProfile:(RayCoreProfile*)profile hostedTabs:(NSArray<RayCoreTab*>*)tabs {
  Profile* chrome_profile = profile.chromeProfile;
  std::set<content::WebContents*> hosted;
  for (RayCoreTab* tab in tabs) {
    if (tab.contents) {
      hosted.insert(tab.contents);
    }
  }
  if (!chrome_profile || chrome_profile->IsOffTheRecord()) {
    return @"profile";
  }
  auto idle = IdleBrowsersOf(chrome_profile, IdleTabs::kSleep, hosted);
  return idle.has_value() ? nil : NS(idle.error());
}

- (NSString*)unloadIdleProfile:(RayCoreProfile*)profile {
  Profile* chrome_profile = profile.chromeProfile;
  if (!chrome_profile) {
    return @"released";
  }
  if (chrome_profile->IsOffTheRecord()) {
    return @"busy";
  }
  auto idle = IdleBrowsersOf(chrome_profile, IdleTabs::kNone);
  if (!idle.has_value()) {
    return @"busy";
  }
  base::WeakPtr<Profile> weak = chrome_profile->GetWeakPtr();
  for (const base::WeakPtr<BrowserWindowInterface>& window : *idle) {
    if (window) {
      static_cast<Browser*>(window.get())->GetWindow()->Close();
    }
  }
  if (weak && !raycore::IsProfileDying(weak.get())) {
    g_browser_process->profile_manager()->ClearFirstBrowserWindowKeepAlive(weak.get());
  }
  return !weak || raycore::IsProfileDying(weak.get()) ? @"released" : @"pending";
}

@end
