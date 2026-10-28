// Copyright 2026 Ray. Apache-2.0.

#ifndef CHROME_BROWSER_RAY_AC_EXTENSIONS_H_
#define CHROME_BROWSER_RAY_AC_EXTENSIONS_H_

#include "chrome/browser/ray/ac_engine.h"

AC_ENGINE_CALL(ac_extensions_list);
AC_ENGINE_CALL(ac_extensions_install);
AC_ENGINE_CALL(ac_extensions_install_crx);
AC_ENGINE_CALL(ac_extensions_set_enabled);
AC_ENGINE_CALL(ac_extensions_uninstall);
AC_ENGINE_CALL(ac_extensions_reload);
AC_ENGINE_CALL(ac_extensions_configure);

#endif
