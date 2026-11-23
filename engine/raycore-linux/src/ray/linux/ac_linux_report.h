#ifndef RAY_LINUX_AC_LINUX_REPORT_H_
#define RAY_LINUX_AC_LINUX_REPORT_H_

#include <string_view>

#include "base/files/file_path.h"
#include "base/functional/callback.h"
#include "base/values.h"

namespace raycore {

using LinuxReportEvent = base::RepeatingCallback<void(base::Value)>;

bool LinuxReportInvokes(std::string_view method);
void LinuxReportInvoke(std::string_view method, const base::ListValue& args, const base::FilePath& documents,
                       int caller, LinuxReportEvent emit, base::OnceCallback<void(bool, base::Value)> done);
void LinuxReportCallerGone(int caller);

}

#endif
