#ifndef RAY_LINUX_AC_LINUX_REPORT_CORE_H_
#define RAY_LINUX_AC_LINUX_REPORT_CORE_H_

#include <cstddef>
#include <cstdint>
#include <functional>
#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace ray::linux_report {

inline constexpr const char* kReportCapabilities[] = {"report.files", "report.send"};
inline constexpr const char* kReportCalls[] = {
    "RayReport.draftDirectory", "RayReport.fileSize", "RayReport.removeFile", "RayReport.gzipFile",
    "RayReport.gzipText",       "RayReport.upload",   "RayReport.post",       "RayReport.cancelUploads"};
inline constexpr char kDraftsFolder[] = "Report Drafts";
inline constexpr char kEndpoint[] = "https://github.com/shanuflash/ray/api/feedback";
inline constexpr char kErrorCode[] = "ERR_REPORT";
inline constexpr char kEvent[] = "onReport";
inline constexpr int64_t kMiB = 1024 * 1024;
inline constexpr size_t kJsonMaxBytes = 128 * 1024;
inline constexpr size_t kTextMaxBytes = 64 * 1024 * 1024;
inline constexpr size_t kUploadReplyMaxBytes = 4096;
inline constexpr size_t kPostReplyMaxBytes = 64 * 1024;
inline constexpr size_t kPathMaxBytes = 4096;
inline constexpr int kMaxTransfers = 4;
inline constexpr int kPostTimeoutSeconds = 30;
inline constexpr int kUploadTimeoutSeconds = 15 * 60;

enum class Target { kRefused, kCreate, kComplete, kFile };

struct Request {
  Target target = Target::kRefused;
  std::string id;
  std::string file;
  int64_t max_bytes = 0;
};

using Header = std::pair<std::string, std::string>;

bool InsideDrafts(std::string_view drafts, std::string_view path);
bool DraftFolderName(std::string_view name);
bool ReportId(std::string_view id);
std::optional<int64_t> FileLimit(std::string_view name);
Request ClassifyUrl(std::string_view endpoint, std::string_view url);
bool MethodAllowed(Target target, std::string_view method);
std::optional<std::vector<Header>> AllowedHeaders(Target target, const std::vector<Header>& given);
bool UploadSizeAllowed(const Request& request, int64_t bytes);
std::string ReplyText(std::string_view body, size_t limit);

using GzipRead = std::function<int64_t(uint8_t* buffer, size_t capacity)>;
using GzipWrite = std::function<bool(const uint8_t* data, size_t size)>;
int64_t Gzip(const GzipRead& read, const GzipWrite& write);

}

#endif
