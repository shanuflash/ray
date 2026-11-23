#include "ray/linux/ac_linux_bang_list.h"

#include <algorithm>
#include <memory>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "ray/core/ac_launch_switches.h"
#include "ray/linux/ac_linux_bang_list_policy.h"
#include "base/functional/bind.h"
#include "base/no_destructor.h"
#include "base/strings/string_util.h"
#include "base/task/sequenced_task_runner.h"
#include "base/time/time.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/net/system_network_context_manager.h"
#include "content/public/browser/browser_thread.h"
#include "net/base/load_flags.h"
#include "net/base/net_errors.h"
#include "net/http/http_request_headers.h"
#include "net/http/http_response_headers.h"
#include "net/traffic_annotation/network_traffic_annotation.h"
#include "services/network/public/cpp/resource_request.h"
#include "services/network/public/cpp/shared_url_loader_factory.h"
#include "services/network/public/cpp/simple_url_loader.h"
#include "services/network/public/mojom/fetch_api.mojom.h"
#include "services/network/public/mojom/url_response_head.mojom.h"
#include "url/gurl.h"

namespace raycore {

namespace {

namespace bang_list = ray::linux_bang_list;

using Done = base::OnceCallback<void(bool, base::Value)>;

constexpr net::NetworkTrafficAnnotationTag kTrafficAnnotation =
    net::DefineNetworkTrafficAnnotation("ray_linux_bang_list", R"(
      semantics {
        sender: "Ray search shortcuts"
        description:
          "Fetches the list of search shortcuts (bangs) the address bar "
          "understands, so the list bundled with the app can be brought up "
          "to date."
        trigger:
          "The browser checking for a newer list, at most about once a day."
        user_data {
          type: NONE
        }
        data:
          "The ETag of the list the browser already has. No cookies, "
          "credentials or browsing data."
        destination: OTHER
        destination_other: "The Helium services host that publishes the list."
        last_reviewed: "2026-11-14"
      }
      policy {
        cookies_allowed: NO
        setting: "This request cannot be turned off in settings."
        policy_exception_justification: "Not implemented."
      })");

void Fail(Done done, std::string_view message) {
  std::move(done).Run(false, base::Value(base::DictValue().Set("code", bang_list::kErrorCode).Set("message", message)));
}

base::Value OrNull(std::optional<std::string> text) {
  return text && base::IsStringUTF8(*text) ? base::Value(std::move(*text)) : base::Value();
}

scoped_refptr<network::SharedURLLoaderFactory> SystemLoaderFactory() {
  if (!g_browser_process || g_browser_process->IsShuttingDown()) return nullptr;
  SystemNetworkContextManager* manager = g_browser_process->system_network_context_manager();
  return manager ? manager->GetSharedURLLoaderFactory() : nullptr;
}

class Fetch;

std::vector<std::unique_ptr<Fetch>>& Running() {
  static base::NoDestructor<std::vector<std::unique_ptr<Fetch>>> running;
  return *running;
}

class Fetch {
 public:
  explicit Fetch(Done done) : done_(std::move(done)) {}
  Fetch(const Fetch&) = delete;
  Fetch& operator=(const Fetch&) = delete;
  ~Fetch() = default;

  void Load(network::mojom::URLLoaderFactory* factory, const std::string& etag) {
    auto request = std::make_unique<network::ResourceRequest>();
    request->url = GURL(bang_list::kListUrl);
    request->method = "GET";
    request->credentials_mode = network::mojom::CredentialsMode::kOmit;
    request->redirect_mode = network::mojom::RedirectMode::kError;
    request->load_flags = net::LOAD_DISABLE_CACHE;
    request->headers.SetHeader(net::HttpRequestHeaders::kAccept, "application/json");
    if (bang_list::EtagSent(etag)) request->headers.SetHeader(net::HttpRequestHeaders::kIfNoneMatch, etag);
    loader_ = network::SimpleURLLoader::Create(std::move(request), kTrafficAnnotation);
    loader_->SetTimeoutDuration(base::Seconds(bang_list::kTimeoutSeconds));
    loader_->SetAllowHttpErrorResults(true);
    loader_->DownloadToString(factory, base::BindOnce(&Fetch::OnLoaded, base::Unretained(this)), bang_list::kMaxBytes);
  }

 private:
  void OnLoaded(std::optional<std::string> body) {
    const int error = loader_->NetError();
    const network::mojom::URLResponseHead* head = loader_->ResponseInfo();
    const net::HttpResponseHeaders* headers = head ? head->headers.get() : nullptr;
    const int status = headers ? headers->response_code() : 0;
    const bang_list::Failure failure = bang_list::Judge(
        error == net::OK, headers != nullptr, body.has_value(), error == net::ERR_INSUFFICIENT_RESOURCES,
        body && base::IsStringUTF8(*body), status);
    base::Value reply;
    if (failure == bang_list::Failure::kNone) {
      const int bytes = body ? static_cast<int>(body->size()) : 0;
      reply = base::Value(base::DictValue()
          .Set("status", status)
          .Set("etag", OrNull(headers->GetNormalizedHeader("ETag")))
          .Set("contentType", OrNull(headers->GetNormalizedHeader("Content-Type")))
          .Set("body", bang_list::BodyReturned(status) ? OrNull(std::move(body)) : base::Value())
          .Set("bytes", bytes));
    }
    Done done = std::move(done_);
    std::erase_if(Running(), [this](const std::unique_ptr<Fetch>& owned) { return owned.get() == this; });
    if (failure != bang_list::Failure::kNone) return Fail(std::move(done), bang_list::FailureMessage(failure));
    std::move(done).Run(true, std::move(reply));
  }

  Done done_;
  std::unique_ptr<network::SimpleURLLoader> loader_;
};

}

void FetchLinuxBangList(const base::ListValue& args, Done done) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (args.size() > 1 || (args.size() == 1 && !args[0].is_string() && !args[0].is_none())) {
    return Fail(std::move(done), "fetchBangList takes an ETag or null");
  }
  if (BackgroundInstance()) return Fail(std::move(done), "Background instances keep the bundled bang list");
  if (!bang_list::Admits(static_cast<int>(Running().size()))) return Fail(std::move(done), "A bang list fetch is already running");
  scoped_refptr<network::SharedURLLoaderFactory> factory = SystemLoaderFactory();
  if (!factory) return Fail(std::move(done), "The network is unavailable");
  const std::string etag = args.size() == 1 && args[0].is_string() ? args[0].GetString() : std::string();
  Running().push_back(std::make_unique<Fetch>(std::move(done)));
  Running().back()->Load(factory.get(), etag);
}

}
