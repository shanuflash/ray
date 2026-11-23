#include "ray/linux/ac_linux_self_update.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <sys/stat.h>
#include <unistd.h>

#include <memory>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "ray/linux/ac_linux_launch_config.h"
#include "ray/linux/ac_linux_updates.h"
#include "base/command_line.h"
#include "base/environment.h"
#include "base/files/file_enumerator.h"
#include "base/files/file_path.h"
#include "base/files/file_util.h"
#include "base/files/scoped_file.h"
#include "base/functional/bind.h"
#include "base/logging.h"
#include "base/memory/weak_ptr.h"
#include "base/no_destructor.h"
#include "base/posix/eintr_wrapper.h"
#include "base/path_service.h"
#include "base/process/kill.h"
#include "base/process/launch.h"
#include "base/process/process.h"
#include "base/system/sys_info.h"
#include "base/task/sequenced_task_runner.h"
#include "base/task/single_thread_task_runner.h"
#include "base/task/thread_pool.h"
#include "base/threading/scoped_blocking_call.h"
#include "base/time/time.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/lifetime/application_lifetime.h"
#include "chrome/browser/net/system_network_context_manager.h"
#include "chrome/common/chrome_paths.h"
#include "content/public/browser/browser_thread.h"
#include "net/base/load_flags.h"
#include "net/base/net_errors.h"
#include "net/http/http_request_headers.h"
#include "net/traffic_annotation/network_traffic_annotation.h"
#include "net/url_request/redirect_info.h"
#include "services/network/public/cpp/resource_request.h"
#include "services/network/public/cpp/shared_url_loader_factory.h"
#include "services/network/public/cpp/simple_url_loader.h"
#include "services/network/public/mojom/fetch_api.mojom.h"
#include "services/network/public/mojom/url_response_head.mojom.h"
#include "url/gurl.h"

