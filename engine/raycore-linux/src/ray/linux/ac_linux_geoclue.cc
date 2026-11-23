#include "ray/linux/ac_linux_geoclue.h"

#include <map>
#include <memory>
#include <optional>
#include <set>
#include <string>
#include <utility>

#include "ray/linux/ac_linux_geoclue_policy.h"
#include "base/functional/bind.h"
#include "base/functional/callback_helpers.h"
#include "base/memory/ref_counted.h"
#include "base/memory/weak_ptr.h"
#include "base/no_destructor.h"
#include "base/task/sequenced_task_runner.h"
#include "base/time/time.h"
#include "base/timer/timer.h"
#include "components/dbus/thread_linux/dbus_thread_linux.h"
#include "content/public/browser/browser_task_traits.h"
#include "content/public/browser/browser_thread.h"
#include "dbus/bus.h"
#include "dbus/message.h"
#include "dbus/object_path.h"
#include "dbus/object_proxy.h"
#include "services/device/public/cpp/geolocation/location_provider.h"
#include "services/device/public/mojom/geoposition.mojom.h"

extern std::unique_ptr<device::LocationProvider> (*g_ray_linux_location_provider)();

namespace ray {
namespace {

namespace geoclue = linux_geoclue;
using geoclue::Fix;

device::mojom::GeopositionResultPtr ResultOf(const std::optional<Fix>& fix) {
  if (!fix) {
    return device::mojom::GeopositionResult::NewError(device::mojom::GeopositionError::New(
        device::mojom::GeopositionErrorCode::kPositionUnavailable,
        "The system location service isn't available.", ""));
  }
  auto position = device::mojom::Geoposition::New();
  position->latitude = fix->latitude;
  position->longitude = fix->longitude;
  position->accuracy = fix->accuracy;
  if (fix->altitude) position->altitude = *fix->altitude;
  if (fix->heading) position->heading = *fix->heading;
  if (fix->speed) position->speed = *fix->speed;
  position->timestamp = fix->acquired_seconds > 0 ? base::Time::FromSecondsSinceUnixEpoch(fix->acquired_seconds)
                                                 : base::Time::Now();
  return device::mojom::GeopositionResult::NewPosition(std::move(position));
}

class Relay : public base::RefCountedThreadSafe<Relay> {
 public:
  using Deliver = base::RepeatingCallback<void(std::optional<Fix>)>;
  Relay(scoped_refptr<base::SequencedTaskRunner> runner, Deliver deliver, bool high_accuracy)
      : runner_(std::move(runner)), deliver_(std::move(deliver)), high_accuracy_(high_accuracy) {}
  void Send(std::optional<Fix> fix) { runner_->PostTask(FROM_HERE, base::BindOnce(deliver_, std::move(fix))); }
  bool high_accuracy() const { return high_accuracy_; }

 private:
  friend class base::RefCountedThreadSafe<Relay>;
  ~Relay() = default;
  scoped_refptr<base::SequencedTaskRunner> runner_;
  Deliver deliver_;
  bool high_accuracy_;
};

class GeoClue {
 public:
  static GeoClue& Get() {
    static base::NoDestructor<GeoClue> geoclue;
    return *geoclue;
  }

  void Watch(scoped_refptr<Relay> relay) {
    DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
    idle_timer_.Stop();
    relays_.insert(relay);
    Retune();
    if (latest_) return relay->Send(latest_);
    if (state_ == State::kUnavailable &&
        base::TimeTicks::Now() - unavailable_since_ < base::Seconds(geoclue::kRetryUnavailableSeconds)) {
      return relay->Send(std::nullopt);
    }
    first_fix_timer_.Start(FROM_HERE, base::Seconds(geoclue::kFirstFixSeconds),
                           base::BindOnce(&GeoClue::NoFirstFix, weak_factory_.GetWeakPtr()));
    if (state_ == State::kIdle || state_ == State::kUnavailable) Start(WantsHighAccuracy());
  }

  void Unwatch(scoped_refptr<Relay> relay) {
    DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
    relays_.erase(relay);
    Retune();
    if (relays_.empty()) {
      idle_timer_.Start(FROM_HERE, base::Seconds(geoclue::kIdleStopSeconds),
                        base::BindOnce(&GeoClue::Stop, weak_factory_.GetWeakPtr()));
    }
  }

  bool DeniedByDesktop() const { return state_ == State::kUnavailable && geoclue::DeniedByDesktop(reason_); }

 private:
  friend class base::NoDestructor<GeoClue>;
  enum class State { kIdle, kStarting, kRunning, kUnavailable };

  GeoClue() = default;

  dbus::ObjectProxy* Proxy(const dbus::ObjectPath& path) { return bus_->GetObjectProxy(geoclue::kService, path); }

  bool WantsHighAccuracy() const {
    for (const scoped_refptr<Relay>& relay : relays_) {
      if (relay->high_accuracy()) return true;
    }
    return false;
  }

