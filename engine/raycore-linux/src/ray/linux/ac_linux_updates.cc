#include "ray/linux/ac_linux_updates.h"

#include <memory>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "base/command_line.h"
#include "base/environment.h"
#include "base/functional/bind.h"
#include "base/no_destructor.h"
#include "base/task/sequenced_task_runner.h"
#include "base/time/time.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/net/system_network_context_manager.h"
#include "chrome/common/chrome_switches.h"
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

namespace ray::linux_updates {
namespace {

namespace policy = ray::linux_updates_policy;
using policy::Source;

constexpr net::NetworkTrafficAnnotationTag kTrafficAnnotation =
    net::DefineNetworkTrafficAnnotation("ray_linux_update_check", R"(
      semantics {
        sender: "Ray update check"
        description:
          "Reads Ray's published release list from GitHub to tell the "
          "user when a newer Linux package exists, and Ray's remote "
          "feature switches from github.com/shanuflash/ray."
        trigger:
          "Check for Updates, and automatic checks 30 seconds after launch "
          "and every 6 hours while automatic update checks are on."
        user_data {
          type: NONE
        }
        data: "None. A GET of two fixed public URLs."
        destination: OTHER
        destination_other: "api.github.com and github.com/shanuflash/ray."
        last_reviewed: "2026-11-15"
      }
      policy {
        cookies_allowed: NO
        setting: "Settings > General > Check for updates automatically."
        policy_exception_justification: "Not implemented."
      })");

struct Fetched {
  int status = 0;
  std::string body;
};

struct SwitchesCache {
  std::optional<Fetched> fetched;
  std::vector<FetchReply> waiting;
  bool loading = false;
};

SwitchesCache& Switches() {
  static base::NoDestructor<SwitchesCache> cache;
  return *cache;
}

class Load;

std::vector<std::unique_ptr<Load>>& InFlight() {
  static base::NoDestructor<std::vector<std::unique_ptr<Load>>> loads;
  return *loads;
}

void Answer(FetchReply reply, int status, std::string body) {
  base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(std::move(reply), status, std::move(body)));
}

scoped_refptr<network::SharedURLLoaderFactory> SystemLoaderFactory() {
  if (!g_browser_process || g_browser_process->IsShuttingDown()) {
    return nullptr;
  }
  SystemNetworkContextManager* manager =
      g_browser_process->system_network_context_manager();
  return manager ? manager->GetSharedURLLoaderFactory() : nullptr;
}

void Finished(Source source, Fetched fetched);

GURL RequestUrl(Source source) {
  if (source == Source::kReleases && UpdateFeed()) {
    return GURL(linux_self_update_policy::ReleasesUrl(*UpdateFeed()));
  }
  return GURL(policy::UrlFor(source));
}

class Load {
 public:
  explicit Load(Source source) : source_(source) {}
  Load(const Load&) = delete;
  Load& operator=(const Load&) = delete;

  void Start(network::mojom::URLLoaderFactory* factory) {
    auto request = std::make_unique<network::ResourceRequest>();
    request->url = RequestUrl(source_);
    request->method = "GET";
    request->credentials_mode = network::mojom::CredentialsMode::kOmit;
    request->redirect_mode = network::mojom::RedirectMode::kError;
    request->load_flags = net::LOAD_DISABLE_CACHE;
    request->headers.SetHeader(net::HttpRequestHeaders::kAccept,
                               source_ == Source::kReleases
                                   ? "application/vnd.github+json"
                                   : "application/json");
    loader_ = network::SimpleURLLoader::Create(std::move(request),
                                               kTrafficAnnotation);
    loader_->SetTimeoutDuration(base::Seconds(policy::kTimeoutSeconds));
    loader_->DownloadToString(
        factory, base::BindOnce(&Load::OnLoaded, base::Unretained(this)),
        policy::MaxBytesFor(source_));
  }

 private:
  void OnLoaded(std::optional<std::string> body) {
    const auto* head = loader_->ResponseInfo();
    const int http_status =
        head && head->headers ? head->headers->response_code() : 0;
    Fetched fetched;
    fetched.status = policy::ReportedStatus(loader_->NetError() == net::OK,
                                            http_status, body.has_value());
    if (fetched.status) fetched.body = std::move(*body);
    const Source source = source_;
    auto& loads = InFlight();
    std::unique_ptr<Load> self;
    for (auto it = loads.begin(); it != loads.end(); ++it) {
      if (it->get() == this) {
        self = std::move(*it);
        loads.erase(it);
        break;
      }
    }
    Finished(source, std::move(fetched));
  }

  Source source_;
  std::unique_ptr<network::SimpleURLLoader> loader_;
};

std::vector<FetchReply>& ReleaseWaiters() {
  static base::NoDestructor<std::vector<FetchReply>> waiters;
  return *waiters;
}

void Finished(Source source, Fetched fetched) {
  if (source == Source::kKillSwitches) {
    SwitchesCache& cache = Switches();
    cache.loading = false;
    if (policy::CachesForProcess(source, fetched.status)) cache.fetched = fetched;
    std::vector<FetchReply> waiting = std::move(cache.waiting);
    for (FetchReply& reply : waiting) Answer(std::move(reply), fetched.status, fetched.body);
    return;
  }
  std::vector<FetchReply> waiting = std::move(ReleaseWaiters());
  ReleaseWaiters().clear();
  for (FetchReply& reply : waiting) Answer(std::move(reply), fetched.status, fetched.body);
}

bool StartLoading(Source source) {
  if (!policy::AdmitFetch(static_cast<int>(InFlight().size()))) return false;
  scoped_refptr<network::SharedURLLoaderFactory> factory = SystemLoaderFactory();
  if (!factory) return false;
  auto load = std::make_unique<Load>(source);
  Load* started = load.get();
  InFlight().push_back(std::move(load));
  started->Start(factory.get());
  return true;
}

}

const std::optional<linux_self_update_policy::Feed>& UpdateFeed() {
  static const base::NoDestructor<std::optional<linux_self_update_policy::Feed>> feed([] {
    const auto environment = base::Environment::Create();
    const bool isolated = base::CommandLine::ForCurrentProcess()->HasSwitch(switches::kUserDataDir) ||
                          !environment->GetVar("RAY_DATA_DIR").value_or("").empty();
    if (!isolated) return std::optional<linux_self_update_policy::Feed>();
    return linux_self_update_policy::FeedOverride(environment->GetVar("RAY_UPDATE_FEED").value_or(""));
  }());
  return *feed;
}

void Fetch(Source source, FetchReply reply) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (source == Source::kKillSwitches) {
    SwitchesCache& cache = Switches();
    if (cache.fetched) {
      return Answer(std::move(reply), cache.fetched->status, cache.fetched->body);
    }
    cache.waiting.push_back(std::move(reply));
    if (cache.loading) return;
    cache.loading = true;
    if (!StartLoading(source)) Finished(source, Fetched());
    return;
  }
  ReleaseWaiters().push_back(std::move(reply));
  if (ReleaseWaiters().size() > 1) return;
  if (!StartLoading(source)) Finished(source, Fetched());
}

}
