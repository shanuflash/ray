// Copyright 2026 Ray. Apache-2.0.

#include "ray/core/ac_host_visibility.h"

#include "chrome/browser/ui/tabs/public/tab_dialog_manager.h"
#include "chrome/browser/ui/tabs/public/tab_features.h"
#include "components/permissions/permission_request_manager.h"
#include "components/tabs/public/tab_interface.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_user_data.h"
#include "ray/core/ac_hooks.h"
#include "ray/core/ac_picture_in_picture.h"
#include "ray/core/ac_video_upscaling.h"

namespace raycore {

namespace {

class HostVisibility : public content::WebContentsUserData<HostVisibility> {
 public:
  bool shown() const { return shown_; }
  void set_shown(bool shown) { shown_ = shown; }

 private:
  explicit HostVisibility(content::WebContents* contents)
      : content::WebContentsUserData<HostVisibility>(*contents) {}
  friend class content::WebContentsUserData<HostVisibility>;
  WEB_CONTENTS_USER_DATA_KEY_DECL();

  bool shown_ = false;
};

WEB_CONTENTS_USER_DATA_KEY_IMPL(HostVisibility);

int Answer(content::WebContents* contents) {
  std::optional<bool> shown = ShownByHost(contents);
  return shown ? *shown : -1;
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
  HostVisibility::FromWebContents(contents)->set_shown(shown);
  VideoUpscalingInputsChanged();
  TraceAutoPictureInPictureInputs(contents, shown ? "host shows tab" : "host hides tab");
  RayAutoPictureInPictureHostVisibilityChanged(contents);
  if (auto* prompts = permissions::PermissionRequestManager::FromWebContents(contents)) {
    prompts->OnVisibilityChanged(contents->GetVisibility());
  }
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

void StartHostVisibility() {
  g_ray_tab_shown_by_host = &Answer;
  g_ray_permission_tab_shown = &Answer;
}

}
