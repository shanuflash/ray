#include "ray/linux/ac_linux_report.h"

#include <algorithm>
#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "ray/core/ac_launch_switches.h"
#include "ray/linux/ac_linux_report_core.h"
#include "base/compiler_specific.h"
#include "base/containers/span.h"
#include "base/files/file.h"
#include "base/files/file_util.h"
#include "base/functional/bind.h"
#include "base/no_destructor.h"
#include "base/task/thread_pool.h"
#include "base/time/time.h"
#include "base/uuid.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/net/system_network_context_manager.h"
#include "content/public/browser/browser_thread.h"
#include "net/base/load_flags.h"
#include "net/base/net_errors.h"
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

namespace report = ray::linux_report;

using Done = base::OnceCallback<void(bool, base::Value)>;

constexpr net::NetworkTrafficAnnotationTag kTrafficAnnotation =
    net::DefineNetworkTrafficAnnotation("ray_linux_problem_report", R"(
      semantics {
        sender: "Ray Report a Problem"
        description:
          "Sends a problem report the user wrote, and the files they chose "
          "to attach to it, to Ray's feedback service."
        trigger:
          "The user pressing Send in the Report a Problem sheet."
        user_data {
          type: USER_CONTENT
          type: OTHER
        }
        data:
          "The report's title, description, optional contact, app and "
          "system versions, diagnostics, and the attachments the user left "
          "ticked. No cookies or browsing data."
        destination: OTHER
        destination_other: "Ray's feedback service at github.com/shanuflash/ray."
        last_reviewed: "2026-11-15"
      }
      policy {
        cookies_allowed: NO
        setting: "Nothing is sent unless the user sends a report."
        policy_exception_justification: "Not implemented."
      })");

void Fail(Done done, std::string_view message) {
  std::move(done).Run(false, base::Value(base::DictValue().Set("code", report::kErrorCode).Set("message", message)));
}

base::Value Reply(int status, std::string body, std::optional<std::string> error) {
  return base::Value(base::DictValue()
      .Set("status", status)
      .Set("body", std::move(body))
      .Set("error", error ? base::Value(std::move(*error)) : base::Value()));
}

void Refuse(Done done, std::string_view why) {
  std::move(done).Run(true, Reply(0, std::string(), std::string(why)));
}

base::FilePath DraftsFolder(const base::FilePath& documents) {
  return documents.AppendASCII(report::kDraftsFolder);
}

std::optional<base::FilePath> RealPath(const base::FilePath& path) {
  base::FilePath real = base::MakeAbsoluteFilePath(path);
  if (real.empty()) return std::nullopt;
  return real;
}

std::optional<base::FilePath> ExistingDraftPath(const base::FilePath& drafts, const std::string& path) {
  if (!report::InsideDrafts(drafts.value(), path)) return std::nullopt;
  const std::optional<base::FilePath> real_drafts = RealPath(drafts);
  const std::optional<base::FilePath> real = RealPath(base::FilePath(path));
  if (!real_drafts || !real || !report::InsideDrafts(real_drafts->value(), real->value())) return std::nullopt;
  return real;
}

std::optional<base::FilePath> NewDraftPath(const base::FilePath& drafts, const std::string& path) {
  if (!report::InsideDrafts(drafts.value(), path)) return std::nullopt;
  const base::FilePath given(path);
  const std::optional<base::FilePath> real_drafts = RealPath(drafts);
  const std::optional<base::FilePath> parent = RealPath(given.DirName());
  if (!real_drafts || !parent) return std::nullopt;
  const base::FilePath real = parent->Append(given.BaseName());
  if (!report::InsideDrafts(real_drafts->value(), real.value()) || base::IsLink(real)) return std::nullopt;
  return real;
}

std::optional<std::string> CreateDraft(const base::FilePath& documents) {
  const base::FilePath drafts = DraftsFolder(documents);
  if (!base::CreateDirectory(drafts)) return std::nullopt;
  base::SetPosixFilePermissions(drafts, 0700);
  const base::FilePath draft = drafts.AppendASCII(base::Uuid::GenerateRandomV4().AsLowercaseString());
  if (!base::CreateDirectory(draft)) return std::nullopt;
  base::SetPosixFilePermissions(draft, 0700);
  return draft.value();
}

