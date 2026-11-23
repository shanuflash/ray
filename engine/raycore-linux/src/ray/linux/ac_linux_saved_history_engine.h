#ifndef RAY_LINUX_AC_LINUX_SAVED_HISTORY_ENGINE_H_
#define RAY_LINUX_AC_LINUX_SAVED_HISTORY_ENGINE_H_

#include <string>

#include "base/functional/callback.h"

class Profile;

namespace raycore {

void ReadLinuxSavedTabHistory(Profile* profile, const std::string& key, const std::string& url,
                              base::OnceCallback<void(std::string)> done);

}

#endif
