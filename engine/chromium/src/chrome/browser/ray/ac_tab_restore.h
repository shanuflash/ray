// Copyright 2026 Ray. Apache-2.0.

#ifndef CHROME_BROWSER_RAY_AC_TAB_RESTORE_H_
#define CHROME_BROWSER_RAY_AC_TAB_RESTORE_H_

namespace content {
class WebContents;
}

namespace ray {

void StartTabHistoryCleaner();
bool CanKeepTabHistory(content::WebContents* contents);
bool KeepTabHistory(content::WebContents* contents);
bool KeepTabHistoryWhenClosed(content::WebContents* contents);

}

#endif
