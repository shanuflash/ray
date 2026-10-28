// Copyright 2026 Ray. Apache-2.0.

#include "chrome/browser/ray/ac_omnibox.h"

#include "base/values.h"

AC_ENGINE_CALL(ac_omnibox_opened) {
  ray::Call call(profile_dir, args_json, reply, context);
  if (!call) {
    return;
  }
  call.TakeReply().Send(base::DictValue().Set("prewarm", 2));
}
