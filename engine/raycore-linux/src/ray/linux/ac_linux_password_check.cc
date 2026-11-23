#include "ray/linux/ac_linux_password_check.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pwd.h>
#include <signal.h>
#include <spawn.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include <algorithm>
#include <vector>

namespace ray::linux_password {
namespace {

constexpr std::array<int64_t, 6> kRetryDelaysMs = {0, 0, 2000, 5000, 30000, 60000};

bool WriteAll(int fd, const char* data, size_t size) {
  while (size > 0) {
    const ssize_t written = send(fd, data, size, MSG_NOSIGNAL);
    if (written < 0 && errno == EINTR) {
      continue;
    }
    if (written <= 0) {
      return false;
    }
    data += written;
    size -= static_cast<size_t>(written);
  }
  return true;
}

void SleepMs(int ms) {
  timespec wait{0, static_cast<long>(ms) * 1000000L};
  while (nanosleep(&wait, &wait) != 0 && errno == EINTR) {
  }
}

}

std::optional<FileFacts> StatOnDisk(const std::string& path) {
  struct stat facts;
  if (stat(path.c_str(), &facts) != 0) {
    return std::nullopt;
  }
  return FileFacts{S_ISREG(facts.st_mode), S_ISDIR(facts.st_mode), facts.st_uid, facts.st_mode};
}

std::optional<std::string> RealPath(const std::string& path) {
  char resolved[PATH_MAX];
  if (!realpath(path.c_str(), resolved)) {
    return std::nullopt;
  }
  return std::string(resolved);
}

std::optional<std::string> FindHelper() {
  for (const char* candidate : kHelpers) {
    const std::optional<std::string> real = RealPath(candidate);
    if (!real) {
      continue;
    }
    if (std::optional<std::string> trusted = TrustedHelperAt(*real, StatOnDisk)) {
      return trusted;
    }
  }
  return std::nullopt;
}

std::optional<std::string> CurrentUser() {
  struct passwd entry;
  struct passwd* found = nullptr;
  std::vector<char> buffer(16384);
  if (getpwuid_r(getuid(), &entry, buffer.data(), buffer.size(), &found) != 0 || !found || !found->pw_name ||
      !*found->pw_name) {
    return std::nullopt;
  }
  return std::string(found->pw_name);
}

Verdict VerdictForExit(std::optional<int> exit_code) {
  if (exit_code == 0) {
    return Verdict::kMatch;
  }
  if (exit_code == kWrongPasswordExit) {
    return Verdict::kMismatch;
  }
  return Verdict::kFailed;
}

std::optional<std::string> UnusablePassword(std::string_view password) {
  if (password.empty()) {
    return "Enter your login password.";
  }
  if (password.size() > kMaxPasswordBytes) {
    return "That password is too long to check.";
  }
  if (password.find('\0') != std::string_view::npos) {
    return "That password can't be checked.";
  }
  return std::nullopt;
}

Verdict RunHelper(const std::string& helper, const std::string& user, std::string_view password, int deadline_ms) {
  int ends[2];
  if (socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, ends) != 0) {
    return Verdict::kFailed;
  }
  const int nowhere = open("/dev/null", O_RDWR | O_CLOEXEC);
  posix_spawn_file_actions_t actions;
  posix_spawn_file_actions_init(&actions);
  posix_spawn_file_actions_adddup2(&actions, ends[0], STDIN_FILENO);
  if (nowhere >= 0) {
    posix_spawn_file_actions_adddup2(&actions, nowhere, STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, nowhere, STDERR_FILENO);
  }
  std::string program = helper;
  std::string name = user;
  std::string mode = "nonull";
  char* argv[] = {program.data(), name.data(), mode.data(), nullptr};
  char* envp[] = {nullptr};
  pid_t child = -1;
  const int spawned = posix_spawn(&child, helper.c_str(), &actions, nullptr, argv, envp);
  posix_spawn_file_actions_destroy(&actions);
  close(ends[0]);
  if (nowhere >= 0) {
    close(nowhere);
  }
  if (spawned != 0) {
    close(ends[1]);
    return Verdict::kFailed;
  }
  constexpr char kTerminator = '\0';
  if (WriteAll(ends[1], password.data(), password.size())) {
    WriteAll(ends[1], &kTerminator, 1);
  }
  shutdown(ends[1], SHUT_WR);
  close(ends[1]);
  int status = 0;
  for (int waited = 0;; waited += 10) {
    const pid_t done = waitpid(child, &status, WNOHANG);
    if (done == child) {
      break;
    }
    if (done < 0 && errno != EINTR) {
      return Verdict::kFailed;
    }
    if (waited >= deadline_ms) {
      kill(child, SIGKILL);
      while (waitpid(child, &status, 0) < 0 && errno == EINTR) {
      }
      return Verdict::kFailed;
    }
    SleepMs(10);
  }
  return VerdictForExit(WIFEXITED(status) ? std::optional<int>(WEXITSTATUS(status)) : std::nullopt);
}

void Throttle::NoteWrong(int64_t now_ms) {
  ++wrong_;
  const size_t step = std::min<size_t>(static_cast<size_t>(wrong_), kRetryDelaysMs.size() - 1);
  retry_at_ms_ = now_ms + kRetryDelaysMs[step];
}

void Throttle::NoteRight() {
  wrong_ = 0;
  retry_at_ms_ = 0;
}

int64_t Throttle::WaitMs(int64_t now_ms) const {
  return std::max<int64_t>(0, retry_at_ms_ - now_ms);
}

}
