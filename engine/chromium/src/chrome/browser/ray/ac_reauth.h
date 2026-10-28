// Copyright 2026 Ray. Apache-2.0.

#ifndef CHROME_BROWSER_RAY_AC_REAUTH_H_
#define CHROME_BROWSER_RAY_AC_REAUTH_H_

#include <string>

#include "base/functional/callback_forward.h"
#include "base/time/time.h"
#include "components/device_reauth/device_reauth_metrics_util.h"

class Profile;

namespace ray {

void Reauth(Profile* profile,
            device_reauth::DeviceAuthSource source,
            const std::u16string& purpose,
            base::TimeDelta validity,
            base::OnceCallback<void(bool)> done);

}

#endif