namespace ray::linux_self_update {
namespace {

namespace policy = ray::linux_self_update_policy;
using Done = base::OnceCallback<void(bool, base::Value)>;
using policy::Kind;

constexpr net::NetworkTrafficAnnotationTag kTrafficAnnotation =
    net::DefineNetworkTrafficAnnotation("ray_linux_update_download", R"(
      semantics {
        sender: "Ray Linux self-update"
        description:
          "Downloads a newer Ray release for Linux from GitHub: its signed "
          "update manifest, the manifest's signature and the package for "
          "the way Ray is installed (.deb, tarball or AppImage), so Ray "
          "can install it and finish the update on restart."
        trigger:
          "A newer release found by Check for Updates, or by an automatic "
          "check while automatic updates are on."
        user_data {
          type: NONE
        }
        data: "None. GETs of public release assets."
        destination: OTHER
        destination_other:
          "github.com and GitHub's release asset hosts "
          "(objects.githubusercontent.com, "
          "release-assets.githubusercontent.com)."
        last_reviewed: "2026-11-20"
      }
      policy {
        cookies_allowed: NO
        setting: "Settings > General > Automatically update Ray."
        policy_exception_justification: "Not implemented."
      })");

constexpr base::TimeDelta kKillGrace = base::Seconds(5);
constexpr base::TimeDelta kDrainLimit = base::Seconds(5);
constexpr base::TimeDelta kReapLimit = base::Seconds(5);
constexpr int kPollMilliseconds = 250;
constexpr size_t kOutputLimit = 64 * 1024;

std::string Text(std::string_view text) {
  return std::string(text);
}

base::FilePath HelperPath() {
  return raycore::LinuxPackage().directory.Append(Text(policy::kHelperName));
}

base::FilePath UpdatesDirectory() {
  base::FilePath user_data_directory;
  if (!base::PathService::Get(chrome::DIR_USER_DATA, &user_data_directory)) return base::FilePath();
  return user_data_directory.Append(Text(policy::kUpdatesFolder));
}

std::optional<std::string> AppImagePath() {
  const auto value = base::Environment::Create()->GetVar("APPIMAGE");
  if (!value || value->empty() || value->front() != '/') return std::nullopt;
  return value;
}

bool ExecutableFile(const base::FilePath& path) {
  struct stat info;
  return stat(path.value().c_str(), &info) == 0 && S_ISREG(info.st_mode) && access(path.value().c_str(), X_OK) == 0;
}

struct ChildRun {
  bool launched = false;
  bool timed_out = false;
  int exit_code = -1;
  std::string output;
};

ChildRun RunChild(const std::vector<std::string>& arguments, base::EnvironmentMap environment,
                  base::TimeDelta limit, bool lets_pkexec_gain_root = false) {
  ChildRun run;
  int output[2];
  if (pipe2(output, O_CLOEXEC) != 0) return run;
  base::ScopedFD output_read(output[0]);
  base::ScopedFD output_write(output[1]);
  base::ScopedFD null_device(HANDLE_EINTR(open("/dev/null", O_WRONLY | O_CLOEXEC)));
  if (!null_device.is_valid()) return run;

  base::LaunchOptions options;
  options.clear_environment = true;
  options.environment = std::move(environment);
  options.current_directory = base::FilePath("/");
  options.fds_to_remap.emplace_back(output_write.get(), STDOUT_FILENO);
  options.fds_to_remap.emplace_back(null_device.get(), STDERR_FILENO);
  options.new_process_group = true;
  options.allow_new_privs = lets_pkexec_gain_root;
  base::Process process = base::LaunchProcess(arguments, options);
  output_write.reset();
  null_device.reset();
  if (!process.IsValid()) return run;
  run.launched = true;

  const pid_t group = process.Pid();
  const base::TimeTicks deadline = base::TimeTicks::Now() + limit;
  const base::TimeTicks drain_end = deadline + kKillGrace + kDrainLimit;
  std::optional<base::TimeTicks> kill_at;
  std::optional<base::TimeTicks> exited_at;
  std::optional<int> exit_code;
  std::string buffer(16384, '\0');
  while (true) {
    int ready = 0;
    if (output_read.is_valid()) {
      pollfd watched{output_read.get(), POLLIN, 0};
      ready = poll(&watched, 1, kPollMilliseconds);
      if (ready < 0 && errno != EINTR) break;
      if (ready > 0 && (watched.revents & (POLLIN | POLLHUP | POLLERR))) {
        const ssize_t got = HANDLE_EINTR(read(output_read.get(), buffer.data(), buffer.size()));
        if (got > 0) {
          run.output.append(buffer.data(), static_cast<size_t>(got));
          if (run.output.size() > kOutputLimit) run.output.erase(0, run.output.size() - kOutputLimit);
        } else if (got == 0 || errno != EAGAIN) {
          output_read.reset();
        }
      }
    } else {
      poll(nullptr, 0, kPollMilliseconds);
    }
    const base::TimeTicks now = base::TimeTicks::Now();
    if (!exit_code) {
      int code = 0;
      if (process.WaitForExitWithTimeout(base::TimeDelta(), &code)) {
        exit_code = code;
        exited_at = now;
      }
    }
    if (exit_code && (!output_read.is_valid() || ready == 0)) break;
    if (exited_at && now - *exited_at >= kDrainLimit) break;
    if (now >= drain_end) break;
    if (!kill_at && now >= deadline) {
      run.timed_out = true;
      kill(-group, SIGTERM);
      kill_at = now + kKillGrace;
    } else if (kill_at && now >= *kill_at) {
      kill(-group, SIGKILL);
      kill_at = drain_end;
    }
  }
  if (run.timed_out) kill(-group, SIGKILL);
  if (!exit_code) {
    int code = 0;
    kill(-group, SIGKILL);
    if (process.WaitForExitWithTimeout(kReapLimit, &code)) {
      exit_code = code;
    } else {
      base::EnsureProcessGetsReaped(std::move(process));
    }
  }
  run.exit_code = exit_code.value_or(-1);
  return run;
}

base::EnvironmentMap HelperEnvironment(const std::optional<std::string>& appimage) {
  base::EnvironmentMap environment;
  environment["PATH"] = Text(policy::kHelperSearchPath);
  environment["LC_ALL"] = "C";
  if (!appimage) return environment;
  environment["APPIMAGE"] = *appimage;
  const auto mount = base::Environment::Create()->GetVar("APPDIR");
  if (mount && !mount->empty() && mount->front() == '/') environment["APPDIR"] = *mount;
  return environment;
}

std::string ReadKind(base::FilePath helper, std::optional<std::string> appimage) {
  base::ScopedBlockingCall blocking(FROM_HERE, base::BlockingType::WILL_BLOCK);
  if (!ExecutableFile(helper)) return Text(policy::kNoHelper);
  const ChildRun run = RunChild({helper.value(), "kind"}, HelperEnvironment(appimage),
                                base::Seconds(policy::kKindDeadlineSeconds));
  const std::string_view line = policy::LastLine(run.output);
  if (!run.launched || run.timed_out || run.exit_code != 0 || !policy::ValidKindLine(line)) {
    LOG(WARNING) << "ray-update kind didn't answer (exit " << run.exit_code << ")";
    return Text(policy::kHelperFailed);
  }
  return Text(line);
}

std::optional<base::FilePath> Pkexec() {
  for (const std::string_view path : policy::kPkexecPaths) {
    const base::FilePath candidate(path);
    if (ExecutableFile(candidate)) return candidate;
  }
  return std::nullopt;
}

policy::InstallOutcome RunInstall(base::FilePath helper, Kind kind, base::FilePath directory, std::string version,
                                  std::optional<std::string> appimage) {
  base::ScopedBlockingCall blocking(FROM_HERE, base::BlockingType::WILL_BLOCK);
  if (!base::DirectoryExists(directory) || !base::PathExists(directory.Append(policy::ManifestName(version))) ||
      !base::PathExists(directory.Append(policy::SignatureName(version)))) {
    return {false, Text(policy::kMissingReason)};
  }
  if (!ExecutableFile(helper)) return {false, Text(policy::kKindReason)};
  std::vector<std::string> arguments;
  const bool through_pkexec = policy::ThroughPkexec(kind);
  if (through_pkexec) {
    const std::optional<base::FilePath> pkexec = Pkexec();
    if (!pkexec) return {false, Text(policy::kPolkitReason)};
    arguments.push_back(pkexec->value());
    arguments.push_back("--disable-internal-agent");
  } else if (!appimage) {
    return {false, Text(policy::kKindReason)};
  }
  arguments.push_back(helper.value());
  arguments.push_back("install");
  arguments.push_back(directory.value());
  const ChildRun run = RunChild(arguments, HelperEnvironment(through_pkexec ? std::nullopt : appimage),
                                base::Seconds(policy::kInstallDeadlineSeconds), through_pkexec);
  if (!run.launched) return {false, Text(policy::kInstallReason)};
  policy::InstallOutcome outcome = policy::InstallOutcomeFor(version, run.timed_out, run.exit_code,
                                                             policy::LastLine(run.output), through_pkexec);
  if (outcome.ok || policy::DiscardsDownload(outcome.detail)) base::DeletePathRecursively(directory);
  if (!outcome.ok) {
    LOG(WARNING) << "ray-update install failed: " << outcome.detail << " (exit " << run.exit_code << ")";
  }
  return outcome;
}

bool RealDirectory(const base::FilePath& path) {
  struct stat info;
  return lstat(path.value().c_str(), &info) == 0 && S_ISDIR(info.st_mode);
}

bool Missing(const base::FilePath& path) {
  struct stat info;
  return lstat(path.value().c_str(), &info) != 0 && errno == ENOENT;
}

bool EnsureRealDirectory(const base::FilePath& path) {
  if (Missing(path) && !base::CreateDirectory(path)) return false;
  return RealDirectory(path);
}

struct Prepared {
  std::string reason;
  bool complete = false;
};

std::optional<policy::Package> CompleteDownload(const base::FilePath& directory, const std::string& version,
                                                Kind kind) {
  std::string manifest;
  if (!base::ReadFileToStringWithMaxSize(directory.Append(policy::ManifestName(version)), &manifest,
                                         policy::kMaxManifestBytes)) {
    return std::nullopt;
  }
  const policy::ManifestRead read = policy::PackageInManifest(manifest, version, kind);
  if (!read.package) return std::nullopt;
  const std::optional<int64_t> signature = base::GetFileSize(directory.Append(policy::SignatureName(version)));
  const std::optional<int64_t> package = base::GetFileSize(directory.Append(read.package->name));
  if (!signature || *signature != static_cast<int64_t>(policy::kSignatureBytes)) return std::nullopt;
  if (!package || *package != static_cast<int64_t>(read.package->size)) return std::nullopt;
  return read.package;
}

Prepared PrepareDirectory(base::FilePath updates, std::string version, Kind kind) {
  base::ScopedBlockingCall blocking(FROM_HERE, base::BlockingType::MAY_BLOCK);
  Prepared prepared;
  if (updates.empty() || !EnsureRealDirectory(updates)) {
    prepared.reason = Text(policy::kDiskReason);
    return prepared;
  }
  base::FileEnumerator entries(updates, false,
                               base::FileEnumerator::FILES | base::FileEnumerator::DIRECTORIES |
                                   base::FileEnumerator::SHOW_SYM_LINKS);
  for (base::FilePath entry = entries.Next(); !entry.empty(); entry = entries.Next()) {
    const std::string name = entry.BaseName().value();
    if (name != version && policy::ValidVersion(name)) base::DeletePathRecursively(entry);
  }
  const base::FilePath directory = updates.Append(version);
  if (base::IsLink(directory)) base::DeleteFile(directory);
  if (base::DirectoryExists(directory) && CompleteDownload(directory, version, kind)) {
    prepared.complete = true;
    return prepared;
  }
  base::DeletePathRecursively(directory);
  if (!base::CreateDirectory(directory)) prepared.reason = Text(policy::kDiskReason);
  return prepared;
}

struct ManifestChecked {
  std::optional<policy::Package> package;
  std::string reason;
};

ManifestChecked CheckManifest(base::FilePath directory, std::string version, Kind kind) {
  base::ScopedBlockingCall blocking(FROM_HERE, base::BlockingType::MAY_BLOCK);
  ManifestChecked checked;
  std::string manifest;
  if (!base::ReadFileToStringWithMaxSize(directory.Append(policy::ManifestName(version)), &manifest,
                                         policy::kMaxManifestBytes)) {
    checked.reason = Text(policy::kManifestReason);
    return checked;
  }
  const std::optional<int64_t> signature = base::GetFileSize(directory.Append(policy::SignatureName(version)));
  if (!signature || *signature != static_cast<int64_t>(policy::kSignatureBytes)) {
    checked.reason = Text(policy::kManifestReason);
    return checked;
  }
  policy::ManifestRead read = policy::PackageInManifest(manifest, version, kind);
  if (!read.package) {
    checked.reason = Text(read.reason);
    return checked;
  }
  const std::optional<int64_t> free_space = base::SysInfo::AmountOfFreeDiskSpace(directory);
  if (!free_space || static_cast<uint64_t>(*free_space) < read.package->size + policy::kDiskHeadroomBytes) {
    checked.reason = Text(policy::kDiskReason);
    return checked;
  }
  checked.package = std::move(read.package);
  return checked;
}

bool PackageSizeMatches(base::FilePath path, uint64_t size) {
  base::ScopedBlockingCall blocking(FROM_HERE, base::BlockingType::MAY_BLOCK);
  const std::optional<int64_t> actual = base::GetFileSize(path);
  return actual && *actual == static_cast<int64_t>(size);
}

void RemoveDirectory(base::FilePath directory) {
  base::ScopedBlockingCall blocking(FROM_HERE, base::BlockingType::MAY_BLOCK);
  base::DeletePathRecursively(directory);
}

scoped_refptr<network::SharedURLLoaderFactory> SystemLoaderFactory() {
  if (!g_browser_process || g_browser_process->IsShuttingDown()) return nullptr;
  SystemNetworkContextManager* manager = g_browser_process->system_network_context_manager();
  return manager ? manager->GetSharedURLLoaderFactory() : nullptr;
}

constexpr base::TaskTraits kFileTraits = {base::MayBlock(), base::TaskPriority::USER_VISIBLE,
                                          base::TaskShutdownBehavior::SKIP_ON_SHUTDOWN};

class PackageDownload {
 public:
  using Finish = base::OnceCallback<void(std::string reason)>;

