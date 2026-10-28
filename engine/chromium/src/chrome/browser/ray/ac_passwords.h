// Copyright 2026 Ray. Apache-2.0.

#ifndef CHROME_BROWSER_RAY_AC_PASSWORDS_H_
#define CHROME_BROWSER_RAY_AC_PASSWORDS_H_

#include "chrome/browser/ray/ac_engine.h"

AC_ENGINE_CALL(ac_passwords_list);
AC_ENGINE_CALL(ac_passwords_unlock);
AC_ENGINE_CALL(ac_passwords_reveal);
AC_ENGINE_CALL(ac_passwords_add);
AC_ENGINE_CALL(ac_passwords_update);
AC_ENGINE_CALL(ac_passwords_remove);
AC_ENGINE_CALL(ac_passwords_exceptions);
AC_ENGINE_CALL(ac_passwords_allow);
AC_ENGINE_CALL(ac_passwords_export);

#endif