double FileSize(const base::FilePath& documents, const std::string& path) {
  const std::optional<base::FilePath> real = ExistingDraftPath(DraftsFolder(documents), path);
  if (!real || base::DirectoryExists(*real)) return -1;
  const std::optional<int64_t> size = base::GetFileSize(*real);
  return size ? static_cast<double>(*size) : -1;
}

bool RemovePath(const base::FilePath& documents, const std::string& path) {
  const base::FilePath drafts = DraftsFolder(documents);
  if (!report::InsideDrafts(drafts.value(), path)) return false;
  const base::FilePath given(path);
  const std::optional<base::FilePath> real_drafts = RealPath(drafts);
  const std::optional<base::FilePath> parent = RealPath(given.DirName());
  if (!real_drafts || !parent) return false;
  const base::FilePath real = parent->Append(given.BaseName());
  if (!report::InsideDrafts(real_drafts->value(), real.value())) return false;
  return base::DeletePathRecursively(real);
}

double GzipInto(const base::FilePath& destination, const report::GzipRead& read) {
  base::File output(destination, base::File::FLAG_CREATE_ALWAYS | base::File::FLAG_WRITE);
  if (!output.IsValid()) return -1;
  const int64_t written = report::Gzip(read, [&output](const uint8_t* data, size_t size) {
    return output.WriteAtCurrentPosAndCheck(UNSAFE_BUFFERS(base::span<const uint8_t>(data, size)));
  });
  output.Close();
  if (written < 0) {
    base::DeleteFile(destination);
    return -1;
  }
  return static_cast<double>(written);
}

double GzipFile(const base::FilePath& documents, const std::string& source, const std::string& destination, bool remove_source) {
  const base::FilePath drafts = DraftsFolder(documents);
  const std::optional<base::FilePath> from = ExistingDraftPath(drafts, source);
  const std::optional<base::FilePath> to = NewDraftPath(drafts, destination);
  if (!from || !to || *from == *to || base::DirectoryExists(*from)) return -1;
  base::File input(*from, base::File::FLAG_OPEN | base::File::FLAG_READ);
  if (!input.IsValid()) return -1;
  const double written = GzipInto(*to, [&input](uint8_t* buffer, size_t capacity) -> int64_t {
    const std::optional<size_t> count = input.ReadAtCurrentPos(UNSAFE_BUFFERS(base::span<uint8_t>(buffer, capacity)));
    return count ? static_cast<int64_t>(*count) : -1;
  });
  input.Close();
  if (written >= 0 && remove_source) base::DeleteFile(*from);
  return written;
}

double GzipText(const base::FilePath& documents, const std::string& text, const std::string& destination) {
  const std::optional<base::FilePath> to = NewDraftPath(DraftsFolder(documents), destination);
  if (!to) return -1;
  size_t offset = 0;
  return GzipInto(*to, [&text, &offset](uint8_t* buffer, size_t capacity) -> int64_t {
    const size_t count = std::min(capacity, text.size() - offset);
    UNSAFE_BUFFERS(std::copy_n(text.data() + offset, count, buffer));
    offset += count;
    return static_cast<int64_t>(count);
  });
}

struct UploadFile {
  base::FilePath path;
  int64_t bytes = -1;
};

UploadFile FindUploadFile(const base::FilePath& documents, const std::string& path) {
  const std::optional<base::FilePath> real = ExistingDraftPath(DraftsFolder(documents), path);
  if (!real || base::DirectoryExists(*real)) return {};
  return {*real, base::GetFileSize(*real).value_or(-1)};
}

scoped_refptr<network::SharedURLLoaderFactory> SystemLoaderFactory() {
  if (!g_browser_process || g_browser_process->IsShuttingDown()) return nullptr;
  SystemNetworkContextManager* manager = g_browser_process->system_network_context_manager();
  return manager ? manager->GetSharedURLLoaderFactory() : nullptr;
}

class Transfer;

std::vector<std::unique_ptr<Transfer>>& Running() {
  static base::NoDestructor<std::vector<std::unique_ptr<Transfer>>> running;
  return *running;
}