  PackageDownload(std::string version, Kind kind, base::FilePath updates, Finish finish)
      : version_(std::move(version)),
        kind_(kind),
        updates_(std::move(updates)),
        directory_(updates_.Append(version_)),
        finish_(std::move(finish)) {}
  PackageDownload(const PackageDownload&) = delete;
  PackageDownload& operator=(const PackageDownload&) = delete;

  void Start() {
    base::ThreadPool::PostTaskAndReplyWithResult(
        FROM_HERE, kFileTraits, base::BindOnce(&PrepareDirectory, updates_, version_, kind_),
        base::BindOnce(&PackageDownload::OnPrepared, weak_factory_.GetWeakPtr()));
  }

 private:
  enum class Step { kManifest, kSignature, kPackage };

  void OnPrepared(Prepared prepared) {
    if (!prepared.reason.empty()) return Complete(prepared.reason);
    if (prepared.complete) return Succeed();
    Fetch(Step::kManifest, policy::ManifestName(version_), policy::kMaxManifestBytes);
  }

  void Fetch(Step step, const std::string& name, uint64_t max_bytes) {
    scoped_refptr<network::SharedURLLoaderFactory> factory = SystemLoaderFactory();
    if (!factory) return Fail(policy::kNetworkReason);
    step_ = step;
    auto request = std::make_unique<network::ResourceRequest>();
    request->url = GURL(policy::DownloadUrl(version_, name, linux_updates::UpdateFeed()));
    request->method = "GET";
    request->credentials_mode = network::mojom::CredentialsMode::kOmit;
    request->redirect_mode = network::mojom::RedirectMode::kFollow;
    request->load_flags = net::LOAD_DISABLE_CACHE;
    request->headers.SetHeader(net::HttpRequestHeaders::kAccept, "application/octet-stream");
    loader_ = network::SimpleURLLoader::Create(std::move(request), kTrafficAnnotation);
    loader_->SetTimeoutDuration(base::Seconds(step == Step::kPackage ? policy::kPackageTimeoutSeconds
                                                                     : policy::kSmallFileTimeoutSeconds));
    loader_->SetOnRedirectCallback(base::BindRepeating(&PackageDownload::OnRedirect, weak_factory_.GetWeakPtr()));
    loader_->DownloadToFile(factory.get(), base::BindOnce(&PackageDownload::OnFetched, weak_factory_.GetWeakPtr()),
                            directory_.Append(name), static_cast<int64_t>(max_bytes));
  }

