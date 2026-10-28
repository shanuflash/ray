#include "ray/core/ac_installed_bubble.h"

#include <utility>
#include <vector>

#include "base/functional/bind.h"
#include "base/memory/scoped_refptr.h"
#include "base/memory/weak_ptr.h"
#include "base/no_destructor.h"
#include "base/scoped_observation.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/browser.h"
#include "chrome/browser/ui/browser_window/public/browser_collection_observer.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface_iterator.h"
#include "chrome/browser/ui/browser_window/public/global_browser_collection.h"
#include "chrome/browser/ui/extensions/extension_post_install_dialog.h"
#include "components/tabs/public/tab_interface.h"
#include "content/public/browser/web_contents.h"
#include "extensions/browser/extension_registry.h"
#include "extensions/common/extension.h"
#include "ray/core/ac_hooks.h"
#include "ray/core/ac_browser.h"
#include "third_party/skia/include/core/SkBitmap.h"
#include "ui/views/widget/widget.h"

namespace raycore {

namespace {

struct Waiting {
  base::WeakPtr<Profile> profile;
  scoped_refptr<const extensions::Extension> extension;
  SkBitmap icon;
};

std::vector<Waiting>& WaitingBubbles() {
  static base::NoDestructor<std::vector<Waiting>> waiting;
  return *waiting;
}

content::WebContents* ShownPageFor(Profile* profile) {
  content::WebContents* found = nullptr;
  ForEachCurrentBrowserWindowInterfaceOrderedByActivation(
      [&](BrowserWindowInterface* browser) {
        WindowHost* host = WindowHost::ForBrowser(browser);
        tabs::TabInterface* tab = browser->GetActiveTabInterface();
        if (browser->GetProfile() != profile || !host || host->internal() ||
            host->closing() || !host->widget() || !host->widget()->IsVisible() ||
            !host->IsActiveBrowser(static_cast<Browser*>(browser)) || !tab) {
          return true;
        }
        found = tab->GetContents();
        return false;
      });
  return found;
}

void Show(Profile* profile,
          scoped_refptr<const extensions::Extension> extension,
          const SkBitmap& icon,
          content::WebContents* page) {
  extensions::TriggerPostInstallDialog(
      profile, std::move(extension), icon,
      base::BindOnce(
          [](base::WeakPtr<content::WebContents> page) { return page.get(); },
          page->GetWeakPtr()),
      base::OnceCallback<void(base::WeakPtr<content::WebContents>)>());
}

class ActivationWatch : public BrowserCollectionObserver {
 public:
  ActivationWatch() { observation_.Observe(GlobalBrowserCollection::GetInstance()); }
  void OnBrowserActivated(BrowserWindowInterface* browser) override {
    ShowWaitingInstalledBubbles();
  }

 private:
  base::ScopedObservation<GlobalBrowserCollection, BrowserCollectionObserver> observation_{
      this};
};

bool ExtensionInstalled(Profile* profile,
                        scoped_refptr<const extensions::Extension> extension,
                        const SkBitmap* icon) {
  if (!profile || !extension || extension->is_app()) {
    return true;
  }
  Profile* original = profile->GetOriginalProfile();
  const SkBitmap bitmap = icon ? *icon : SkBitmap();
  if (content::WebContents* page = ShownPageFor(original)) {
    Show(original, std::move(extension), bitmap, page);
    return true;
  }
  std::vector<Waiting>& waiting = WaitingBubbles();
  std::erase_if(waiting, [&](const Waiting& w) {
    return !w.profile || (w.profile.get() == original &&
                          w.extension->id() == extension->id());
  });
  waiting.push_back({original->GetWeakPtr(), std::move(extension), bitmap});
  static base::NoDestructor<ActivationWatch> watch;
  return true;
}

}

void InstallExtensionInstalledHook() {
  g_ray_extension_installed = &ExtensionInstalled;
  download_crx_util::g_ray_prompts_without_tab = true;
}

void ShowWaitingInstalledBubbles() {
  std::vector<Waiting>& waiting = WaitingBubbles();
  if (waiting.empty()) {
    return;
  }
  std::vector<Waiting> list = std::move(waiting);
  waiting.clear();
  for (Waiting& w : list) {
    if (!w.profile || !extensions::ExtensionRegistry::Get(w.profile.get())
                           ->enabled_extensions()
                           .Contains(w.extension->id())) {
      continue;
    }
    if (content::WebContents* page = ShownPageFor(w.profile.get())) {
      Show(w.profile.get(), std::move(w.extension), w.icon, page);
    } else {
      waiting.push_back(std::move(w));
    }
  }
}

}