class Transfer {
 public:
  Transfer(int caller, std::string id, size_t reply_limit, LinuxReportEvent emit, Done done)
      : caller_(caller), id_(std::move(id)), reply_limit_(reply_limit), emit_(std::move(emit)), done_(std::move(done)) {}
  Transfer(const Transfer&) = delete;
  Transfer& operator=(const Transfer&) = delete;
  ~Transfer() = default;

  int caller() const { return caller_; }

  void Post(network::mojom::URLLoaderFactory* factory, const std::string& url, const std::vector<report::Header>& headers,
            std::string body) {
    Create(url, "POST", headers, report::kPostTimeoutSeconds);
    loader_->AttachStringForUpload(std::move(body), "application/json");
    Start(factory);
  }

  void Put(network::mojom::URLLoaderFactory* factory, const std::string& url, const std::vector<report::Header>& headers,
           const base::FilePath& file) {
    std::string type;
    for (const auto& [name, value] : headers) {
      if (name == "Content-Type") type = value;
    }
    Create(url, "PUT", headers, report::kUploadTimeoutSeconds);
    loader_->AttachFileForUpload(file, type);
    loader_->SetOnUploadProgressCallback(base::BindRepeating(&Transfer::OnProgress, base::Unretained(this)));
    Start(factory);
  }

  void Cancel() {
    loader_.reset();
    if (done_) std::move(done_).Run(true, Reply(0, std::string(), "cancelled"));
  }

 private:
  void Create(const std::string& url, const char* method, const std::vector<report::Header>& headers, int timeout_seconds) {
    auto request = std::make_unique<network::ResourceRequest>();
    request->url = GURL(url);
    request->method = method;
    request->credentials_mode = network::mojom::CredentialsMode::kOmit;
    request->redirect_mode = network::mojom::RedirectMode::kError;
    request->load_flags = net::LOAD_DISABLE_CACHE;
    for (const auto& [name, value] : headers) {
      if (name != "Content-Type") request->headers.SetHeader(name, value);
    }
    loader_ = network::SimpleURLLoader::Create(std::move(request), kTrafficAnnotation);
    loader_->SetTimeoutDuration(base::Seconds(timeout_seconds));
    loader_->SetAllowHttpErrorResults(true);
    loader_->SetAllowPartialResults(true);
  }

  void Start(network::mojom::URLLoaderFactory* factory) {
    loader_->DownloadToString(factory, base::BindOnce(&Transfer::OnLoaded, base::Unretained(this)), reply_limit_);
  }

  void OnProgress(uint64_t sent, uint64_t total) {
    if (!emit_) return;
    emit_.Run(base::Value(base::DictValue()
        .Set("type", "upload").Set("id", id_)
        .Set("sent", static_cast<double>(sent)).Set("total", static_cast<double>(total))));
  }

  void OnLoaded(std::optional<std::string> body) {
    const int error = loader_->NetError();
    const network::mojom::URLResponseHead* head = loader_->ResponseInfo();
    const net::HttpResponseHeaders* headers = head ? head->headers.get() : nullptr;
    const bool answered = headers && (error == net::OK || error == net::ERR_INSUFFICIENT_RESOURCES ||
                                      error == net::ERR_HTTP_RESPONSE_CODE_FAILURE);
    base::Value reply = answered
        ? Reply(headers->response_code(), report::ReplyText(body ? *body : std::string(), reply_limit_), std::nullopt)
        : Reply(0, std::string(), net::ErrorToString(error));
    Done done = std::move(done_);
    std::erase_if(Running(), [this](const std::unique_ptr<Transfer>& owned) { return owned.get() == this; });
    std::move(done).Run(true, std::move(reply));
  }

  const int caller_;
  const std::string id_;
  const size_t reply_limit_;
  LinuxReportEvent emit_;
  Done done_;
  std::unique_ptr<network::SimpleURLLoader> loader_;
};

std::optional<std::vector<report::Header>> HeadersFrom(const base::Value& value) {
  if (!value.is_dict()) return std::nullopt;
  std::vector<report::Header> headers;
  for (const auto [name, text] : value.GetDict()) {
    if (!text.is_string()) return std::nullopt;
    headers.emplace_back(name, text.GetString());
  }
  return headers;
}