  void OnRedirect(const GURL& url_before_redirect, const net::RedirectInfo& redirect_info,
                  const network::mojom::URLResponseHead& response_head, std::vector<std::string>* removed_headers) {
    const GURL& target = redirect_info.new_url;
    if (policy::AllowedRedirect(target.scheme(), target.host(), target.EffectiveIntPort(),
                                linux_updates::UpdateFeed())) {
      return;
    }
    LOG(WARNING) << "Ray's update download refused a redirect to " << target.host();
    loader_.reset();
    Fail(policy::kNetworkReason);
  }

  void OnFetched(base::FilePath path) {
    const int error = loader_ ? loader_->NetError() : net::ERR_FAILED;
    loader_.reset();
    if (path.empty()) {
      return Fail(error == net::ERR_INSUFFICIENT_RESOURCES ? policy::kTooLargeReason : policy::kNetworkReason);
    }
    switch (step_) {
      case Step::kManifest:
        return Fetch(Step::kSignature, policy::SignatureName(version_), policy::kSignatureBytes);
      case Step::kSignature:
        base::ThreadPool::PostTaskAndReplyWithResult(
            FROM_HERE, kFileTraits, base::BindOnce(&CheckManifest, directory_, version_, kind_),
            base::BindOnce(&PackageDownload::OnManifestChecked, weak_factory_.GetWeakPtr()));
        return;
      case Step::kPackage:
        base::ThreadPool::PostTaskAndReplyWithResult(
            FROM_HERE, kFileTraits, base::BindOnce(&PackageSizeMatches, path, package_size_),
            base::BindOnce(&PackageDownload::OnPackageChecked, weak_factory_.GetWeakPtr()));
        return;
    }
  }

