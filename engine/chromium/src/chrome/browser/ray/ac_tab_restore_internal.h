// Copyright 2026 Ray. Apache-2.0.

#ifndef CHROME_BROWSER_RAY_AC_TAB_RESTORE_INTERNAL_H_
#define CHROME_BROWSER_RAY_AC_TAB_RESTORE_INTERNAL_H_

#include <string>

#include "base/containers/span.h"
#include "components/sessions/core/serialized_navigation_entry.h"

namespace ray {
namespace tab_restore_internal {

inline constexpr char kTabKey[] = "ac_tab";

std::string PackNavigations(
    int selected,
    base::span<const sessions::SerializedNavigationEntry> navigations);

}
}

#endif
