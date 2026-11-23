#include "ray/linux/ac_linux_system.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <unistd.h>

#include <algorithm>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "ray/core/ac_launch_switches.h"
#include "ray/linux/ac_linux_appearance.h"
#include "ray/linux/ac_linux_desktop_core.h"
#include "ray/linux/ac_linux_hardware.h"
#include "ray/linux/ac_linux_launch_config.h"
#include "base/base_paths.h"
#include "base/files/file_path.h"
#include "base/files/scoped_file.h"
#include "base/functional/bind.h"
#include "base/location.h"
#include "base/logging.h"
#include "base/no_destructor.h"
#include "base/path_service.h"
#include "base/process/kill.h"
#include "base/process/launch.h"
#include "base/process/process.h"
#include "base/system/sys_info.h"
#include "base/task/sequenced_task_runner.h"
#include "base/task/thread_pool.h"
#include "base/threading/scoped_blocking_call.h"
#include "base/time/time.h"
#include "chrome/browser/platform_util.h"
#include "content/public/browser/browser_thread.h"
#include "content/public/browser/gpu_data_manager.h"
#include "gpu/config/gpu_info.h"
#include "ui/display/display.h"
#include "ui/display/screen.h"
#include "ui/native_theme/native_theme.h"
#include "url/gurl.h"

