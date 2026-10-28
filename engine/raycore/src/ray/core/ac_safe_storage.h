#ifndef RAY_CORE_AC_SAFE_STORAGE_H_
#define RAY_CORE_AC_SAFE_STORAGE_H_

namespace base {
class CommandLine;
}

namespace raycore {

void GuardSafeStorageKey(const base::CommandLine& command_line);

}

#endif