  void OnManifestChecked(ManifestChecked checked) {
    if (!checked.package) return Fail(checked.reason);
    package_size_ = checked.package->size;
    Fetch(Step::kPackage, checked.package->name, checked.package->size);
  }

  void OnPackageChecked(bool matches) {
    if (!matches) return Fail(policy::kNetworkReason);
    Succeed();
  }

  void Succeed() { Complete(std::string()); }

  void Fail(std::string_view reason) {
    weak_factory_.InvalidateWeakPtrs();
    if (!finish_) return;
    base::ThreadPool::PostTaskAndReply(FROM_HERE, kFileTraits, base::BindOnce(&RemoveDirectory, directory_),
                                       base::BindOnce(std::move(finish_), Text(reason)));
  }

  void Complete(std::string result) {
    weak_factory_.InvalidateWeakPtrs();
    if (finish_) {
      base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
          FROM_HERE, base::BindOnce(std::move(finish_), std::move(result)));
    }
  }

  const std::string version_;
  const Kind kind_;
  const base::FilePath updates_;
  const base::FilePath directory_;
  Finish finish_;
  Step step_ = Step::kManifest;
  uint64_t package_size_ = 0;
  std::unique_ptr<network::SimpleURLLoader> loader_;
  base::WeakPtrFactory<PackageDownload> weak_factory_{this};
};

class Service {
 public:
  static Service& Get() {
    static base::NoDestructor<Service> service;
    return *service;
  }

