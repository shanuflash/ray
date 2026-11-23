// Copyright 2026 Ray. Apache-2.0.

#include "chrome/browser/ray/ac_engine.h"

#include "base/values.h"
#include "chrome/browser/predictors/loading_predictor.h"
#include "chrome/browser/predictors/loading_predictor_config.h"
#include "chrome/browser/predictors/loading_predictor_factory.h"
#include "services/network/public/cpp/constants.h"
#include "url/gurl.h"
#include "url/url_constants.h"

// The command bar's top row while the user types, as Chrome's omnibox does with its default match
// (ChromeOmniboxClient::DoPreconnect): DNS, connect and TLS start before Enter. Args: {"url": "https://host/"}.
// Replies {"started": bool}: false when network prediction is off (Chrome's own gate, which the preconnect
// manager checks too). Never for a private session: Chrome makes no loading predictor there.
AC_PROFILE_CALL(ac_preconnect) {
  GURL url(call.String("url"));
  if (!url.is_valid() ||
      !(url.SchemeIs(url::kHttpsScheme) || url.SchemeIs(url::kHttpScheme))) {
    return call.TakeReply().Error("http(s) url required");
  }
  predictors::LoadingPredictor* predictor =
      predictors::LoadingPredictorFactory::GetForProfile(call.profile());
  if (!predictor || !predictors::IsPreconnectAllowed(call.profile())) {
    return call.TakeReply().Send(base::DictValue().Set("started", false));
  }
  predictor->PrepareForPageLoad(
      /*initiator_origin=*/std::nullopt, url.DeprecatedGetOriginAsURL(),
      predictors::HintOrigin::OMNIBOX, network::GetNoOpNetworkRestrictionsId(),
      /*preconnectable=*/true);
  call.TakeReply().Send(base::DictValue().Set("started", true));
}