namespace raycore {

namespace {

namespace desktop = ray::linux_desktop;

using Done = base::OnceCallback<void(bool, base::Value)>;

constexpr int kPollMilliseconds = 50;
constexpr base::TimeDelta kReapLimit = base::Seconds(2);

void Fail(Done done, std::string_view code, std::string_view message) {
  std::move(done).Run(false, base::Value(base::DictValue().Set("code", code).Set("message", message)));
}

desktop::Install CurrentInstall() {
  const LinuxDesktopEnvironment& environment = LinuxDesktop();
  desktop::Install install;
  install.application_directories = environment.application_directories;
  install.autostart_directory = environment.autostart_directory.value_or(std::string());
  install.search_path = environment.search_path;
  base::FilePath executable;
  if (base::PathService::Get(base::FILE_EXE, &executable) && executable.IsAbsolute()) {
    install.executable = executable.value();
    install.launcher = executable.DirName().DirName().DirName().Append("bin").Append("ray").value();
  }
  return install;
}

desktop::ToolResult RunTool(const std::vector<std::string>& arguments, int seconds) {
  base::ScopedBlockingCall blocking(FROM_HERE, base::BlockingType::WILL_BLOCK);
  desktop::ToolResult result;
  int ends[2];
  if (pipe2(ends, O_CLOEXEC) != 0) return result;
  base::ScopedFD output_read(ends[0]);
  base::ScopedFD output_write(ends[1]);
  base::ScopedFD no_input(open("/dev/null", O_RDONLY | O_CLOEXEC));
  if (!no_input.is_valid() || fcntl(output_read.get(), F_SETFL, O_NONBLOCK) != 0) return result;
  base::LaunchOptions options;
  options.fds_to_remap.emplace_back(no_input.get(), STDIN_FILENO);
  options.fds_to_remap.emplace_back(output_write.get(), STDOUT_FILENO);
  options.new_process_group = true;
  base::Process process = base::LaunchProcess(arguments, options);
  output_write.reset();
  no_input.reset();
  if (!process.IsValid()) return result;
  const pid_t group = process.Pid();
  const base::TimeTicks deadline = base::TimeTicks::Now() + base::Seconds(seconds);
  char buffer[1024];
  const auto drain = [&] {
    while (true) {
      const ssize_t got = read(output_read.get(), buffer, sizeof(buffer));
      if (got < 0 && errno == EINTR) continue;
      if (got <= 0) return;
      const size_t room = desktop::kToolOutputLimit - std::min(desktop::kToolOutputLimit, result.output.size());
      result.output.append(buffer, std::min(room, static_cast<size_t>(got)));
    }
  };
  bool exited = false;
  int exit_code = -1;
  while (!exited && base::TimeTicks::Now() < deadline) {
    pollfd watched{output_read.get(), POLLIN, 0};
    poll(&watched, 1, kPollMilliseconds);
    drain();
    exited = process.WaitForExitWithTimeout(base::TimeDelta(), &exit_code);
  }
  if (!exited) {
    kill(-group, SIGKILL);
    if (!process.WaitForExitWithTimeout(kReapLimit, &exit_code)) base::EnsureProcessGetsReaped(std::move(process));
    return result;
  }
  drain();
  result.ran = true;
  result.exit_code = exit_code;
  return result;
}

scoped_refptr<base::SequencedTaskRunner> Worker() {
  static base::NoDestructor<scoped_refptr<base::SequencedTaskRunner>> worker(
      base::ThreadPool::CreateSequencedTaskRunner({base::MayBlock(), base::WithBaseSyncPrimitives(),
                                                   base::TaskPriority::USER_VISIBLE,
                                                   base::TaskShutdownBehavior::SKIP_ON_SHUTDOWN}));
  return *worker;
}

desktop::DefaultBrowserAnswer CheckDefaultBrowser(desktop::Install install) {
  return desktop::IsDefaultBrowser(install, &RunTool);
}

desktop::DefaultBrowserAnswer MakeDefaultBrowser(desktop::Install install) {
  return desktop::SetAsDefaultBrowser(install, &RunTool);
}

desktop::LoginStatus ReadLoginStatus(desktop::Install install) {
  base::ScopedBlockingCall blocking(FROM_HERE, base::BlockingType::MAY_BLOCK);
  return desktop::LaunchAtLoginStatus(install);
}

desktop::LoginChange ChangeLaunchAtLogin(desktop::Install install, bool enabled) {
  base::ScopedBlockingCall blocking(FROM_HERE, base::BlockingType::MAY_BLOCK);
  return desktop::SetLaunchAtLogin(install, enabled);
}

void ReplyDefaultBrowser(bool changing, Done done, desktop::DefaultBrowserAnswer answer) {
  if (changing && !answer.is_default) LOG(WARNING) << "Ray is not the default browser: " << answer.problem;
  std::move(done).Run(true, base::Value(answer.is_default));
}

void OpenExternalUrl(const base::ListValue& args, Done done) {
  if (args.size() != 1 || !args[0].is_string()) return Fail(std::move(done), "ERR_SYSTEM_REQUEST", "A URL is required");
  const std::string& text = args[0].GetString();
  const GURL url(text);
  if (text.size() > desktop::kExternalUrlLimit || !url.is_valid() || !desktop::ExternalSchemeAllowed(url.scheme())) {
    return std::move(done).Run(true, base::Value(false));
  }
  if (BackgroundInstance()) {
    LOG(INFO) << "Ray background instance: not opening a " << url.scheme() << " link in another app";
    return std::move(done).Run(true, base::Value(false));
  }
  platform_util::OpenExternal(url);
  std::move(done).Run(true, base::Value(true));
}

}

namespace {

namespace hardware = ray::linux_hardware;

static_assert(gpu::H264PROFILE_BASELINE == hardware::kH264First && gpu::H264PROFILE_MULTIVIEWHIGH == hardware::kH264Last);
static_assert(gpu::VP9PROFILE_PROFILE0 == hardware::kVp9First && gpu::VP9PROFILE_PROFILE3 == hardware::kVp9Last);
static_assert(gpu::HEVCPROFILE_MAIN == hardware::kHevcFirst && gpu::HEVCPROFILE_MAIN_STILL_PICTURE == hardware::kHevcLast);
static_assert(gpu::AV1PROFILE_PROFILE_MAIN == hardware::kAv1First && gpu::AV1PROFILE_PROFILE_PRO == hardware::kAv1Last);
static_assert(gpu::HEVCPROFILE_REXT == hardware::kHevcExtendedFirst &&
              gpu::HEVCPROFILE_HIGH_THROUGHPUT_SCREEN_EXTENDED == hardware::kHevcExtendedLast);

std::string ReadChip() {
  base::ScopedBlockingCall blocking(FROM_HERE, base::BlockingType::MAY_BLOCK);
  return base::SysInfo::CPUModelName();
}

void ReplyHardware(Done done, std::string chip) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  hardware::Hardware info;
  info.chip = std::move(chip);
  info.memory_bytes = base::SysInfo::AmountOfTotalPhysicalMemory().InBytes();
  if (content::GpuDataManager* manager = content::GpuDataManager::GetInstance()) {
    const gpu::GPUInfo gpu_info = manager->GetGPUInfo();
    info.gpu = hardware::GpuName(gpu_info.active_gpu().device_string, gpu_info.gl_renderer);
    for (const auto& supported : gpu_info.video_decode_accelerator_supported_profiles)
      hardware::NoteDecodeProfile(info.decode, static_cast<int>(supported.profile));
  }
  if (display::Screen* screen = display::Screen::Get()) {
    info.displays = screen->GetNumDisplays();
    for (const display::Display& attached : screen->GetAllDisplays())
      info.max_scale = std::max<double>(info.max_scale, attached.device_scale_factor());
  }
  std::move(done).Run(true, base::Value(hardware::Reply(info)));
}

namespace appearance = ray::linux_appearance;

std::optional<ui::NativeTheme::PreferredColorScheme> ColorSchemeOverride(appearance::Appearance mode) {
  switch (mode) {
    case appearance::Appearance::kDark:
      return ui::NativeTheme::PreferredColorScheme::kDark;
    case appearance::Appearance::kLight:
      return ui::NativeTheme::PreferredColorScheme::kLight;
    case appearance::Appearance::kAuto:
      return std::nullopt;
  }
  return std::nullopt;
}

}

