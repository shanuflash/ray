// Copyright 2026 Ray. Apache-2.0.

#include "ray/core/ac_host_visibility.h"

#include <string>

#include "base/functional/bind.h"
#include "base/memory/weak_ptr.h"
#include "base/task/single_thread_task_runner.h"
#include "base/time/time.h"
#include "base/timer/timer.h"
#include "chrome/browser/ui/tabs/public/tab_dialog_manager.h"
#include "chrome/browser/ui/tabs/public/tab_features.h"
#include "components/permissions/permission_request_manager.h"
#include "components/tabs/public/tab_interface.h"
#include "content/public/browser/visibility.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_observer.h"
#include "content/public/browser/web_contents_user_data.h"
#include "ray/core/ac_browser.h"
#include "ray/core/ac_hooks.h"
#include "ray/core/ac_picture_in_picture.h"
#include "ray/core/ac_video_upscaling.h"

namespace raycore {

namespace {

constexpr base::TimeDelta kHiddenPageWait = base::Milliseconds(400);

void UpdateTabDialogs(content::WebContents* contents) {
  if (auto* tab = tabs::TabInterface::MaybeGetFromContents(contents)) {
    if (auto* features = tab->GetTabFeatures()) {
      if (auto* dialogs = features->tab_dialog_manager()) {
        if (dialogs->UpdateDialogVisibility()) {
          dialogs->UpdateModalDialogBounds();
        }
      }
    }
  }
}

class HostVisibility : public content::WebContentsUserData<HostVisibility>,
                       public content::WebContentsObserver {
 public:
  bool shown() const { return shown_; }
  bool shown_until_page_hidden() const { return shown_ || awaiting_hidden_page_; }

  void Note(bool shown) {
    shown_ = shown;
    if (shown || GetWebContents().GetVisibility() != content::Visibility::VISIBLE) {
      StopAwaitingHiddenPage();
      TellAutoPictureInPicture();
      return;
    }
    awaiting_hidden_page_ = true;
    hidden_page_wait_.Start(FROM_HERE, kHiddenPageWait,
                            base::BindOnce(&HostVisibility::PageHiddenOrWaitedOut,
                                           weak_factory_.GetWeakPtr(), "waited out"));
  }

  void OnVisibilityChanged(content::Visibility visibility) override {
    if (!awaiting_hidden_page_ || visibility == content::Visibility::VISIBLE) {
      return;
    }
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(&HostVisibility::PageHiddenOrWaitedOut,
                                  weak_factory_.GetWeakPtr(), "page hidden"));
  }

 private:
  explicit HostVisibility(content::WebContents* contents)
      : content::WebContentsUserData<HostVisibility>(*contents),
        content::WebContentsObserver(contents) {}
  friend class content::WebContentsUserData<HostVisibility>;
  WEB_CONTENTS_USER_DATA_KEY_DECL();

  void PageHiddenOrWaitedOut(const char* why) {
    if (!awaiting_hidden_page_) {
      return;
    }
    StopAwaitingHiddenPage();
    TraceAutoPictureInPictureInputs(&GetWebContents(),
                                    (std::string("host hides tab, ") + why).c_str());
    TellAutoPictureInPicture();
    UpdateTabDialogs(&GetWebContents());
  }

  void StopAwaitingHiddenPage() {
    awaiting_hidden_page_ = false;
    hidden_page_wait_.Stop();
    weak_factory_.InvalidateWeakPtrs();
  }

  void TellAutoPictureInPicture() {
    RayAutoPictureInPictureHostVisibilityChanged(&GetWebContents());
  }

  bool shown_ = false;
  bool awaiting_hidden_page_ = false;
  base::OneShotTimer hidden_page_wait_;
  base::WeakPtrFactory<HostVisibility> weak_factory_{this};
};

WEB_CONTENTS_USER_DATA_KEY_IMPL(HostVisibility);

class ShownSlot : public content::WebContentsUserData<ShownSlot> {
 private:
  explicit ShownSlot(content::WebContents* contents)
      : content::WebContentsUserData<ShownSlot>(*contents) {}
  friend class content::WebContentsUserData<ShownSlot>;
  WEB_CONTENTS_USER_DATA_KEY_DECL();
};

WEB_CONTENTS_USER_DATA_KEY_IMPL(ShownSlot);

int Answer(content::WebContents* contents) {
  std::optional<bool> shown = ShownByHost(contents);
  return shown ? *shown : -1;
}

int ShownUntilPageHidden(content::WebContents* contents) {
  HostVisibility* state = contents ? HostVisibility::FromWebContents(contents) : nullptr;
  return state ? state->shown_until_page_hidden() : -1;
}

}

std::optional<bool> ShownByHost(content::WebContents* contents) {
  HostVisibility* state = contents ? HostVisibility::FromWebContents(contents) : nullptr;
  return state ? std::optional<bool>(state->shown()) : std::nullopt;
}

void NoteTabShownByHost(content::WebContents* contents, bool shown) {
  if (!contents || ShownByHost(contents) == shown) {
    return;
  }
  HostVisibility::CreateForWebContents(contents);
  TraceAutoPictureInPictureInputs(contents, shown ? "host shows tab" : "host hides tab");
  HostVisibility::FromWebContents(contents)->Note(shown);
  VideoUpscalingInputsChanged();
  if (auto* prompts = permissions::PermissionRequestManager::FromWebContents(contents)) {
    prompts->OnVisibilityChanged(contents->GetVisibility());
  }
  UpdateTabDialogs(contents);
}

void NoteTabInShownSlot(content::WebContents* contents) {
  if (contents && !ShownSlot::FromWebContents(contents)) {
    ShownSlot::CreateForWebContents(contents);
  }
}

bool TabWasInShownSlot(content::WebContents* contents) {
  return contents && ShownSlot::FromWebContents(contents);
}

bool IsAutomationWindow(const BrowserWindowInterface* browser) {
  WindowHost* host = browser ? WindowHost::ForBrowser(browser) : nullptr;
  return host && host->automation();
}

bool InAutomationWindow(content::WebContents* contents) {
  WindowHost* host = contents ? WindowHost::ForContents(contents) : nullptr;
  return host && host->automation();
}

void StartHostVisibility() {
  g_ray_tab_shown_by_host = &ShownUntilPageHidden;
  g_ray_permission_tab_shown = &Answer;
}

}
