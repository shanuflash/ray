#ifndef RAY_CORE_AC_LIFETIME_H_
#define RAY_CORE_AC_LIFETIME_H_

#include "base/functional/callback.h"

namespace raycore {

void InstallAppOverrides();

void StartLifetimeObservers();

void QuitEngine();
bool IsQuitting();

struct LifetimeCallbacks {
  base::RepeatingClosure quit_cancelled;
};
void SetLifetimeCallbacks(LifetimeCallbacks callbacks);

}

#endif
