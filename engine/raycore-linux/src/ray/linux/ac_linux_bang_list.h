#ifndef RAY_LINUX_AC_LINUX_BANG_LIST_H_
#define RAY_LINUX_AC_LINUX_BANG_LIST_H_

#include "base/functional/callback.h"
#include "base/values.h"

namespace raycore {

void FetchLinuxBangList(const base::ListValue& args, base::OnceCallback<void(bool, base::Value)> done);

}

#endif
