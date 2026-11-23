#include "ray/linux/ac_linux_auto_pip_service.h"

#include <vector>

#include "ray/linux/ac_linux_auto_pip.h"
#include "base/check.h"
#include "base/functional/bind.h"
#include "base/functional/callback.h"
#include "base/memory/weak_ptr.h"
#include "base/no_destructor.h"
#include "base/scoped_observation.h"
#include "base/task/single_thread_task_runner.h"
#include "base/time/time.h"
#include "base/timer/timer.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/content_settings/host_content_settings_map_factory.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/profiles/profile_manager.h"
#include "chrome/browser/profiles/profile_manager_observer.h"
#include "components/content_settings/core/browser/host_content_settings_map.h"
#include "components/content_settings/core/common/content_settings.h"
#include "components/content_settings/core/common/content_settings_types.h"
#include "content/public/browser/browser_thread.h"
#include "content/public/browser/visibility.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_observer.h"
#include "content/public/browser/web_contents_user_data.h"

namespace raycore {
namespace {

class AutoPictureInPictureProfiles : public ProfileManagerObserver {
 public:
  void Set(bool enabled) {
    ProfileManager* manager = g_browser_process ? g_browser_process->profile_manager() : nullptr;
    if (manager && !observation_.IsObserving()) observation_.Observe(manager);
    preference_.Set(enabled, manager ? manager->GetLoadedProfiles() : std::vector<Profile*>());
  }

 private:
  static void Apply(Profile* profile, bool enabled) {
    if (HostContentSettingsMap* map = HostContentSettingsMapFactory::GetForProfile(profile)) {
      map->SetDefaultContentSetting(ContentSettingsType::AUTO_PICTURE_IN_PICTURE,
                                    enabled ? CONTENT_SETTING_ALLOW : CONTENT_SETTING_BLOCK);
    }
  }

  static bool Regular(Profile* profile) {
    return profile->IsRegularProfile() && !profile->ShutdownStarted();
  }

  void OnProfileAdded(Profile* profile) override {
    preference_.Added(profile);
  }

  void OnProfileManagerDestroying() override {
    observation_.Reset();
  }

  linux_auto_pip::Preference<Profile> preference_{&AutoPictureInPictureProfiles::Apply,
                                                   &AutoPictureInPictureProfiles::Regular};
  base::ScopedObservation<ProfileManager, ProfileManagerObserver> observation_{this};
};

class HiddenPageDeparture : public content::WebContentsUserData<HiddenPageDeparture>,
                            public content::WebContentsObserver {
 public:
  void Depart(base::OnceClosure depart) {
    Stop();
    if (wait_.Depart(GetWebContents().GetVisibility() == content::Visibility::VISIBLE)) {
      return std::move(depart).Run();
    }
    depart_ = std::move(depart);
    timer_.Start(FROM_HERE, base::Milliseconds(linux_auto_pip::kHiddenPageWaitMs),
                 base::BindOnce(&HiddenPageDeparture::WaitedOut, weak_factory_.GetWeakPtr()));
  }

  void Return() {
    wait_.Return();
    Stop();
  }

  void OnVisibilityChanged(content::Visibility visibility) override {
    if (!wait_.waiting() || visibility == content::Visibility::VISIBLE) return;
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(&HiddenPageDeparture::PageHidden, weak_factory_.GetWeakPtr()));
  }

 private:
  explicit HiddenPageDeparture(content::WebContents* contents)
      : content::WebContentsUserData<HiddenPageDeparture>(*contents), content::WebContentsObserver(contents) {}
  friend class content::WebContentsUserData<HiddenPageDeparture>;
  WEB_CONTENTS_USER_DATA_KEY_DECL();

  void PageHidden() {
    if (wait_.PageHidden()) Finish();
  }

  void WaitedOut() {
    if (wait_.WaitedOut()) Finish();
  }

  void Finish() {
    base::OnceClosure depart = std::move(depart_);
    Stop();
    if (depart) std::move(depart).Run();
  }

  void Stop() {
    timer_.Stop();
    depart_.Reset();
    weak_factory_.InvalidateWeakPtrs();
  }

  linux_auto_pip::HiddenPageWait wait_;
  base::OnceClosure depart_;
  base::OneShotTimer timer_;
  base::WeakPtrFactory<HiddenPageDeparture> weak_factory_{this};
};

WEB_CONTENTS_USER_DATA_KEY_IMPL(HiddenPageDeparture);

}

void DepartWhenLinuxPageHidden(content::WebContents* contents, base::OnceClosure depart) {
  if (!contents) return;
  HiddenPageDeparture::CreateForWebContents(contents);
  HiddenPageDeparture::FromWebContents(contents)->Depart(std::move(depart));
}

void ReturnBeforeLinuxPageHidden(content::WebContents* contents) {
  if (auto* departure = contents ? HiddenPageDeparture::FromWebContents(contents) : nullptr) departure->Return();
}

void SetLinuxAutoPictureInPicture(bool enabled) {
  CHECK(content::BrowserThread::CurrentlyOn(content::BrowserThread::UI));
  static base::NoDestructor<AutoPictureInPictureProfiles> profiles;
  profiles->Set(enabled);
}

}
