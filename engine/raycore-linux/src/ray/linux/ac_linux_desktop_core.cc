#include "ray/linux/ac_linux_desktop_core.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>

#include <atomic>
#include <utility>

namespace ray::linux_desktop {

namespace {

constexpr char kGroup[] = "Desktop Entry";
constexpr std::string_view kReserved = " \t\n\"'\\><~|&;$*?#()`";
constexpr std::string_view kQuotedEscapes = "\"`$\\";
constexpr const char* kDeniedSchemes[] = {
    "about",       "afp",    "applescript", "blob",    "chrome",   "chrome-extension", "chrome-search",
    "chrome-untrusted", "data", "devtools", "disk",    "disks",    "file",             "filesystem",
    "hcp",         "ie.http", "javascript", "mk",      "ms-help",  "nntp",             "res",
    "shell",       "vbscript", "view-source", "vnd.ms.radio"};

class Descriptor {
 public:
  explicit Descriptor(int fd) : fd_(fd) {}
  ~Descriptor() {
    if (fd_ >= 0) close(fd_);
  }
  Descriptor(const Descriptor&) = delete;
  Descriptor& operator=(const Descriptor&) = delete;
  int get() const { return fd_; }
  bool valid() const { return fd_ >= 0; }

 private:
  int fd_;
};

enum class ReadState { kOk, kMissing, kUnreadable };

struct SmallFile {
  ReadState state = ReadState::kUnreadable;
  std::string text;
};

SmallFile ReadSmallFile(const std::string& path) {
  SmallFile file;
  Descriptor fd(open(path.c_str(), O_RDONLY | O_CLOEXEC | O_NONBLOCK));
  if (!fd.valid()) {
    if (errno == ENOENT || errno == ENOTDIR) file.state = ReadState::kMissing;
    return file;
  }
  struct stat info;
  if (fstat(fd.get(), &info) != 0 || !S_ISREG(info.st_mode) || info.st_size < 0 ||
      static_cast<size_t>(info.st_size) > kEntryLimit) {
    return file;
  }
  std::string text;
  char buffer[4096];
  while (true) {
    const ssize_t got = read(fd.get(), buffer, sizeof(buffer));
    if (got < 0 && errno == EINTR) continue;
    if (got < 0) return file;
    if (got == 0) break;
    text.append(buffer, static_cast<size_t>(got));
    if (text.size() > kEntryLimit) return file;
  }
  file.state = ReadState::kOk;
  file.text = std::move(text);
  return file;
}

std::string_view Trimmed(std::string_view text) {
  const size_t first = text.find_first_not_of(" \t");
  if (first == std::string_view::npos) return {};
  return text.substr(first, text.find_last_not_of(" \t") - first + 1);
}

std::string Unescaped(std::string_view value) {
  std::string text;
  text.reserve(value.size());
  for (size_t index = 0; index < value.size(); ++index) {
    if (value[index] != '\\' || index + 1 == value.size()) {
      text.push_back(value[index]);
      continue;
    }
    const char next = value[++index];
    switch (next) {
      case 's': text.push_back(' '); break;
      case 'n': text.push_back('\n'); break;
      case 't': text.push_back('\t'); break;
      case 'r': text.push_back('\r'); break;
      case '\\': text.push_back('\\'); break;
      default:
        text.push_back('\\');
        text.push_back(next);
    }
  }
  return text;
}

bool ValidKey(std::string_view key) {
  if (key.empty()) return false;
  for (const char c : key) {
    const bool allowed = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-';
    if (!allowed) return false;
  }
  return true;
}

std::string ResolvedPath(const std::string& path) {
  char resolved[PATH_MAX];
  return realpath(path.c_str(), resolved) ? std::string(resolved) : std::string();
}

bool ExecutableFile(const std::string& path) {
  struct stat info;
  return stat(path.c_str(), &info) == 0 && S_ISREG(info.st_mode) && access(path.c_str(), X_OK) == 0;
}

bool Truthy(const Keys& keys, std::string_view key) {
  const auto found = keys.find(key);
  return found != keys.end() && found->second == "true";
}

bool DeclaresWebHandlers(const Keys& keys) {
  const auto found = keys.find("MimeType");
  if (found == keys.end()) return false;
  bool http = false;
  bool https = false;
  std::string_view rest = found->second;
  while (!rest.empty()) {
    const size_t semicolon = rest.find(';');
    const std::string_view type = Trimmed(rest.substr(0, semicolon));
    http = http || type == "x-scheme-handler/http";
    https = https || type == "x-scheme-handler/https";
    if (semicolon == std::string_view::npos) break;
    rest.remove_prefix(semicolon + 1);
  }
  return http && https;
}

bool Application(const Keys& keys) {
  const auto type = keys.find("Type");
  return type != keys.end() && type->second == "Application";
}

bool MakeDirectories(const std::string& path) {
  if (path.empty() || path.front() != '/') return false;
  size_t end = 1;
  while (end <= path.size()) {
    end = path.find('/', end);
    if (end == std::string::npos) end = path.size();
    const std::string prefix = path.substr(0, end);
    struct stat info;
    if (mkdir(prefix.c_str(), 0700) != 0 && (stat(prefix.c_str(), &info) != 0 || !S_ISDIR(info.st_mode))) return false;
    ++end;
  }
  return true;
}

bool WriteAll(int fd, std::string_view text) {
  while (!text.empty()) {
    const ssize_t wrote = write(fd, text.data(), text.size());
    if (wrote < 0 && errno == EINTR) continue;
    if (wrote <= 0) return false;
    text.remove_prefix(static_cast<size_t>(wrote));
  }
  return true;
}

LoginChange LoginFailure(std::string message) {
  return {false, "ERR_LOGIN_ITEM", std::move(message)};
}

DefaultBrowserAnswer NotDefault(std::string problem) {
  return {false, std::move(problem)};
}

std::optional<std::string> DefaultBrowserTool(const Install& install, std::string* problem) {
  const InstalledEntry entry = FindInstalledEntry(install);
  if (entry.state != EntryState::kUsable) {
    *problem = std::string(EntryProblem(entry.state));
    return std::nullopt;
  }
  std::string tool = FindTool(install, "xdg-settings");
  if (tool.empty()) {
    *problem = "xdg-settings is not installed";
    return std::nullopt;
  }
  return tool;
}

DefaultBrowserAnswer CheckWith(const std::string& tool, const ToolRunner& run) {
  const ToolResult result = run({tool, "check", "default-web-browser", kDesktopId}, kCheckSeconds);
  if (!result.ran || result.exit_code != 0) return NotDefault("xdg-settings could not read the default browser");
  std::string_view answer = result.output;
  while (!answer.empty() && (answer.back() == '\n' || answer.back() == '\r' || answer.back() == ' ')) {
    answer.remove_suffix(1);
  }
  if (answer == "yes") return {true, {}};
  if (answer == "no") return {};
  return NotDefault("xdg-settings gave an unexpected answer");
}

}

Install::Install() = default;
Install::Install(const Install&) = default;
Install::Install(Install&&) = default;
Install::~Install() = default;

std::optional<Keys> ParseEntry(std::string_view text) {
  if (text.size() > kEntryLimit || text.find('\0') != std::string_view::npos) return std::nullopt;
  Keys keys;
  bool seen = false;
  bool inside = false;
  while (!text.empty()) {
    const size_t newline = text.find('\n');
    std::string_view line = text.substr(0, newline);
    text.remove_prefix(newline == std::string_view::npos ? text.size() : newline + 1);
    if (!line.empty() && line.back() == '\r') line.remove_suffix(1);
    const std::string_view content = Trimmed(line);
    if (content.empty() || content.front() == '#') continue;
    if (content.front() == '[') {
      if (content.back() != ']') return std::nullopt;
      const bool entry = content.substr(1, content.size() - 2) == kGroup;
      if (entry && seen) return std::nullopt;
      inside = entry;
      seen = seen || entry;
      continue;
    }
    if (!inside) {
      if (!seen) return std::nullopt;
      continue;
    }
    const size_t equals = line.find('=');
    if (equals == std::string_view::npos) return std::nullopt;
    const std::string_view key = Trimmed(line.substr(0, equals));
    if (key.find('[') != std::string_view::npos) continue;
    if (!ValidKey(key)) return std::nullopt;
    keys.emplace(std::string(key), Unescaped(Trimmed(line.substr(equals + 1))));
  }
  if (!seen) return std::nullopt;
  return keys;
}

std::optional<std::string> ExecProgram(std::string_view exec) {
  size_t index = exec.find_first_not_of(' ');
  if (index == std::string_view::npos) return std::nullopt;
  std::string program;
  if (exec[index] == '"') {
    bool closed = false;
    for (++index; index < exec.size(); ++index) {
      const char c = exec[index];
      if (c == '"') {
        closed = true;
        ++index;
        break;
      }
      if (c == '\\') {
        if (index + 1 == exec.size()) return std::nullopt;
        program.push_back(exec[++index]);
        continue;
      }
      program.push_back(c);
    }
    if (!closed || (index < exec.size() && exec[index] != ' ')) return std::nullopt;
  } else {
    const size_t end = exec.find(' ', index);
    program = std::string(exec.substr(index, end == std::string_view::npos ? end : end - index));
    if (program.find_first_of("\"'\\`$") != std::string::npos) return std::nullopt;
  }
  std::string plain;
  for (size_t at = 0; at < program.size(); ++at) {
    if (program[at] != '%') {
      plain.push_back(program[at]);
      continue;
    }
    if (at + 1 == program.size() || program[at + 1] != '%') return std::nullopt;
    plain.push_back('%');
    ++at;
  }
  if (plain.empty()) return std::nullopt;
  return plain;
}

std::string QuoteExec(std::string_view path) {
  if (path.empty()) return {};
  for (const unsigned char c : path) {
    if (c < 0x20 || c == 0x7f) return {};
  }
  std::string argument;
  for (const char c : path) {
    if (c == '%') argument += "%%";
    else argument.push_back(c);
  }
  if (path.find_first_of(kReserved) == std::string_view::npos && path.find('=') == std::string_view::npos) {
    return argument;
  }
  std::string quoted = "\"";
  for (const char c : argument) {
    if (kQuotedEscapes.find(c) != std::string_view::npos) quoted.push_back('\\');
    quoted.push_back(c);
  }
  quoted.push_back('"');
  std::string escaped;
  for (const char c : quoted) {
    if (c == '\\') escaped.push_back('\\');
    escaped.push_back(c);
  }
  return escaped;
}

std::string FindTool(const Install& install, std::string_view name) {
  if (name.empty() || name.find('/') != std::string_view::npos) return {};
  for (const std::string& directory : install.search_path) {
    if (directory.empty() || directory.front() != '/') continue;
    std::string candidate = directory;
    if (candidate.back() != '/') candidate.push_back('/');
    candidate.append(name);
    if (ExecutableFile(candidate)) return candidate;
  }
  return {};
}

bool LaunchesThisInstall(std::string_view exec, const Install& install) {
  const std::optional<std::string> program = ExecProgram(exec);
  if (!program) return false;
  std::string path = *program;
  if (path.find('/') == std::string::npos) path = FindTool(install, path);
  if (path.empty() || path.front() != '/') return false;
  const std::string resolved = ResolvedPath(path);
  if (resolved.empty()) return false;
  for (const std::string* ours : {&install.launcher, &install.executable}) {
    if (!ours->empty() && resolved == ResolvedPath(*ours)) return true;
  }
  return false;
}

InstalledEntry FindInstalledEntry(const Install& install) {
  for (const std::string& directory : install.application_directories) {
    if (directory.empty() || directory.front() != '/') continue;
    InstalledEntry entry;
    entry.path = directory + "/" + kDesktopId;
    const SmallFile file = ReadSmallFile(entry.path);
    if (file.state == ReadState::kMissing) continue;
    const std::optional<Keys> keys = file.state == ReadState::kOk ? ParseEntry(file.text) : std::nullopt;
    const auto exec = keys ? keys->find("Exec") : Keys::const_iterator();
    if (!keys || !Application(*keys) || exec == keys->end()) entry.state = EntryState::kUnreadable;
    else if (Truthy(*keys, "Hidden")) entry.state = EntryState::kHidden;
    else if (!LaunchesThisInstall(exec->second, install)) entry.state = EntryState::kOtherInstall;
    else if (!DeclaresWebHandlers(*keys)) entry.state = EntryState::kNoHandlers;
    else entry.state = EntryState::kUsable;
    return entry;
  }
  return {};
}

std::string_view EntryProblem(EntryState state) {
  switch (state) {
    case EntryState::kUsable: return "";
    case EntryState::kMissing: return "Ray has no installed desktop entry";
    case EntryState::kUnreadable: return "Ray's desktop entry cannot be read";
    case EntryState::kHidden: return "Ray's desktop entry is hidden";
    case EntryState::kOtherInstall: return "The installed desktop entry starts another copy of Ray";
    case EntryState::kNoHandlers: return "Ray's desktop entry does not handle web links";
  }
  return "";
}

DefaultBrowserAnswer IsDefaultBrowser(const Install& install, const ToolRunner& run) {
  std::string problem;
  const std::optional<std::string> tool = DefaultBrowserTool(install, &problem);
  if (!tool) return NotDefault(std::move(problem));
  return CheckWith(*tool, run);
}

DefaultBrowserAnswer SetAsDefaultBrowser(const Install& install, const ToolRunner& run) {
  std::string problem;
  const std::optional<std::string> tool = DefaultBrowserTool(install, &problem);
  if (!tool) return NotDefault(std::move(problem));
  const ToolResult result = run({*tool, "set", "default-web-browser", kDesktopId}, kSetSeconds);
  if (!result.ran || result.exit_code != 0) return NotDefault("xdg-settings could not set the default browser");
  DefaultBrowserAnswer answer = CheckWith(*tool, run);
  if (!answer.is_default && answer.problem.empty()) answer.problem = "The desktop kept another default browser";
  return answer;
}

std::string_view LoginStatusName(LoginStatus status) {
  switch (status) {
    case LoginStatus::kEnabled: return "enabled";
    case LoginStatus::kNotRegistered: return "notRegistered";
    case LoginStatus::kNotFound: return "notFound";
  }
  return "notFound";
}

std::string AutostartEntry(const Install& install) {
  const std::string exec = QuoteExec(install.launcher);
  if (exec.empty()) return {};
  return "[Desktop Entry]\nType=Application\nName=Ray\nExec=" + exec +
         "\nIcon=ray\nTerminal=false\nX-GNOME-Autostart-enabled=true\n";
}

LoginStatus LaunchAtLoginStatus(const Install& install) {
  if (install.autostart_directory.empty() || install.autostart_directory.front() != '/' ||
      !ExecutableFile(install.launcher) || AutostartEntry(install).empty()) {
    return LoginStatus::kNotFound;
  }
  const SmallFile file = ReadSmallFile(install.autostart_directory + "/" + kDesktopId);
  if (file.state != ReadState::kOk) return LoginStatus::kNotRegistered;
  const std::optional<Keys> keys = ParseEntry(file.text);
  if (!keys || !Application(*keys) || Truthy(*keys, "Hidden")) return LoginStatus::kNotRegistered;
  const auto enabled = keys->find("X-GNOME-Autostart-enabled");
  if (enabled != keys->end() && enabled->second == "false") return LoginStatus::kNotRegistered;
  const auto exec = keys->find("Exec");
  if (exec == keys->end() || !LaunchesThisInstall(exec->second, install)) return LoginStatus::kNotRegistered;
  return LoginStatus::kEnabled;
}

LoginChange SetLaunchAtLogin(const Install& install, bool enabled) {
  static std::atomic<unsigned> sequence{0};
  if (install.autostart_directory.empty() || install.autostart_directory.front() != '/') {
    return LoginFailure("There is no home folder to keep the login entry in");
  }
  if (!enabled) {
    Descriptor directory(open(install.autostart_directory.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC));
    if (!directory.valid()) {
      if (errno == ENOENT || errno == ENOTDIR) return {true, {}, {}};
      return LoginFailure("The autostart folder cannot be opened");
    }
    if (unlinkat(directory.get(), kDesktopId, 0) != 0 && errno != ENOENT) {
      return LoginFailure("The login entry cannot be removed");
    }
    fsync(directory.get());
    return {true, {}, {}};
  }
  const std::string text = AutostartEntry(install);
  if (text.empty() || !ExecutableFile(install.launcher)) {
    return LoginFailure("This copy of Ray has no launcher to start at login");
  }
  if (!MakeDirectories(install.autostart_directory)) return LoginFailure("The autostart folder cannot be created");
  Descriptor directory(open(install.autostart_directory.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC));
  if (!directory.valid()) return LoginFailure("The autostart folder cannot be opened");
  std::string staged;
  int staged_fd = -1;
  for (int attempt = 0; attempt < 8 && staged_fd < 0; ++attempt) {
    staged = "." + std::string(kDesktopId) + "." + std::to_string(getpid()) + "." + std::to_string(sequence++) +
             ".tmp";
    staged_fd = openat(directory.get(), staged.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0644);
    if (staged_fd < 0 && errno != EEXIST) break;
  }
  if (staged_fd < 0) return LoginFailure("The login entry cannot be written");
  bool written = false;
  {
    Descriptor file(staged_fd);
    written = WriteAll(file.get(), text) && fchmod(file.get(), 0644) == 0 && fsync(file.get()) == 0;
  }
  if (!written || renameat(directory.get(), staged.c_str(), directory.get(), kDesktopId) != 0) {
    unlinkat(directory.get(), staged.c_str(), 0);
    return LoginFailure("The login entry cannot be written");
  }
  fsync(directory.get());
  return {true, {}, {}};
}

bool ExternalSchemeAllowed(std::string_view scheme) {
  if (scheme.empty() || scheme.size() > 64) return false;
  const char first = scheme.front();
  if (!((first >= 'a' && first <= 'z') || (first >= 'A' && first <= 'Z'))) return false;
  std::string lower;
  for (const char c : scheme) {
    const bool allowed = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '+' ||
                         c == '-' || c == '.';
    if (!allowed) return false;
    lower.push_back(c >= 'A' && c <= 'Z' ? static_cast<char>(c - 'A' + 'a') : c);
  }
  for (const char* denied : kDeniedSchemes) {
    if (lower == denied) return false;
  }
  return true;
}

}
