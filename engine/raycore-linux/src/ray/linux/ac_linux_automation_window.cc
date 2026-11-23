#include "ray/linux/ac_linux_automation_window.h"

#include <map>
#include <utility>
#include <vector>

#include "base/files/file_path.h"
#include "base/memory/weak_ptr.h"
#include "base/no_destructor.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/browser_window/public/create_browser_window.h"
#include "chrome/browser/ui/tabs/tab_enums.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "content/public/browser/devtools_agent_host.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/web_contents.h"
#include "ui/gfx/geometry/rect.h"

namespace raycore {

namespace {

std::map<base::FilePath, base::WeakPtr<BrowserWindowInterface>>& AutomationWindows() {
  static base::NoDestructor<std::map<base::FilePath, base::WeakPtr<BrowserWindowInterface>>> windows;
  return *windows;
}

}

BrowserWindowInterface* LinuxAutomationWindowFor(Profile* profile) {
  if (!profile || profile->IsOffTheRecord() || profile->ShutdownStarted()) return nullptr;
  auto& windows = AutomationWindows();
  if (auto found = windows.find(profile->GetPath()); found != windows.end()) {
    if (found->second && !found->second->IsDeleteScheduled()) return found->second.get();
    windows.erase(found);
  }
  if (GetBrowserWindowCreationStatusForProfile(*profile) != BrowserWindowInterface::CreationStatus::kOk) {
    return nullptr;
  }
  BrowserWindowCreateParams params(profile, false);
  params.omit_from_session_restore = true;
  params.should_trigger_session_restore = false;
  params.initial_bounds = gfx::Rect(0, 0, 1280, 800);
  BrowserWindowInterface* created = CreateBrowserWindow(std::move(params));
  if (!created) return nullptr;
  windows[profile->GetPath()] = created->GetWeakPtr();
  return created;
}

bool IsLinuxAutomationWindow(const BrowserWindowInterface* browser) {
  if (!browser) return false;
  for (const auto& [path, window] : AutomationWindows()) {
    if (window.get() == browser) return true;
  }
  return false;
}

bool InsertIntoLinuxAutomationWindow(BrowserWindowInterface* window, std::unique_ptr<content::WebContents> contents) {
  if (!window || !contents || !IsLinuxAutomationWindow(window) || window->IsDeleteScheduled()) return false;
  TabStripModel* model = window->GetTabStripModel();
  model->InsertWebContentsAt(model->count(), std::move(contents), AddTabTypes::ADD_ACTIVE);
  return true;
}

void CloseLinuxOffscreenTabs() {
  std::vector<base::WeakPtr<BrowserWindowInterface>> windows;
  for (const auto& [path, window] : AutomationWindows()) windows.push_back(window);
  for (const auto& window : windows) {
    if (!window || window->IsDeleteScheduled()) continue;
    TabStripModel* model = window->GetTabStripModel();
    while (window && !window->IsDeleteScheduled() && model->count() > 0) {
      model->DetachAndDeleteWebContentsAt(model->count() - 1);
    }
  }
}

std::optional<std::string> LinuxDevToolsTargetId(content::WebContents* contents) {
  if (!contents || contents->IsCrashed() || contents->WasDiscarded() ||
      !contents->GetController().GetLastCommittedEntry()) {
    return std::nullopt;
  }
  scoped_refptr<content::DevToolsAgentHost> host = content::DevToolsAgentHost::GetOrCreateFor(contents);
  if (!host) return std::nullopt;
  return host->GetId();
}

}
