#ifndef RAY_LINUX_AC_LINUX_CAST_H_
#define RAY_LINUX_AC_LINUX_CAST_H_

#include <string>

#include "base/functional/callback.h"
#include "base/values.h"

class Profile;

namespace content {
class WebContents;
}

namespace raycore {

using LinuxCastHolder = base::RepeatingCallback<bool(content::WebContents*)>;
using LinuxCastDialogDelivery = base::RepeatingCallback<void(content::WebContents*, base::DictValue)>;
using LinuxCastRoutesDelivery = base::RepeatingCallback<void(Profile*, base::ListValue)>;

void InstallLinuxCast(LinuxCastHolder holds, LinuxCastDialogDelivery dialog, LinuxCastRoutesDelivery routes);
bool ShowLinuxCastDialog(content::WebContents* contents);
void StartLinuxCasting(int dialog_id, const std::string& sink_id, int cast_mode);
void StopLinuxCasting(int dialog_id, const std::string& route_id);
void CloseLinuxCastDialog(int dialog_id);
void WatchLinuxCastRoutes(Profile* profile);
void TerminateLinuxCastRoute(const std::string& route_id);

}

#endif