  void InstallKind(base::OnceCallback<void(std::string)> reply) {
    if (kind_) return ReplyLater(std::move(reply), *kind_);
    kind_waiters_.push_back(std::move(reply));
    if (kind_waiters_.size() > 1) return;
    base::ThreadPool::PostTaskAndReplyWithResult(
        FROM_HERE,
        {base::MayBlock(), base::WithBaseSyncPrimitives(), base::TaskPriority::USER_VISIBLE,
         base::TaskShutdownBehavior::SKIP_ON_SHUTDOWN},
        base::BindOnce(&ReadKind, HelperPath(), AppImagePath()),
        base::BindOnce(&Service::KindRead, weak_factory_.GetWeakPtr()));
  }

  void Status(Done done) {
    InstallKind(base::BindOnce(&Service::AnswerStatus, weak_factory_.GetWeakPtr(), std::move(done)));
  }

  void Update(std::string version, Done done) {
    if (policy::BeginRun(state_, version)) {
      const int run = state_.run;
      InstallKind(base::BindOnce(&Service::DownloadWithKind, weak_factory_.GetWeakPtr(), run, std::move(version)));
    }
    Status(std::move(done));
  }

  bool ClaimOutcome(int run) { return policy::ClaimOutcome(state_, run); }

  void Restart() {
    if (kind_ && *kind_ == "appimage") {
      if (const std::optional<std::string> appimage = AppImagePath()) {
        base::CommandLine::ForCurrentProcess()->SetProgram(base::FilePath(*appimage));
      }
    }
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE, base::BindOnce(&chrome::AttemptRestart));
  }

 private:
  friend class base::NoDestructor<Service>;
  Service() = default;

