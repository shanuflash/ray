#ifndef RAY_LINUX_AC_LINUX_SYSTEM_SIGNALS_H_
#define RAY_LINUX_AC_LINUX_SYSTEM_SIGNALS_H_

#include <map>
#include <set>
#include <string>
#include <vector>

#include "ray/linux/ac_linux_idle_policy.h"
#include "base/callback_list.h"
#include "base/functional/callback.h"
#include "base/memory/scoped_refptr.h"
#include "base/memory/weak_ptr.h"
#include "base/no_destructor.h"
#include "base/timer/timer.h"
#include "base/values.h"

namespace dbus {
class Bus;
class Signal;
}

namespace ray {

class LinuxSystemSignals {
 public:
  using Listener = base::RepeatingCallback<void(const base::DictValue&)>;
  static LinuxSystemSignals& Get();
  LinuxSystemSignals(const LinuxSystemSignals&) = delete;
  LinuxSystemSignals& operator=(const LinuxSystemSignals&) = delete;

  base::CallbackListSubscription Subscribe(Listener listener);
  void WatchIdle(int watcher, const std::vector<double>& thresholds);
  bool Post(const std::string& name);

 private:
  friend class base::NoDestructor<LinuxSystemSignals>;
  LinuxSystemSignals();
  ~LinuxSystemSignals();
  void WatchSleep();
  void PrepareForSleep(dbus::Signal* signal);
  void Poll();
  void Send(base::DictValue signal);

  base::RepeatingCallbackList<void(const base::DictValue&)> listeners_;
  std::map<int, std::set<double>> wanted_;
  linux_idle::IdleWatch idle_;
  base::OneShotTimer poll_;
  scoped_refptr<dbus::Bus> bus_;
  bool asleep_ = false;
  base::WeakPtrFactory<LinuxSystemSignals> weak_factory_{this};
};

}

#endif