  void Retune() {
    if (relays_.empty()) return;
    const bool wanted = WantsHighAccuracy();
    const geoclue::Retune step =
        geoclue::RetuneFor(state_ == State::kStarting || state_ == State::kRunning, high_accuracy_, wanted,
                           client_.IsValid() && client_.value() != "/", state_ == State::kRunning);
    if (step == geoclue::Retune::kNothing) return;
    high_accuracy_ = wanted;
    if (step == geoclue::Retune::kRemember) return;
    RequestAccuracy();
    if (step == geoclue::Retune::kRequestAndRestart) return Restart();
    restart_when_started_ = true;
  }

  void RequestAccuracy() {
    const unsigned level = geoclue::AccuracyLevel(high_accuracy_);
    SetProperty("RequestedAccuracyLevel", [level](dbus::MessageWriter& writer) { writer.AppendVariantOfUint32(level); });
  }

  void Restart() {
    state_ = State::kStarting;
    dbus::MethodCall stop(geoclue::kClient, "Stop");
    Proxy(client_)->CallMethod(&stop, geoclue::kCallTimeoutMs, base::DoNothing());
    dbus::MethodCall start(geoclue::kClient, "Start");
    Proxy(client_)->CallMethodWithErrorResponse(&start, geoclue::kCallTimeoutMs,
                                                base::BindOnce(&GeoClue::Started, session_.GetWeakPtr()));
  }

  void Start(bool high_accuracy) {
    bus_ = dbus_thread_linux::GetSharedSystemBus();
    if (!bus_) return GiveUp("no system bus");
    EndSession();
    state_ = State::kStarting;
    high_accuracy_ = high_accuracy;
    dbus::MethodCall call(geoclue::kManager, "GetClient");
    Proxy(dbus::ObjectPath(geoclue::kManagerPath))
        ->CallMethodWithErrorResponse(&call, geoclue::kCallTimeoutMs,
                                      base::BindOnce(&GeoClue::GotClient, session_.GetWeakPtr()));
  }

  static std::string ErrorText(dbus::ErrorResponse* error, std::string_view fallback) {
    if (!error) return std::string(fallback);
    std::string message;
    dbus::MessageReader(error).PopString(&message);
    return error->GetErrorName() + ": " + message;
  }

  void GotClient(dbus::Response* response, dbus::ErrorResponse* error) {
    dbus::ObjectPath path;
    if (!response || !dbus::MessageReader(response).PopObjectPath(&path)) {
      return GiveUp(ErrorText(error, "GeoClue didn't answer"));
    }
    client_ = path;
    SetProperty("DesktopId", [](dbus::MessageWriter& writer) { writer.AppendVariantOfString(geoclue::kDesktopId); });
    RequestAccuracy();
    Proxy(client_)->ConnectToSignal(geoclue::kClient, "LocationUpdated",
                                    base::BindRepeating(&GeoClue::LocationUpdated, session_.GetWeakPtr()),
                                    base::DoNothing());
    dbus::MethodCall start(geoclue::kClient, "Start");
    Proxy(client_)->CallMethodWithErrorResponse(&start, geoclue::kCallTimeoutMs,
                                                base::BindOnce(&GeoClue::Started, session_.GetWeakPtr()));
  }

  template <typename Write>
  void SetProperty(const char* name, Write write) {
    dbus::MethodCall call(geoclue::kProperties, "Set");
    dbus::MessageWriter writer(&call);
    writer.AppendString(geoclue::kClient);
    writer.AppendString(name);
    write(writer);
    Proxy(client_)->CallMethod(&call, geoclue::kCallTimeoutMs, base::DoNothing());
  }

  void Started(dbus::Response* response, dbus::ErrorResponse* error) {
    if (state_ != State::kStarting || !client_.IsValid()) return;
    if (!response) return GiveUp(ErrorText(error, "GeoClue didn't start"));
    if (std::exchange(restart_when_started_, false)) return Restart();
    state_ = State::kRunning;
    dbus::MethodCall call(geoclue::kProperties, "Get");
    dbus::MessageWriter writer(&call);
    writer.AppendString(geoclue::kClient);
    writer.AppendString("Location");
    Proxy(client_)->CallMethod(
        &call, geoclue::kCallTimeoutMs,
        base::BindOnce(
            [](base::WeakPtr<GeoClue> self, dbus::Response* response) {
              dbus::ObjectPath location;
              if (self && response && dbus::MessageReader(response).PopVariantOfObjectPath(&location) &&
                  location.value() != "/") {
                self->ReadFix(location);
              }
            },
            session_.GetWeakPtr()));
  }

  void LocationUpdated(dbus::Signal* signal) {
    dbus::MessageReader reader(signal);
    dbus::ObjectPath old_location;
    dbus::ObjectPath location;
    if (reader.PopObjectPath(&old_location) && reader.PopObjectPath(&location)) ReadFix(location);
  }

  void ReadFix(const dbus::ObjectPath& location) {
    dbus::MethodCall call(geoclue::kProperties, "GetAll");
    dbus::MessageWriter(&call).AppendString(geoclue::kLocation);
    Proxy(location)->CallMethod(&call, geoclue::kCallTimeoutMs,
                                base::BindOnce(&GeoClue::FixRead, session_.GetWeakPtr()));
  }