  static void ReplyLater(base::OnceCallback<void(std::string)> reply, std::string kind) {
    base::SequencedTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE,
                                                             base::BindOnce(std::move(reply), std::move(kind)));
  }

  static base::Value Nullable(const std::string& text) {
    return text.empty() ? base::Value() : base::Value(text);
  }

  void AnswerStatus(Done done, std::string kind) {
    std::move(done).Run(true, base::Value(base::DictValue()
                                              .Set("phase", Text(policy::PhaseName(state_.phase)))
                                              .Set("version", Nullable(state_.version))
                                              .Set("reason", Nullable(state_.reason))
                                              .Set("kind", std::move(kind))
                                              .Set("run", state_.run)));
  }

  void KindRead(std::string kind) {
    if (kind != policy::kHelperFailed) kind_ = kind;
    std::vector<base::OnceCallback<void(std::string)>> waiting = std::move(kind_waiters_);
    kind_waiters_.clear();
    for (auto& reply : waiting) std::move(reply).Run(kind);
  }

  void DownloadWithKind(int run, std::string version, std::string kind_line) {
    const std::optional<Kind> kind = policy::InstallableKind(kind_line);
    if (!kind) return policy::Finished(state_, run, false, policy::kKindReason);
    const base::FilePath updates = UpdatesDirectory();
    if (updates.empty()) return policy::Finished(state_, run, false, policy::kDiskReason);
    download_ = std::make_unique<PackageDownload>(
        version, *kind, updates,
        base::BindOnce(&Service::DownloadFinished, weak_factory_.GetWeakPtr(), run, version, *kind,
                       updates.Append(version)));
    download_->Start();
  }

  void DownloadFinished(int run, std::string version, Kind kind, base::FilePath directory, std::string reason) {
    download_.reset();
    if (!reason.empty()) return policy::Finished(state_, run, false, reason);
    policy::Downloaded(state_, run);
    base::ThreadPool::PostTaskAndReplyWithResult(
        FROM_HERE,
        {base::MayBlock(), base::WithBaseSyncPrimitives(), base::TaskPriority::USER_VISIBLE,
         base::TaskShutdownBehavior::CONTINUE_ON_SHUTDOWN},
        base::BindOnce(&RunInstall, HelperPath(), kind, std::move(directory), version, AppImagePath()),
        base::BindOnce(&Service::InstallFinished, weak_factory_.GetWeakPtr(), run));
  }

  void InstallFinished(int run, policy::InstallOutcome outcome) {
    policy::Finished(state_, run, outcome.ok, outcome.detail);
  }

  std::optional<std::string> kind_;
  std::vector<base::OnceCallback<void(std::string)>> kind_waiters_;
  std::unique_ptr<PackageDownload> download_;
  policy::UpdateState state_;
  base::WeakPtrFactory<Service> weak_factory_{this};
};

std::optional<int> RunArgument(const base::ListValue& args) {
  if (args.size() != 1) return std::nullopt;
  if (args[0].is_int()) return args[0].GetInt();
  if (!args[0].is_double()) return std::nullopt;
  const double value = args[0].GetDouble();
  if (value < 0 || value > 1e9 || value != static_cast<double>(static_cast<int>(value))) return std::nullopt;
  return static_cast<int>(value);
}

std::optional<std::string> VersionArgument(const base::ListValue& args) {
  if (args.size() != 1 || !args[0].is_string()) return std::nullopt;
  return args[0].GetString();
}

}

bool Invokes(std::string_view method) {
  for (const char* capability : policy::kSelfUpdateCapabilities) {
    if (method == capability) return true;
  }
  return false;
}

void Invoke(std::string_view method, const base::ListValue& args, Done done) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (method == "RayUpdates.installKind") {
    if (!args.empty()) return std::move(done).Run(false, base::Value("installKind takes no arguments"));
    return Service::Get().InstallKind(base::BindOnce(
        [](Done done, std::string kind) { std::move(done).Run(true, base::Value(std::move(kind))); },
        std::move(done)));
  }
  if (method == "RayUpdates.status") {
    if (!args.empty()) return std::move(done).Run(false, base::Value("status takes no arguments"));
    return Service::Get().Status(std::move(done));
  }
  if (method == "RayUpdates.update") {
    return Service::Get().Update(VersionArgument(args).value_or(std::string()), std::move(done));
  }
  if (method == "RayUpdates.claimOutcome") {
    const std::optional<int> run = RunArgument(args);
    if (!run) return std::move(done).Run(false, base::Value("claimOutcome takes a run number"));
    return std::move(done).Run(true, base::Value(Service::Get().ClaimOutcome(*run)));
  }
  if (method == "RayUpdates.restart") {
    if (!args.empty()) return std::move(done).Run(false, base::Value("restart takes no arguments"));
    Service::Get().Restart();
    return std::move(done).Run(true, base::Value(true));
  }
  std::move(done).Run(false, base::Value("Unknown update method"));
}

}
