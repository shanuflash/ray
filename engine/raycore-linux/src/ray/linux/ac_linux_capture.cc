#include "ray/linux/ac_linux_capture.h"

#include "chrome/browser/media/webrtc/media_capture_devices_dispatcher.h"
#include "chrome/browser/media/webrtc/media_stream_capture_indicator.h"
#include "chrome/browser/ui/tab_sharing/tab_sharing_infobar_delegate.h"
#include "components/infobars/content/content_infobar_manager.h"
#include "components/infobars/core/infobar.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/web_contents.h"

namespace raycore {

bool ShareLinuxTabInstead(content::WebContents* capturer, content::WebContents* target) {
  auto* manager = target && capturer ? infobars::ContentInfoBarManager::FromWebContents(target) : nullptr;
  if (!manager) return false;
  TabSharingInfoBarDelegate* found = nullptr;
  size_t matches = 0;
  for (infobars::InfoBar* infobar : manager->infobars()) {
    if (infobar->delegate()->GetIdentifier() != infobars::InfoBarDelegate::TAB_SHARING_INFOBAR_DELEGATE) continue;
    auto* sharing = static_cast<TabSharingInfoBarDelegate*>(infobar->delegate());
    content::RenderFrameHost* frame = content::RenderFrameHost::FromID(sharing->capturer_id());
    if (!frame || content::WebContents::FromRenderFrameHost(frame) != capturer) continue;
    found = sharing;
    ++matches;
  }
  if (!found || !linux_capture::SharesInstead(found->GetButtons(), TabSharingInfoBarDelegate::kShareThisTabInstead,
                                              found->IsButtonEnabled(TabSharingInfoBarDelegate::kShareThisTabInstead),
                                              matches)) {
    return false;
  }
  found->ShareThisTabInstead();
  return true;
}

bool StopLinuxCapture(content::WebContents* capturer) {
  if (!capturer) return false;
  scoped_refptr<MediaStreamCaptureIndicator> indicator =
      MediaCaptureDevicesDispatcher::GetInstance()->GetMediaStreamCaptureIndicator();
  const bool capturing = indicator->IsCapturingTab(capturer) || indicator->IsCapturingWindow(capturer) ||
                         indicator->IsCapturingDisplay(capturer);
  indicator->StopMediaCapturing(capturer, MediaStreamCaptureIndicator::MediaType::kDisplayMedia);
  return capturing;
}

}
