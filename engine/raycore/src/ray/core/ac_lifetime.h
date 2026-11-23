#ifndef RAY_CORE_AC_LIFETIME_H_
#define RAY_CORE_AC_LIFETIME_H_

namespace raycore {

void InstallAppOverrides();

void StartLifetimeObservers();

void QuitEngine();
bool IsQuitting();

void HostQuitCancelled();

}

#endif
