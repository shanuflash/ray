#include "ray/linux/ac_linux_system_signals.h"

#include <utility>

#include "base/functional/bind.h"
#include "base/functional/callback_helpers.h"
#include "base/no_destructor.h"
#include "base/time/time.h"
#include "components/dbus/thread_linux/dbus_thread_linux.h"
#include "content/public/browser/browser_thread.h"
#include "dbus/bus.h"
#include "dbus/message.h"
#include "dbus/object_path.h"
#include "dbus/object_proxy.h"
#include "ui/base/idle/idle.h"

namespace ray {
namespace {

constexpr char kLogindService[] = "org.freedesktop.login1";
constexpr char kLogindPath[] = "/org/freedesktop/login1";
constexpr char kLogindManager[] = "org.freedesktop.login1.Manager";

}

LinuxSystemSignals& LinuxSystemSignals::Get() {
  static base::NoDestructor<LinuxSystemSignals> signals;
  return *signals;
}

LinuxSystemSignals::LinuxSystemSignals() = default;
LinuxSystemSignals::~LinuxSystemSignals() = default;

base::CallbackListSubscription LinuxSystemSignals::Subscribe(Listener listener) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  WatchSleep();
  return listeners_.Add(std::move(listener));
}

void LinuxSystemSignals::WatchSleep() {
  if (bus_) return;
  bus_ = dbus_thread_linux::GetSharedSystemBus();
  if (!bus_) return;
  dbus::ObjectProxy* logind = bus_->GetObjectProxy(kLogindService, dbus::ObjectPath(kLogindPath));
  logind->ConnectToSignal(kLogindManager, "PrepareForSleep",
                          base::BindRepeating(&LinuxSystemSignals::PrepareForSleep, weak_factory_.GetWeakPtr()),
                          base::DoNothing());
}

void LinuxSystemSignals::PrepareForSleep(dbus::Signal* signal) {
  bool starting = false;
  if (!dbus::MessageReader(signal).PopBool(&starting) || starting == asleep_) return;
  asleep_ = starting;
  Send(base::DictValue().Set("type", starting ? "sleep" : "wake"));
}

bool LinuxSystemSignals::Post(const std::string& name) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (name != "willSleep" && name != "didWake") return false;
  asleep_ = name == "willSleep";
  Send(base::DictValue().Set("type", asleep_ ? "sleep" : "wake"));
  return true;
}

void LinuxSystemSignals::WatchIdle(int watcher, const std::vector<double>& thresholds) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  const std::set<double> kept = linux_idle::CleanThresholds(thresholds);
  if (kept.empty()) {
    wanted_.erase(watcher);
  } else {
    wanted_[watcher] = kept;
  }
  std::set<double> all;
  for (const auto& [id, set] : wanted_) all.insert(set.begin(), set.end());
  idle_.Watch(all);
  for (double threshold : idle_.IdleAmong(kept)) {
    Send(base::DictValue().Set("type", "idle").Set("threshold", threshold).Set("idle", true));
  }
  poll_.Stop();
  if (!idle_.empty()) Poll();
}

void LinuxSystemSignals::Poll() {
  const double idle_seconds = static_cast<double>(ui::CalculateIdleTime());
  for (const auto& [threshold, idle] : idle_.Update(idle_seconds)) {
    Send(base::DictValue().Set("type", "idle").Set("threshold", threshold).Set("idle", idle));
  }
  if (idle_.empty()) return;
  poll_.Start(FROM_HERE, base::Seconds(idle_.NextCheckSeconds(idle_seconds)),
              base::BindOnce(&LinuxSystemSignals::Poll, weak_factory_.GetWeakPtr()));
}

void LinuxSystemSignals::Send(base::DictValue signal) {
  listeners_.Notify(signal);
}

}
