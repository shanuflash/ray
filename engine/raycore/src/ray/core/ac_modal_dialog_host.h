#ifndef RAY_CORE_AC_MODAL_DIALOG_HOST_H_
#define RAY_CORE_AC_MODAL_DIALOG_HOST_H_

#include "base/observer_list.h"
#include "components/web_modal/web_contents_modal_dialog_host.h"
#include "content/public/browser/web_contents_user_data.h"
#include "ui/gfx/geometry/point.h"
#include "ui/gfx/geometry/rect.h"
#include "ui/gfx/geometry/size.h"

@class NSView;
@class NSWindow;

namespace content {
class WebContents;
}

namespace raycore {

class WindowHost;

gfx::Rect PageRectInHostView(NSView* host_view, content::WebContents* contents);
gfx::Point DialogPositionInHostView(NSView* host_view,
                                    const gfx::Rect& page,
                                    const gfx::Size& size);

bool WindowIsForeground(NSWindow* window);
void DialogHostObserverAdded();
void DialogHostObserverRemoved();

class ACTabDialogHost : public web_modal::WebContentsModalDialogHost,
                        public content::WebContentsUserData<ACTabDialogHost> {
 public:
  ACTabDialogHost(const ACTabDialogHost&) = delete;
  ACTabDialogHost& operator=(const ACTabDialogHost&) = delete;
  ~ACTabDialogHost() override;

  gfx::NativeView GetHostView() const override;
  gfx::Point GetDialogPosition(const gfx::Size& size) override;
  bool ShouldActivateDialog() const override;
  gfx::Size GetMaximumDialogSize() override;
  void AddObserver(web_modal::ModalDialogHostObserver* observer) override;
  void RemoveObserver(web_modal::ModalDialogHostObserver* observer) override;
  void NotifyPositionRequiresUpdate() override;

 private:
  friend class content::WebContentsUserData<ACTabDialogHost>;
  explicit ACTabDialogHost(content::WebContents* contents);

  WindowHost* window_host() const;

  base::ObserverList<web_modal::ModalDialogHostObserver> observers_;
  WEB_CONTENTS_USER_DATA_KEY_DECL();
};

}

#endif