Transfer* Admit(int caller, std::string id, size_t reply_limit, LinuxReportEvent emit, Done* done) {
  if (static_cast<int>(Running().size()) >= report::kMaxTransfers) {
    Refuse(std::move(*done), "Too many report transfers are running");
    return nullptr;
  }
  Running().push_back(std::make_unique<Transfer>(caller, std::move(id), reply_limit, std::move(emit), std::move(*done)));
  return Running().back().get();
}

void CancelTransfers(std::optional<int> caller) {
  std::vector<std::unique_ptr<Transfer>> cancelled;
  auto& running = Running();
  for (auto at = running.begin(); at != running.end();) {
    if (caller && (*at)->caller() != *caller) {
      ++at;
      continue;
    }
    cancelled.push_back(std::move(*at));
    at = running.erase(at);
  }
  for (auto& transfer : cancelled) transfer->Cancel();
}

void StartPost(const base::ListValue& args, int caller, Done done) {
  if (args.size() != 3 || !args[0].is_string() || !args[1].is_string()) {
    return Fail(std::move(done), "post takes a URL, a JSON body and headers");
  }
  const report::Request request = report::ClassifyUrl(report::kEndpoint, args[0].GetString());
  if (request.target != report::Target::kCreate && request.target != report::Target::kComplete) {
    return Refuse(std::move(done), "Reports go to Ray's feedback service only");
  }
  const std::optional<std::vector<report::Header>> given = HeadersFrom(args[2]);
  const auto headers = given ? report::AllowedHeaders(request.target, *given) : std::nullopt;
  if (!headers) return Refuse(std::move(done), "These headers are not sent with a report");
  if (args[1].GetString().size() > report::kJsonMaxBytes) return Refuse(std::move(done), "The report is too large");
  if (BackgroundInstance()) return Refuse(std::move(done), "Background instances send no reports");
  scoped_refptr<network::SharedURLLoaderFactory> factory = SystemLoaderFactory();
  if (!factory) return Refuse(std::move(done), "The network is unavailable");
  Transfer* transfer = Admit(caller, std::string(), report::kPostReplyMaxBytes, LinuxReportEvent(), &done);
  if (transfer) transfer->Post(factory.get(), args[0].GetString(), *headers, args[1].GetString());
}

void StartUpload(const base::ListValue& args, const base::FilePath& documents, int caller, LinuxReportEvent emit, Done done) {
  if (args.size() != 5 || !args[0].is_string() || args[0].GetString().empty() || args[0].GetString().size() > 64 ||
      !args[1].is_string() || !args[2].is_string() || !args[4].is_string()) {
    return Fail(std::move(done), "upload takes an id, a URL, a method, headers and a file path");
  }
  const report::Request request = report::ClassifyUrl(report::kEndpoint, args[1].GetString());
  if (request.target != report::Target::kFile || !report::MethodAllowed(request.target, args[2].GetString())) {
    return Refuse(std::move(done), "Report files go to Ray's feedback service only");
  }
  const std::optional<std::vector<report::Header>> given = HeadersFrom(args[3]);
  auto headers = given ? report::AllowedHeaders(request.target, *given) : std::nullopt;
  if (!headers) return Refuse(std::move(done), "These headers are not sent with a report file");
  if (BackgroundInstance()) return Refuse(std::move(done), "Background instances send no reports");
  base::ThreadPool::PostTaskAndReplyWithResult(
      FROM_HERE, {base::MayBlock(), base::TaskPriority::USER_VISIBLE},
      base::BindOnce(&FindUploadFile, documents, args[4].GetString()),
      base::BindOnce(
          [](report::Request request, std::string id, std::string url, std::vector<report::Header> headers, int caller,
             LinuxReportEvent emit, Done done, UploadFile file) {
            if (!report::UploadSizeAllowed(request, file.bytes)) {
              return Refuse(std::move(done), "The file is missing, empty, too large or outside the report's folder");
            }
            scoped_refptr<network::SharedURLLoaderFactory> factory = SystemLoaderFactory();
            if (!factory) return Refuse(std::move(done), "The network is unavailable");
            Transfer* transfer = Admit(caller, std::move(id), report::kUploadReplyMaxBytes, std::move(emit), &done);
            if (transfer) transfer->Put(factory.get(), url, headers, file.path);
          },
          request, args[0].GetString(), args[1].GetString(), std::move(*headers), caller, std::move(emit), std::move(done)));
}

