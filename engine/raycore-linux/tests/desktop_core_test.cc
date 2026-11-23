#include <fcntl.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

#include "ray/linux/ac_linux_desktop_core.cc"

namespace desktop = ray::linux_desktop;

namespace {

constexpr char kHandlers[] = "MimeType=text/html;x-scheme-handler/http;x-scheme-handler/https;\n";

void Write(const std::string& path, const std::string& text, mode_t mode = 0644) {
  std::filesystem::create_directories(std::filesystem::path(path).parent_path());
  std::ofstream out(path, std::ios::binary | std::ios::trunc);
  out << text;
  out.close();
  assert(chmod(path.c_str(), mode) == 0);
}

std::string Slurp(const std::string& path) {
  std::ifstream in(path, std::ios::binary);
  std::stringstream all;
  all << in.rdbuf();
  return all.str();
}

mode_t Mode(const std::string& path) {
  struct stat info;
  assert(lstat(path.c_str(), &info) == 0);
  return info.st_mode & 07777;
}

bool Exists(const std::string& path) {
  struct stat info;
  return lstat(path.c_str(), &info) == 0;
}

std::vector<std::string> Listing(const std::string& folder) {
  std::vector<std::string> names;
  for (const auto& entry : std::filesystem::directory_iterator(folder)) names.push_back(entry.path().filename());
  return names;
}

std::string Entry(const std::string& exec, const std::string& extra = kHandlers) {
  return "[Desktop Entry]\nType=Application\nName=Ray\nExec=" + exec + " %U\n" + extra;
}

desktop::Install Installed(const std::string& root) {
  desktop::Install install;
  install.application_directories = {root + "/home/applications", root + "/usr/share/applications"};
  install.autostart_directory = root + "/home/config/autostart";
  install.search_path = {root + "/empty", root + "/usr/bin"};
  install.launcher = root + "/usr/bin/ray";
  install.executable = root + "/usr/lib/ray/chrome";
  Write(install.launcher, "#!/bin/sh\n", 0755);
  Write(install.executable, "#!/bin/sh\n", 0755);
  return install;
}

void Entries() {
  const auto keys = desktop::ParseEntry(
      "# a comment\n\n[Desktop Entry]\r\nType=Application\nName = Ray \nName[fr]=Ray FR\nExec=/opt/a\\sb/ray %U\n"
      "Hidden=false\n[Desktop Action new]\nExec=/other\nName=New\n");
  assert(keys && keys->size() == 4);
  assert(keys->at("Type") == "Application" && keys->at("Name") == "Ray" && keys->at("Hidden") == "false");
  assert(keys->at("Exec") == "/opt/a b/ray %U");
  assert(!desktop::ParseEntry(""));
  assert(!desktop::ParseEntry("Type=Application\n[Desktop Entry]\n"));
  assert(!desktop::ParseEntry("[Other]\nType=Application\n"));
  assert(!desktop::ParseEntry("[Desktop Entry]\nno equals sign\n"));
  assert(!desktop::ParseEntry("[Desktop Entry]\nBad Key=1\n"));
  assert(!desktop::ParseEntry("[Desktop Entry\nType=Application\n"));
  assert(!desktop::ParseEntry("[Desktop Entry]\nType=Application\n[Desktop Entry]\nType=Link\n"));
  assert(!desktop::ParseEntry(std::string("[Desktop Entry]\nType=A\0pplication\n", 33)));
  assert(!desktop::ParseEntry("[Desktop Entry]\n" + std::string(desktop::kEntryLimit, '#')));
  const auto first = desktop::ParseEntry("[Desktop Entry]\nExec=/first\nExec=/second\nTrailing=a\\");
  assert(first && first->at("Exec") == "/first" && first->at("Trailing") == "a\\");

  assert(desktop::ExecProgram("ray %U") == std::string("ray"));
  assert(desktop::ExecProgram("  /usr/bin/ray") == std::string("/usr/bin/ray"));
  assert(desktop::ExecProgram("\"/opt/my apps/ray\" %U") == std::string("/opt/my apps/ray"));
  assert(desktop::ExecProgram("\"/opt/a\\$b\\\\c\\\"d\\`e\" --flag") == std::string("/opt/a$b\\c\"d`e"));
  assert(desktop::ExecProgram("/opt/100%%/ray") == std::string("/opt/100%/ray"));
  assert(!desktop::ExecProgram(""));
  assert(!desktop::ExecProgram("   "));
  assert(!desktop::ExecProgram("\"/opt/unterminated"));
  assert(!desktop::ExecProgram("\"/opt/a\"b"));
  assert(!desktop::ExecProgram("\"/opt/a\\"));
  assert(!desktop::ExecProgram("%U"));
  assert(!desktop::ExecProgram("/opt/$HOME/ray"));
  assert(!desktop::ExecProgram("\"\""));

  assert(desktop::QuoteExec("/usr/bin/ray") == "/usr/bin/ray");
  assert(desktop::QuoteExec("/opt/my apps/ray") == "\"/opt/my apps/ray\"");
  assert(desktop::QuoteExec("/opt/a$b/ray") == "\"/opt/a\\\\$b/ray\"");
  assert(desktop::QuoteExec("").empty());
  assert(desktop::QuoteExec("/opt/a\nb/ray").empty());
  assert(desktop::QuoteExec("/opt/a\x7f/ray").empty());
  for (const std::string path : {"/usr/bin/ray", "/opt/my apps/ray", "/opt/a$b/ray", "/opt/a\\b/ray",
                                 "/opt/a\"b/ray", "/opt/a`b/ray", "/opt/100%/ray", "/opt/a=b/ray",
                                 "/opt/a'b (c)/ray", "/opt/ünï/ray", "/opt/a%U b/ray"}) {
    const auto keys_back = desktop::ParseEntry("[Desktop Entry]\nExec=" + desktop::QuoteExec(path) + "\n");
    assert(keys_back);
    assert(desktop::ExecProgram(keys_back->at("Exec")) == path);
  }
}

void InstalledEntries(const std::string& root) {
  desktop::Install install = Installed(root);
  const std::string shared = install.application_directories[1] + "/ray.desktop";
  const std::string personal = install.application_directories[0] + "/ray.desktop";
  assert(desktop::FindInstalledEntry(install).state == desktop::EntryState::kMissing);

  Write(shared, Entry(install.launcher));
  const auto usable = desktop::FindInstalledEntry(install);
  assert(usable.state == desktop::EntryState::kUsable && usable.path == shared);
  Write(shared, Entry(install.executable));
  assert(desktop::FindInstalledEntry(install).state == desktop::EntryState::kUsable);
  Write(shared, Entry("ray"));
  assert(desktop::FindInstalledEntry(install).state == desktop::EntryState::kUsable);
  assert(symlink(install.launcher.c_str(), (root + "/link").c_str()) == 0);
  Write(shared, Entry(root + "/link"));
  assert(desktop::FindInstalledEntry(install).state == desktop::EntryState::kUsable);

  Write(root + "/other/bin/ray", "#!/bin/sh\n", 0755);
  Write(shared, Entry(root + "/other/bin/ray"));
  assert(desktop::FindInstalledEntry(install).state == desktop::EntryState::kOtherInstall);
  Write(shared, Entry(root + "/gone/ray"));
  assert(desktop::FindInstalledEntry(install).state == desktop::EntryState::kOtherInstall);
  Write(shared, Entry("usr/bin/ray"));
  assert(desktop::FindInstalledEntry(install).state == desktop::EntryState::kOtherInstall);
  desktop::Install pathless = install;
  pathless.search_path.clear();
  Write(shared, Entry("ray"));
  assert(desktop::FindInstalledEntry(pathless).state == desktop::EntryState::kOtherInstall);

  Write(shared, Entry(install.launcher, "MimeType=text/html;x-scheme-handler/http;\n"));
  assert(desktop::FindInstalledEntry(install).state == desktop::EntryState::kNoHandlers);
  Write(shared, Entry(install.launcher, ""));
  assert(desktop::FindInstalledEntry(install).state == desktop::EntryState::kNoHandlers);
  Write(shared, Entry(install.launcher, "MimeType= x-scheme-handler/https ; x-scheme-handler/http\n"));
  assert(desktop::FindInstalledEntry(install).state == desktop::EntryState::kUsable);

  Write(shared, "not a desktop entry\n");
  assert(desktop::FindInstalledEntry(install).state == desktop::EntryState::kUnreadable);
  Write(shared, "[Desktop Entry]\nType=Link\nExec=" + install.launcher + "\n" + kHandlers);
  assert(desktop::FindInstalledEntry(install).state == desktop::EntryState::kUnreadable);
  Write(shared, "[Desktop Entry]\nType=Application\n" + std::string(kHandlers));
  assert(desktop::FindInstalledEntry(install).state == desktop::EntryState::kUnreadable);
  Write(shared, Entry(install.launcher) + std::string(desktop::kEntryLimit, '#'));
  assert(desktop::FindInstalledEntry(install).state == desktop::EntryState::kUnreadable);

  Write(shared, Entry(install.launcher));
  Write(personal, Entry(install.launcher, std::string(kHandlers) + "Hidden=true\n"));
  const auto hidden = desktop::FindInstalledEntry(install);
  assert(hidden.state == desktop::EntryState::kHidden && hidden.path == personal);
  assert(unlink(personal.c_str()) == 0);
  assert(mkdir(personal.c_str(), 0755) == 0);
  assert(desktop::FindInstalledEntry(install).state == desktop::EntryState::kUnreadable);
  assert(rmdir(personal.c_str()) == 0);
  assert(mkfifo(personal.c_str(), 0644) == 0);
  assert(desktop::FindInstalledEntry(install).state == desktop::EntryState::kUnreadable);
  assert(unlink(personal.c_str()) == 0);
  desktop::Install relative = install;
  relative.application_directories = {"usr/share/applications", ""};
  assert(desktop::FindInstalledEntry(relative).state == desktop::EntryState::kMissing);
  for (const auto state : {desktop::EntryState::kMissing, desktop::EntryState::kUnreadable, desktop::EntryState::kHidden,
                           desktop::EntryState::kOtherInstall, desktop::EntryState::kNoHandlers}) {
    assert(!desktop::EntryProblem(state).empty());
  }
  assert(desktop::EntryProblem(desktop::EntryState::kUsable).empty());

  assert(desktop::FindTool(install, "ray") == install.launcher);
  assert(desktop::FindTool(install, "xdg-settings").empty());
  assert(desktop::FindTool(install, "../bin/ray").empty());
  assert(desktop::FindTool(install, "").empty());
  Write(root + "/usr/bin/plain", "data\n", 0644);
  assert(desktop::FindTool(install, "plain").empty());
}

desktop::ToolResult Spawn(const std::vector<std::string>& arguments, int) {
  desktop::ToolResult result;
  int ends[2];
  assert(pipe(ends) == 0);
  const pid_t child = fork();
  assert(child >= 0);
  if (child == 0) {
    dup2(ends[1], STDOUT_FILENO);
    close(ends[0]);
    close(ends[1]);
    std::vector<char*> argv;
    for (const std::string& argument : arguments) argv.push_back(const_cast<char*>(argument.c_str()));
    argv.push_back(nullptr);
    execv(argv[0], argv.data());
    _exit(127);
  }
  close(ends[1]);
  char buffer[256];
  ssize_t got;
  while ((got = read(ends[0], buffer, sizeof(buffer))) > 0) result.output.append(buffer, static_cast<size_t>(got));
  close(ends[0]);
  int status = 0;
  assert(waitpid(child, &status, 0) == child);
  result.ran = WIFEXITED(status);
  result.exit_code = result.ran ? WEXITSTATUS(status) : -1;
  return result;
}

void DefaultBrowser(const std::string& root) {
  desktop::Install install = Installed(root);
  const std::string shared = install.application_directories[1] + "/ray.desktop";
  const std::string tool = root + "/usr/bin/xdg-settings";
  std::vector<std::vector<std::string>> calls;
  std::vector<desktop::ToolResult> replies;
  const desktop::ToolRunner scripted = [&](const std::vector<std::string>& arguments, int seconds) {
    assert(seconds == (arguments[1] == "set" ? desktop::kSetSeconds : desktop::kCheckSeconds));
    calls.push_back(arguments);
    assert(!replies.empty());
    desktop::ToolResult reply = replies.front();
    replies.erase(replies.begin());
    return reply;
  };
  using Calls = std::vector<std::vector<std::string>>;
  const std::vector<std::string> check = {tool, "check", "default-web-browser", "ray.desktop"};
  const std::vector<std::string> set = {tool, "set", "default-web-browser", "ray.desktop"};

  auto answer = desktop::IsDefaultBrowser(install, scripted);
  assert(!answer.is_default && answer.problem == "Ray has no installed desktop entry" && calls.empty());
  answer = desktop::SetAsDefaultBrowser(install, scripted);
  assert(!answer.is_default && answer.problem == "Ray has no installed desktop entry" && calls.empty());
  Write(shared, Entry(root + "/other/ray"));
  answer = desktop::SetAsDefaultBrowser(install, scripted);
  assert(!answer.is_default && answer.problem == "The installed desktop entry starts another copy of Ray" && calls.empty());
  Write(shared, Entry(install.launcher));
  answer = desktop::IsDefaultBrowser(install, scripted);
  assert(!answer.is_default && answer.problem == "xdg-settings is not installed" && calls.empty());
  answer = desktop::SetAsDefaultBrowser(install, scripted);
  assert(!answer.is_default && answer.problem == "xdg-settings is not installed" && calls.empty());

  Write(tool, "#!/bin/sh\n", 0755);
  replies = {{true, 0, "yes\n"}};
  answer = desktop::IsDefaultBrowser(install, scripted);
  assert(answer.is_default && answer.problem.empty() && calls == Calls{check});
  calls.clear();
  replies = {{true, 0, "no\r\n"}};
  answer = desktop::IsDefaultBrowser(install, scripted);
  assert(!answer.is_default && answer.problem.empty());
  replies = {{true, 1, "yes\n"}};
  assert(!desktop::IsDefaultBrowser(install, scripted).is_default);
  replies = {{false, -1, "yes\n"}};
  answer = desktop::IsDefaultBrowser(install, scripted);
  assert(!answer.is_default && !answer.problem.empty());
  replies = {{true, 0, "yes please\n"}};
  answer = desktop::IsDefaultBrowser(install, scripted);
  assert(!answer.is_default && !answer.problem.empty());
  replies = {{true, 0, ""}};
  assert(!desktop::IsDefaultBrowser(install, scripted).is_default);

  calls.clear();
  replies = {{true, 0, ""}, {true, 0, "yes\n"}};
  answer = desktop::SetAsDefaultBrowser(install, scripted);
  assert(answer.is_default && answer.problem.empty() && (calls == Calls{set, check}));
  calls.clear();
  replies = {{true, 2, ""}};
  answer = desktop::SetAsDefaultBrowser(install, scripted);
  assert(!answer.is_default && !answer.problem.empty() && calls == Calls{set});
  calls.clear();
  replies = {{false, -1, ""}};
  answer = desktop::SetAsDefaultBrowser(install, scripted);
  assert(!answer.is_default && calls == Calls{set});
  replies = {{true, 0, ""}, {true, 0, "no\n"}};
  answer = desktop::SetAsDefaultBrowser(install, scripted);
  assert(!answer.is_default && answer.problem == "The desktop kept another default browser");
  assert(replies.empty());

  const std::string state = root + "/default";
  const std::string log = root + "/calls";
  Write(tool,
        "#!/bin/sh\necho \"$*\" >> '" + log + "'\ncase \"$1 $2\" in\n"
        "  'check default-web-browser') if [ \"$(cat '" + state + "' 2>/dev/null)\" = \"$3\" ]; then echo yes; else echo no; fi ;;\n"
        "  'set default-web-browser') printf %s \"$3\" > '" + state + "' ;;\n"
        "  *) exit 2 ;;\nesac\n",
        0755);
  assert(!desktop::IsDefaultBrowser(install, &Spawn).is_default);
  assert(desktop::SetAsDefaultBrowser(install, &Spawn).is_default);
  assert(desktop::IsDefaultBrowser(install, &Spawn).is_default);
  assert(Slurp(state) == "ray.desktop");
  assert(Slurp(log) == "check default-web-browser ray.desktop\nset default-web-browser ray.desktop\n"
                       "check default-web-browser ray.desktop\ncheck default-web-browser ray.desktop\n");
  Write(tool, "#!/bin/sh\nexit 4\n", 0755);
  assert(!desktop::SetAsDefaultBrowser(install, &Spawn).is_default);
  assert(!desktop::IsDefaultBrowser(install, &Spawn).is_default);
}

void Login(const std::string& root) {
  desktop::Install install = Installed(root);
  const std::string folder = install.autostart_directory;
  const std::string entry = folder + "/ray.desktop";
  assert(desktop::LoginStatusName(desktop::LoginStatus::kEnabled) == "enabled");
  assert(desktop::LoginStatusName(desktop::LoginStatus::kNotRegistered) == "notRegistered");
  assert(desktop::LoginStatusName(desktop::LoginStatus::kNotFound) == "notFound");

  assert(desktop::LaunchAtLoginStatus(install) == desktop::LoginStatus::kNotRegistered);
  assert(desktop::SetLaunchAtLogin(install, false).ok);
  assert(!Exists(root + "/home/config"));

  assert(desktop::SetLaunchAtLogin(install, true).ok);
  assert(Slurp(entry) == "[Desktop Entry]\nType=Application\nName=Ray\nExec=" + install.launcher +
                             "\nIcon=ray\nTerminal=false\nX-GNOME-Autostart-enabled=true\n");
  assert(Slurp(entry) == desktop::AutostartEntry(install));
  assert(Mode(entry) == 0644);
  assert(Mode(folder) == 0700 && Mode(root + "/home/config") == 0700);
  assert(Listing(folder) == std::vector<std::string>{"ray.desktop"});
  assert(desktop::LaunchAtLoginStatus(install) == desktop::LoginStatus::kEnabled);
  assert(desktop::SetLaunchAtLogin(install, true).ok);
  assert(Listing(folder) == std::vector<std::string>{"ray.desktop"});

  Write(entry, desktop::AutostartEntry(install) + "Hidden=true\n");
  assert(desktop::LaunchAtLoginStatus(install) == desktop::LoginStatus::kNotRegistered);
  Write(entry, "[Desktop Entry]\nType=Application\nExec=" + install.launcher + "\nX-GNOME-Autostart-enabled=false\n");
  assert(desktop::LaunchAtLoginStatus(install) == desktop::LoginStatus::kNotRegistered);
  Write(entry, "[Desktop Entry]\nType=Application\nExec=" + install.launcher + " --flag\n");
  assert(desktop::LaunchAtLoginStatus(install) == desktop::LoginStatus::kEnabled);
  Write(entry, "[Desktop Entry]\nType=Application\nExec=" + root + "/other/ray\n");
  assert(desktop::LaunchAtLoginStatus(install) == desktop::LoginStatus::kNotRegistered);
  Write(entry, "[Desktop Entry]\nType=Application\n");
  assert(desktop::LaunchAtLoginStatus(install) == desktop::LoginStatus::kNotRegistered);
  Write(entry, "garbage");
  assert(desktop::LaunchAtLoginStatus(install) == desktop::LoginStatus::kNotRegistered);
  assert(desktop::SetLaunchAtLogin(install, true).ok);
  assert(desktop::LaunchAtLoginStatus(install) == desktop::LoginStatus::kEnabled);

  assert(unlink(entry.c_str()) == 0);
  const std::string elsewhere = root + "/elsewhere.desktop";
  Write(elsewhere, "keep me\n");
  assert(symlink(elsewhere.c_str(), entry.c_str()) == 0);
  assert(desktop::SetLaunchAtLogin(install, true).ok);
  assert(Slurp(elsewhere) == "keep me\n");
  assert(Mode(entry) == 0644 && Slurp(entry) == desktop::AutostartEntry(install));
  assert(symlink(elsewhere.c_str(), (folder + "/.ray.desktop." + std::to_string(getpid()) + ".3.tmp").c_str()) == 0);
  assert(desktop::SetLaunchAtLogin(install, true).ok);
  assert(Slurp(elsewhere) == "keep me\n");

  assert(desktop::SetLaunchAtLogin(install, false).ok);
  assert(!Exists(entry));
  assert(desktop::LaunchAtLoginStatus(install) == desktop::LoginStatus::kNotRegistered);
  assert(desktop::SetLaunchAtLogin(install, false).ok);

  assert(mkdir(entry.c_str(), 0755) == 0);
  Write(entry + "/inside", "x");
  auto change = desktop::SetLaunchAtLogin(install, true);
  assert(!change.ok && change.code == "ERR_LOGIN_ITEM" && !change.message.empty());
  assert(Listing(folder).size() == 2);
  assert(!desktop::SetLaunchAtLogin(install, false).ok);
  assert(desktop::LaunchAtLoginStatus(install) == desktop::LoginStatus::kNotRegistered);

  desktop::Install blocked = install;
  blocked.autostart_directory = root + "/blocked/autostart";
  Write(root + "/blocked", "a file\n");
  assert(!desktop::SetLaunchAtLogin(blocked, true).ok);
  assert(desktop::SetLaunchAtLogin(blocked, false).ok);
  assert(desktop::LaunchAtLoginStatus(blocked) == desktop::LoginStatus::kNotRegistered);

  desktop::Install linked = install;
  linked.autostart_directory = root + "/dotfiles-link/autostart";
  assert(mkdir((root + "/dotfiles").c_str(), 0755) == 0);
  assert(symlink((root + "/dotfiles").c_str(), (root + "/dotfiles-link").c_str()) == 0);
  assert(desktop::SetLaunchAtLogin(linked, true).ok);
  assert(Slurp(root + "/dotfiles/autostart/ray.desktop") == desktop::AutostartEntry(install));
  assert(desktop::LaunchAtLoginStatus(linked) == desktop::LoginStatus::kEnabled);

  desktop::Install homeless = install;
  homeless.autostart_directory.clear();
  assert(desktop::LaunchAtLoginStatus(homeless) == desktop::LoginStatus::kNotFound);
  assert(!desktop::SetLaunchAtLogin(homeless, true).ok && !desktop::SetLaunchAtLogin(homeless, false).ok);
  homeless.autostart_directory = "relative/autostart";
  assert(desktop::LaunchAtLoginStatus(homeless) == desktop::LoginStatus::kNotFound);
  assert(!desktop::SetLaunchAtLogin(homeless, true).ok);

  desktop::Install raw = install;
  raw.autostart_directory = root + "/raw/autostart";
  raw.launcher = root + "/out/bin/ray";
  assert(desktop::LaunchAtLoginStatus(raw) == desktop::LoginStatus::kNotFound);
  change = desktop::SetLaunchAtLogin(raw, true);
  assert(!change.ok && change.message == "This copy of Ray has no launcher to start at login");
  assert(!Exists(root + "/raw"));
  Write(raw.launcher, "#!/bin/sh\n", 0644);
  assert(desktop::LaunchAtLoginStatus(raw) == desktop::LoginStatus::kNotFound);
  raw.launcher.clear();
  assert(desktop::LaunchAtLoginStatus(raw) == desktop::LoginStatus::kNotFound);
  assert(!desktop::SetLaunchAtLogin(raw, true).ok);

  desktop::Install spaced = install;
  spaced.autostart_directory = root + "/spaced/autostart";
  spaced.launcher = root + "/My Apps $1 100%/bin/ray";
  spaced.executable.clear();
  Write(spaced.launcher, "#!/bin/sh\n", 0755);
  assert(desktop::SetLaunchAtLogin(spaced, true).ok);
  assert(desktop::LaunchAtLoginStatus(spaced) == desktop::LoginStatus::kEnabled);
  assert(desktop::LaunchAtLoginStatus(install) == desktop::LoginStatus::kNotRegistered);
  spaced.launcher = root + "/new\nline/ray";
  Write(spaced.launcher, "#!/bin/sh\n", 0755);
  assert(desktop::LaunchAtLoginStatus(spaced) == desktop::LoginStatus::kNotFound);
  assert(!desktop::SetLaunchAtLogin(spaced, true).ok);
}

void Schemes() {
  for (const char* allowed : {"mailto", "MAILTO", "https", "http", "tel", "x-scheme+handler.v2", "zoommtg"}) {
    assert(desktop::ExternalSchemeAllowed(allowed));
  }
  for (const char* denied : {"", "file", "FILE", "javascript", "JavaScript", "data", "blob", "about", "view-source",
                             "chrome", "chrome-extension", "chrome-untrusted", "devtools", "filesystem", "vbscript",
                             "1mail", "mail to", "mail:to", "-mail", "ma\nil"}) {
    assert(!desktop::ExternalSchemeAllowed(denied));
  }
  assert(!desktop::ExternalSchemeAllowed(std::string(65, 'a')));
  assert(!desktop::ExternalSchemeAllowed(std::string("ma\0il", 5)));
}

}

int main(int argc, char** argv) {
  assert(argc == 3);
  const std::string scenario = argv[1];
  const std::string root = argv[2];
  if (scenario == "entries") Entries();
  else if (scenario == "installed") InstalledEntries(root);
  else if (scenario == "default-browser") DefaultBrowser(root);
  else if (scenario == "login") Login(root);
  else if (scenario == "schemes") Schemes();
  else return 2;
  std::puts("ok");
  return 0;
}