bool LinuxSystemInvokes(std::string_view method) {
  return std::ranges::any_of(desktop::kSystemCapabilities, [method](const char* handled) { return method == handled; }) ||
         std::ranges::any_of(hardware::kHardwareCapabilities, [method](const char* handled) { return method == handled; });
}

void LinuxSystemInvoke(std::string_view method, const base::ListValue& args, Done done) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (method == "RayApp.openExternalURL") return OpenExternalUrl(args, std::move(done));
  if (method == hardware::kHardwareInfoCall) {
    if (!args.empty()) return Fail(std::move(done), "ERR_SYSTEM_REQUEST", "The hardware details take no arguments");
    Worker()->PostTaskAndReplyWithResult(FROM_HERE, base::BindOnce(&ReadChip),
                                         base::BindOnce(&ReplyHardware, std::move(done)));
    return;
  }
  if (method == hardware::kThinScrollBarsCall) {
    if (args.size() != 1 || !args[0].is_bool()) {
      return Fail(std::move(done), "ERR_SYSTEM_REQUEST", "The scroll bar style takes one boolean");
    }
    ui::NativeTheme::SetRayLinuxThinScrollBars(args[0].GetBool());
    return std::move(done).Run(true, base::Value());
  }
  if (method == appearance::kSetAppearanceCall) {
    const auto mode = args.size() == 1 && args[0].is_string() ? appearance::ParseAppearance(args[0].GetString()) : std::nullopt;
    if (!mode) return Fail(std::move(done), "ERR_SYSTEM_REQUEST", "The appearance is auto, light or dark");
    ui::NativeTheme::SetPreferredColorSchemeOverride(ColorSchemeOverride(*mode));
    return std::move(done).Run(true, base::Value());
  }
  const bool changing = method == "RaySystem.setAsDefaultBrowser";
  if (method == "RaySystem.isDefaultBrowser" || changing) {
    if (!args.empty()) return Fail(std::move(done), "ERR_SYSTEM_REQUEST", "The default browser calls take no arguments");
    if (BackgroundInstance()) {
      if (changing) LOG(INFO) << "Ray background instance: not setting the default browser";
      return std::move(done).Run(true, base::Value(false));
    }
    Worker()->PostTaskAndReplyWithResult(
        FROM_HERE, base::BindOnce(changing ? &MakeDefaultBrowser : &CheckDefaultBrowser, CurrentInstall()),
        base::BindOnce(&ReplyDefaultBrowser, changing, std::move(done)));
    return;
  }
  if (method == "RaySystem.launchAtLoginStatus") {
    if (!args.empty()) return Fail(std::move(done), "ERR_SYSTEM_REQUEST", "The login status takes no arguments");
    Worker()->PostTaskAndReplyWithResult(
        FROM_HERE, base::BindOnce(&ReadLoginStatus, CurrentInstall()),
        base::BindOnce([](Done done, desktop::LoginStatus status) {
          std::move(done).Run(true, base::Value(desktop::LoginStatusName(status)));
        }, std::move(done)));
    return;
  }
  if (method == "RaySystem.setLaunchAtLogin") {
    if (args.size() != 1 || !args[0].is_bool()) {
      return Fail(std::move(done), "ERR_SYSTEM_REQUEST", "Opening at login takes one boolean");
    }
    if (BackgroundInstance()) {
      LOG(INFO) << "Ray background instance: not changing launch at login";
      return std::move(done).Run(true, base::Value());
    }
    Worker()->PostTaskAndReplyWithResult(
        FROM_HERE, base::BindOnce(&ChangeLaunchAtLogin, CurrentInstall(), args[0].GetBool()),
        base::BindOnce([](Done done, desktop::LoginChange change) {
          if (!change.ok) return Fail(std::move(done), change.code, change.message);
          std::move(done).Run(true, base::Value());
        }, std::move(done)));
    return;
  }
  Fail(std::move(done), "ERR_UNKNOWN_CALL", "Unsupported system operation");
}

}
