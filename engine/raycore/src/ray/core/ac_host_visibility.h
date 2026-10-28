// Copyright 2026 Ray. Apache-2.0.

#ifndef RAY_CORE_AC_HOST_VISIBILITY_H_
#define RAY_CORE_AC_HOST_VISIBILITY_H_

#include <optional>

namespace content {
class WebContents;
}

namespace raycore {

void NoteTabShownByHost(content::WebContents* contents, bool shown);

std::optional<bool> ShownByHost(content::WebContents* contents);

void StartHostVisibility();

}

#endif