  void FixRead(dbus::Response* response) {
    if (!response) return;
    dbus::MessageReader reader(response);
    dbus::MessageReader properties(nullptr);
    if (!reader.PopArray(&properties)) return;
    std::map<std::string, double> values;
    while (properties.HasMoreData()) {
      dbus::MessageReader entry(nullptr);
      std::string name;
      double value = 0;
      if (!properties.PopDictEntry(&entry) || !entry.PopString(&name)) return;
      if (entry.PopVariantOfDouble(&value)) values[name] = value;
    }
    std::optional<Fix> fix = geoclue::FixFrom(values);
    if (!fix) return;
    fix->acquired_seconds = base::Time::Now().InSecondsFSinceUnixEpoch();
    latest_ = fix;
    first_fix_timer_.Stop();
    for (const scoped_refptr<Relay>& relay : relays_) relay->Send(latest_);
  }

  void NoFirstFix() {
    if (latest_) return;
    for (const scoped_refptr<Relay>& relay : relays_) relay->Send(std::nullopt);
  }

  void EndSession() {
    session_.InvalidateWeakPtrs();
    restart_when_started_ = false;
  }

  void GiveUp(const std::string& reason) {
    EndSession();
    state_ = State::kUnavailable;
    unavailable_since_ = base::TimeTicks::Now();
    reason_ = reason;
    latest_.reset();
    client_ = dbus::ObjectPath();
    first_fix_timer_.Stop();
    for (const scoped_refptr<Relay>& relay : relays_) relay->Send(std::nullopt);
  }

  void Stop() {
    if (state_ != State::kRunning && state_ != State::kStarting) return;
    if (client_.IsValid() && client_.value() != "/") {
      dbus::MethodCall call(geoclue::kClient, "Stop");
      Proxy(client_)->CallMethod(&call, geoclue::kCallTimeoutMs, base::DoNothing());
    }
    EndSession();
    state_ = State::kIdle;
    latest_.reset();
    client_ = dbus::ObjectPath();
  }

  scoped_refptr<dbus::Bus> bus_;
  State state_ = State::kIdle;
  bool high_accuracy_ = false;
  bool restart_when_started_ = false;
  dbus::ObjectPath client_;
  std::optional<Fix> latest_;
  base::TimeTicks unavailable_since_;
  std::string reason_;
  std::set<scoped_refptr<Relay>> relays_;
  base::OneShotTimer first_fix_timer_;
  base::OneShotTimer idle_timer_;
  base::WeakPtrFactory<GeoClue> session_{this};
  base::WeakPtrFactory<GeoClue> weak_factory_{this};
};

class GeoClueLocationProvider : public device::LocationProvider {
 public:
  GeoClueLocationProvider() = default;
  ~GeoClueLocationProvider() override { StopProvider(); }

  void FillDiagnostics(device::mojom::GeolocationDiagnostics&) override {}
  void SetUpdateCallback(const LocationProviderUpdateCallback& callback) override { callback_ = callback; }

  void StartProvider(bool enable_high_accuracy) override {
    if (relay_ && relay_->high_accuracy() == enable_high_accuracy) return;
    StopProvider();
    relay_ = base::MakeRefCounted<Relay>(base::SequencedTaskRunner::GetCurrentDefault(),
                                         base::BindRepeating(&GeoClueLocationProvider::Delivered,
                                                             weak_factory_.GetWeakPtr()),
                                         enable_high_accuracy);
    content::GetUIThreadTaskRunner({})->PostTask(
        FROM_HERE, base::BindOnce([](scoped_refptr<Relay> relay) { GeoClue::Get().Watch(std::move(relay)); }, relay_));
  }

  void StopProvider() override {
    if (!relay_) return;
    content::GetUIThreadTaskRunner({})->PostTask(
        FROM_HERE,
        base::BindOnce([](scoped_refptr<Relay> relay) { GeoClue::Get().Unwatch(std::move(relay)); }, std::move(relay_)));
  }

  const device::mojom::GeopositionResult* GetPosition() override { return position_.get(); }
  void OnPermissionGranted() override {}

 private:
  void Delivered(std::optional<Fix> fix) {
    position_ = ResultOf(fix);
    if (callback_) callback_.Run(this, position_.Clone());
  }

  scoped_refptr<Relay> relay_;
  LocationProviderUpdateCallback callback_;
  device::mojom::GeopositionResultPtr position_;
  base::WeakPtrFactory<GeoClueLocationProvider> weak_factory_{this};
};

}

std::unique_ptr<device::LocationProvider> CreateLinuxLocationProvider() {
  return std::make_unique<GeoClueLocationProvider>();
}

void InstallLinuxLocationProvider() {
  g_ray_linux_location_provider = &CreateLinuxLocationProvider;
}

std::string LinuxLocationPermission() {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  return GeoClue::Get().DeniedByDesktop() ? "servicesOff" : "granted";
}

}
