// Copyright 2026 Ray. Apache-2.0.

#ifndef CHROME_BROWSER_RAY_AC_AUTOFILL_H_
#define CHROME_BROWSER_RAY_AC_AUTOFILL_H_

#include "chrome/browser/ray/ac_engine.h"

AC_ENGINE_CALL(ac_autofill_addresses);
AC_ENGINE_CALL(ac_autofill_save_address);
AC_ENGINE_CALL(ac_autofill_cards);
AC_ENGINE_CALL(ac_autofill_save_card);
AC_ENGINE_CALL(ac_autofill_remove);
AC_ENGINE_CALL(ac_autofill_card_number);
AC_ENGINE_CALL(ac_autofill_import);

#endif
