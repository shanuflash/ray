#include "ray/linux/ac_linux_crash_dumps.h"

#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "ray/linux/ac_linux_cli.h"
#include "ray/linux/ac_linux_crash_dumps_core.h"
#include "base/base64.h"
#include "base/files/file.h"
#include "base/files/file_path.h"
#include "base/files/file_util.h"
#include "base/functional/bind.h"
#include "base/path_service.h"
#include "base/task/thread_pool.h"
#include "base/time/time.h"
#include "chrome/common/chrome_paths.h"
#include "components/crash/core/common/crash_key.h"
#include "content/public/browser/browser_thread.h"
#include "third_party/crashpad/crashpad/client/crash_report_database.h"
#include "third_party/crashpad/crashpad/util/misc/uuid.h"

namespace raycore {

namespace {

namespace crash = ray::linux_crash;

using Done = base::OnceCallback<void(bool, base::Value)>;
using Database = crashpad::CrashReportDatabase;

void Fail(Done done, std::string_view message) {
  std::move(done).Run(false, base::Value(base::DictValue().Set("code", "ERR_ENGINE").Set("message", message)));
}

base::FilePath DatabaseFolder() {
  base::FilePath folder;
  if (!base::PathService::Get(chrome::DIR_CRASH_DUMPS, &folder)) return base::FilePath();
  return folder;
}

std::unique_ptr<Database> OpenDatabase(const base::FilePath& folder) {
  if (folder.empty() || !base::DirectoryExists(folder)) return nullptr;
  return Database::InitializeWithoutCreating(folder);
}

double WrittenAt(const Database::Report& report) {
  base::File::Info info;
  if (base::GetFileInfo(report.file_path, &info) && !info.last_modified.is_null()) {
    return info.last_modified.InMillisecondsFSinceUnixEpochIgnoringNull();
  }
  return static_cast<double>(report.creation_time) * 1000;
}

std::vector<crash::Dump> ListDumps(const base::FilePath& folder, double since) {
  std::unique_ptr<Database> database = OpenDatabase(folder);
  if (!database) return {};
  std::vector<crash::Dump> dumps;
  std::vector<Database::Report> reports;
  if (database->GetPendingReports(&reports) == Database::kNoError) {
    for (const Database::Report& report : reports) dumps.push_back({report.uuid.ToString(), WrittenAt(report)});
  }
  reports.clear();
  if (database->GetCompletedReports(&reports) == Database::kNoError) {
    for (const Database::Report& report : reports) dumps.push_back({report.uuid.ToString(), WrittenAt(report)});
  }
  return crash::Newest(std::move(dumps), since);
}

std::optional<std::string> ReadDump(const base::FilePath& folder, const std::string& id) {
  crashpad::UUID uuid;
  if (!crash::IsReportId(id) || !uuid.InitializeFromString(id)) return std::nullopt;
  std::unique_ptr<Database> database = OpenDatabase(folder);
  if (!database) return std::nullopt;
  Database::Report report;
  if (database->LookUpCrashReport(uuid, &report) != Database::kNoError) return std::nullopt;
  std::string bytes;
  if (!base::ReadFileToStringWithMaxSize(report.file_path, &bytes, crash::kReadMaxBytes)) return std::nullopt;
  return base::Base64Encode(bytes);
}

}

bool LinuxCrashInvokes(std::string_view method) {
  return method == crash::kListCall || method == crash::kReadCall;
}

void LinuxCrashInvoke(std::string_view method, const base::ListValue& args, Done done) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  const base::TaskTraits files = {base::MayBlock(), base::TaskPriority::BEST_EFFORT,
                                  base::TaskShutdownBehavior::SKIP_ON_SHUTDOWN};
  if (method == crash::kListCall) {
    const std::optional<double> since = crash::ListSince(args.size(), args.empty() ? std::nullopt : args[0].GetIfDouble());
    if (!since) return Fail(std::move(done), "RayCrash.list takes the time to list dumps after, in milliseconds");
    base::ThreadPool::PostTaskAndReplyWithResult(
        FROM_HERE, files, base::BindOnce(&ListDumps, DatabaseFolder(), *since),
        base::BindOnce([](Done done, std::vector<crash::Dump> dumps) {
          base::ListValue listed;
          for (crash::Dump& dump : dumps) {
            listed.Append(base::DictValue().Set("id", std::move(dump.id)).Set("time", dump.time));
          }
          std::move(done).Run(true, base::Value(std::move(listed)));
        }, std::move(done)));
    return;
  }
  if (method == crash::kReadCall) {
    if (args.size() != 1 || !args[0].is_string() || !crash::IsReportId(args[0].GetString())) {
      return Fail(std::move(done), "RayCrash.read takes a crash report id");
    }
    base::ThreadPool::PostTaskAndReplyWithResult(
        FROM_HERE, files, base::BindOnce(&ReadDump, DatabaseFolder(), args[0].GetString()),
        base::BindOnce([](Done done, std::optional<std::string> dump) {
          std::move(done).Run(true, dump ? base::Value(std::move(*dump)) : base::Value());
        }, std::move(done)));
    return;
  }
  Fail(std::move(done), "Unknown crash call");
}

void AnnotateLinuxCrashVersion() {
  static crash_reporter::CrashKeyString<crash::kVersionMaxBytes> version(crash::kVersionKey);
  if (const auto annotated = crash::AnnotatedVersion(LinuxAppVersion())) version.Set(*annotated);
}

}
