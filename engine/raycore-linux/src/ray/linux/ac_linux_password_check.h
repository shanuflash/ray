#ifndef RAY_LINUX_AC_LINUX_PASSWORD_CHECK_H_
#define RAY_LINUX_AC_LINUX_PASSWORD_CHECK_H_

#include <sys/types.h>

#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <string_view>

namespace ray::linux_password {

struct FileFacts {
  bool regular = false;
  bool directory = false;
  uid_t owner = 0;
  mode_t mode = 0;
};

inline constexpr std::array<const char*, 4> kHelpers = {
    "/usr/sbin/unix_chkpwd",
    "/sbin/unix_chkpwd",
    "/usr/bin/unix_chkpwd",
    "/run/wrappers/bin/unix_chkpwd",
};
inline constexpr int kWrongPasswordExit = 7;
inline constexpr size_t kMaxPasswordBytes = 512;
inline constexpr int kHelperDeadlineMs = 15000;
inline constexpr mode_t kWritableByOthers = 0022;

enum class Verdict { kMatch, kMismatch, kFailed };

template <typename Stat>
std::optional<std::string> TrustedHelperAt(const std::string& real_path, Stat&& stat) {
  if (real_path.empty() || real_path.front() != '/') {
    return std::nullopt;
  }
  const std::optional<FileFacts> file = stat(real_path);
  if (!file || !file->regular || file->owner != 0 || (file->mode & kWritableByOthers) || !(file->mode & 0111)) {
    return std::nullopt;
  }
  std::string folder = real_path;
  while (true) {
    const size_t slash = folder.find_last_of('/');
    folder = slash == 0 ? "/" : folder.substr(0, slash);
    const std::optional<FileFacts> facts = stat(folder);
    if (!facts || !facts->directory || facts->owner != 0 || (facts->mode & kWritableByOthers)) {
      return std::nullopt;
    }
    if (folder == "/") {
      return real_path;
    }
  }
}

std::optional<FileFacts> StatOnDisk(const std::string& path);
std::optional<std::string> RealPath(const std::string& path);
std::optional<std::string> FindHelper();
std::optional<std::string> CurrentUser();

Verdict VerdictForExit(std::optional<int> exit_code);
std::optional<std::string> UnusablePassword(std::string_view password);

Verdict RunHelper(const std::string& helper,
                  const std::string& user,
                  std::string_view password,
                  int deadline_ms = kHelperDeadlineMs);

class Throttle {
 public:
  void NoteWrong(int64_t now_ms);
  void NoteRight();
  int64_t WaitMs(int64_t now_ms) const;
  int wrong() const { return wrong_; }

 private:
  int wrong_ = 0;
  int64_t retry_at_ms_ = 0;
};

}

#endif