void ReplyWithBytes(Done done, const char* failure, double bytes) {
  if (bytes < 0) return Fail(std::move(done), failure);
  std::move(done).Run(true, base::Value(bytes));
}

}

bool LinuxReportInvokes(std::string_view method) {
  return std::ranges::any_of(report::kReportCalls, [&](const char* known) { return method == known; });
}

void LinuxReportInvoke(std::string_view method, const base::ListValue& args, const base::FilePath& documents,
                       int caller, LinuxReportEvent emit, Done done) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  const base::TaskTraits files = {base::MayBlock(), base::TaskPriority::USER_VISIBLE,
                                  base::TaskShutdownBehavior::SKIP_ON_SHUTDOWN};
  if (method == "RayReport.cancelUploads") {
    if (!args.empty()) return Fail(std::move(done), "cancelUploads takes no arguments");
    CancelTransfers(std::nullopt);
    return std::move(done).Run(true, base::Value());
  }
  if (method == "RayReport.post") return StartPost(args, caller, std::move(done));
  if (method == "RayReport.upload") return StartUpload(args, documents, caller, std::move(emit), std::move(done));
  if (documents.empty()) return Fail(std::move(done), "The profile has no folder for report drafts");
  if (method == "RayReport.draftDirectory") {
    if (!args.empty()) return Fail(std::move(done), "draftDirectory takes no arguments");
    base::ThreadPool::PostTaskAndReplyWithResult(
        FROM_HERE, files, base::BindOnce(&CreateDraft, documents),
        base::BindOnce([](Done done, std::optional<std::string> path) {
          if (!path) return Fail(std::move(done), "The report draft folder could not be created");
          std::move(done).Run(true, base::Value(std::move(*path)));
        }, std::move(done)));
    return;
  }
  if (method == "RayReport.fileSize" || method == "RayReport.removeFile") {
    if (args.size() != 1 || !args[0].is_string()) return Fail(std::move(done), "A file path is required");
    if (method == "RayReport.fileSize") {
      base::ThreadPool::PostTaskAndReplyWithResult(
          FROM_HERE, files, base::BindOnce(&FileSize, documents, args[0].GetString()),
          base::BindOnce([](Done done, double size) { std::move(done).Run(true, base::Value(size)); }, std::move(done)));
      return;
    }
    base::ThreadPool::PostTaskAndReplyWithResult(
        FROM_HERE, files, base::BindOnce(&RemovePath, documents, args[0].GetString()),
        base::BindOnce([](Done done, bool) { std::move(done).Run(true, base::Value()); }, std::move(done)));
    return;
  }
  if (method == "RayReport.gzipFile") {
    if (args.size() != 3 || !args[0].is_string() || !args[1].is_string() || !args[2].is_bool()) {
      return Fail(std::move(done), "gzipFile takes a source, a destination and whether to remove the source");
    }
    base::ThreadPool::PostTaskAndReplyWithResult(
        FROM_HERE, files, base::BindOnce(&GzipFile, documents, args[0].GetString(), args[1].GetString(), args[2].GetBool()),
        base::BindOnce(&ReplyWithBytes, std::move(done), "The file could not be compressed inside the report's folder"));
    return;
  }
  if (method == "RayReport.gzipText") {
    if (args.size() != 2 || !args[0].is_string() || !args[1].is_string() ||
        args[0].GetString().size() > report::kTextMaxBytes) {
      return Fail(std::move(done), "gzipText takes text and a destination");
    }
    base::ThreadPool::PostTaskAndReplyWithResult(
        FROM_HERE, files, base::BindOnce(&GzipText, documents, args[0].GetString(), args[1].GetString()),
        base::BindOnce(&ReplyWithBytes, std::move(done), "The text could not be compressed inside the report's folder"));
    return;
  }
  Fail(std::move(done), "Unknown report call");
}

void LinuxReportCallerGone(int caller) {
  CancelTransfers(caller);
}

}
