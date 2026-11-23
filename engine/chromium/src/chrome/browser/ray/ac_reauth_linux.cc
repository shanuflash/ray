#include "chrome/browser/ray/ac_reauth.h"
#include "chrome/browser/ray/ac_reauth_linux.h"

#include <cstdint>
#include <string>
#include <utility>

#include "ray/core/ac_launch_switches.h"
#include "base/check.h"
#include "base/functional/bind.h"
#include "base/functional/callback.h"
#include "base/functional/callback_helpers.h"
#include "base/memory/scoped_refptr.h"
#include "base/memory/weak_ptr.h"
#include "base/strings/string_number_conversions.h"
#include "base/task/sequenced_task_runner.h"
#include "base/time/time.h"
#include "chrome/browser/ray/ac_engine.h"
#include "chrome/browser/ray/ac_reauth_linux_policy.h"
#include "components/dbus/thread_linux/dbus_thread_linux.h"
#include "content/public/browser/browser_thread.h"
#include "dbus/bus.h"
#include "dbus/message.h"
#include "dbus/object_path.h"
#include "dbus/object_proxy.h"

namespace ray {
namespace {

using reauth_linux::Outcome;

ReauthFallback& Fallback() {
  static ReauthFallback* fallback = new ReauthFallback();
  return *fallback;
}

bool FallbackAvailable() {
  return Fallback().available && Fallback().confirm && Fallback().available.Run();
}

bool PolkitUnusable(reauth_linux::Availability availability) {
  return availability == reauth_linux::Availability::kNoPolkit ||
         availability == reauth_linux::Availability::kPolicyMissing;
}

std::string NextCancellation() {
  static uint64_t next = 0;
  return "ray-reauth-" + base::NumberToString(++next);
}

int64_t NowMs() {
  return (base::TimeTicks::Now() - base::TimeTicks()).InMilliseconds();
}

std::string UniqueName(scoped_refptr<dbus::Bus> bus) {
  if (!bus->Connect()) {
    return std::string();
  }
  return bus->GetConnectionName();
}

reauth_linux::PolkitReply ReadReply(dbus::Response* response,
                                    dbus::ErrorResponse* error) {
  reauth_linux::PolkitReply reply;
  if (error) {
    reply.error_name = error->GetErrorName();
    if (reply.error_name.empty()) {
      reply.error_name = "org.freedesktop.DBus.Error.Failed";
    }
    dbus::MessageReader(error).PopString(&reply.error_message);
    return reply;
  }
  if (!response) {
    return reply;
  }
  dbus::MessageReader reader(response);
  dbus::MessageReader result(nullptr);
  dbus::MessageReader details(nullptr);
  bool authorized = false;
  bool challenge = false;
  if (!reader.PopStruct(&result) || !result.PopBool(&authorized) ||
      !result.PopBool(&challenge) || !result.PopArray(&details)) {
    return reply;
  }
  while (details.HasMoreData()) {
    dbus::MessageReader entry(nullptr);
    std::string key;
    std::string value;
    if (!details.PopDictEntry(&entry) || !entry.PopString(&key) ||
        !entry.PopString(&value)) {
      return reply;
    }
    if (key == "polkit.dismissed" && value == "true") {
      reply.dismissed = true;
    }
  }
  reply.authorized = authorized;
  reply.challenge = challenge;
  reply.responded = true;
  return reply;
}

void WriteCheck(dbus::MethodCall* call,
                const std::string& unique_name,
                uint32_t flags,
                const std::string& cancellation) {
  dbus::MessageWriter writer(call);
  dbus::MessageWriter subject(nullptr);
  writer.OpenStruct(&subject);
  subject.AppendString("system-bus-name");
  dbus::MessageWriter subject_details(nullptr);
  subject.OpenArray("{sv}", &subject_details);
  dbus::MessageWriter name_entry(nullptr);
  subject_details.OpenDictEntry(&name_entry);
  name_entry.AppendString("name");
  name_entry.AppendVariantOfString(unique_name);
  subject_details.CloseContainer(&name_entry);
  subject.CloseContainer(&subject_details);
  writer.CloseContainer(&subject);
  writer.AppendString(reauth_linux::kPolkitAction);
  dbus::MessageWriter details(nullptr);
  writer.OpenArray("{ss}", &details);
  writer.CloseContainer(&details);
  writer.AppendUint32(flags);
  writer.AppendString(cancellation);
}

using Probed = base::OnceCallback<void(bool, std::string)>;

void FinishProbe(Probed done, reauth_linux::Availability availability) {
  if (PolkitUnusable(availability) && FallbackAvailable()) {
    return std::move(done).Run(true, "loginPassword");
  }
  std::move(done).Run(availability == reauth_linux::Availability::kAvailable,
                      reauth_linux::AvailabilityName(availability));
}

void ProbeAs(scoped_refptr<dbus::Bus> bus,
             Probed done,
             const std::string& unique_name) {
  if (unique_name.empty()) {
    return FinishProbe(std::move(done), reauth_linux::Availability::kNoPolkit);
  }
  dbus::ObjectProxy* authority = bus->GetObjectProxy(
      reauth_linux::kPolkitService,
      dbus::ObjectPath(reauth_linux::kPolkitPath));
  dbus::MethodCall call(reauth_linux::kPolkitInterface, "CheckAuthorization");
  WriteCheck(&call, unique_name, 0, std::string());
  authority->CallMethodWithErrorResponse(
      &call, static_cast<int>(reauth_linux::kProbeTimeoutMs),
      base::BindOnce(
          [](Probed done, dbus::Response* response,
             dbus::ErrorResponse* error) {
            FinishProbe(std::move(done),
                        reauth_linux::ClassifyProbe(ReadReply(response, error)));
          },
          std::move(done)));
}

class ReauthState : public ProfileState {
 public:
  explicit ReauthState(Profile* profile) : ProfileState(profile) {}

  void Start(const std::u16string& purpose,
             base::TimeDelta validity,
             base::OnceCallback<void(bool)> done) {
    if (grants_.Covers(NowMs(), validity.InMilliseconds())) {
      Report(purpose, Outcome::kGranted, true);
      return std::move(done).Run(true);
    }
    base::WeakPtr<ReauthState> self = weak_factory_.GetWeakPtr();
    Supersede();
    if (!self) {
      return std::move(done).Run(false);
    }
    if (done_) {
      Report(purpose, Outcome::kCancelled, false);
      return std::move(done).Run(false);
    }
    const uint64_t generation = ++generation_;
    done_ = std::move(done);
    using_fallback_ = false;
    purpose_ = purpose;
    validity_ = validity;
    cancellation_ = NextCancellation();
    bus_ = dbus_thread_linux::GetSharedSystemBus();
    if (!bus_) {
      return PolkitUnavailable(generation);
    }
    bus_->GetDBusTaskRunner()->PostTaskAndReplyWithResult(
        FROM_HERE, base::BindOnce(&UniqueName, bus_),
        base::BindOnce(&ReauthState::Check, self, generation));
  }

 private:
  void Release() override {
    weak_factory_.InvalidateWeakPtrs();
    CancelPending();
    done_.Reset();
    grants_.Clear();
  }

  void Supersede() {
    if (!done_) {
      return;
    }
    CancelPending();
    ++generation_;
    base::OnceCallback<void(bool)> older = std::move(done_);
    Report(purpose_, Outcome::kCancelled, false);
    using_fallback_ = false;
    std::move(older).Run(false);
  }

  void CancelPending() {
    if (!std::exchange(prompting_, false) || !bus_ || cancellation_.empty()) {
      return;
    }
    dbus::ObjectProxy* authority = bus_->GetObjectProxy(
        reauth_linux::kPolkitService,
        dbus::ObjectPath(reauth_linux::kPolkitPath));
    dbus::MethodCall call(reauth_linux::kPolkitInterface,
                          "CancelCheckAuthorization");
    dbus::MessageWriter(&call).AppendString(cancellation_);
    authority->CallMethodWithErrorResponse(
        &call, dbus::ObjectProxy::TIMEOUT_USE_DEFAULT, base::DoNothing());
  }

  void Check(uint64_t generation, const std::string& unique_name) {
    if (generation != generation_ || !done_) {
      return;
    }
    if (unique_name.empty()) {
      return PolkitUnavailable(generation);
    }
    dbus::ObjectProxy* authority = bus_->GetObjectProxy(
        reauth_linux::kPolkitService,
        dbus::ObjectPath(reauth_linux::kPolkitPath));
    dbus::MethodCall call(reauth_linux::kPolkitInterface,
                          "CheckAuthorization");
    WriteCheck(&call, unique_name, reauth_linux::kAllowUserInteraction,
               cancellation_);
    prompting_ = true;
    authority->CallMethodWithErrorResponse(
        &call, static_cast<int>(reauth_linux::kPromptTimeoutMs),
        base::BindOnce(&ReauthState::Replied, weak_factory_.GetWeakPtr(),
                       generation));
  }

  void Replied(uint64_t generation,
               dbus::Response* response,
               dbus::ErrorResponse* error) {
    if (generation != generation_ || !done_) {
      return;
    }
    const reauth_linux::PolkitReply reply = ReadReply(response, error);
    if (!reply.error_name.empty() &&
        PolkitUnusable(reauth_linux::ClassifyProbe(reply))) {
      prompting_ = false;
      return PolkitUnavailable(generation);
    }
    const Outcome outcome = reauth_linux::Classify(reply);
    if (outcome == Outcome::kExpired) {
      CancelPending();
    }
    Finish(generation, outcome);
  }

  void PolkitUnavailable(uint64_t generation) {
    if (generation != generation_ || !done_) {
      return;
    }
    if (!FallbackAvailable()) {
      return Finish(generation, Outcome::kUnavailable);
    }
    using_fallback_ = true;
    Fallback().confirm.Run(
        profile(), purpose_,
        base::BindOnce(&ReauthState::FallbackAnswered,
                       weak_factory_.GetWeakPtr(), generation));
  }

  void FallbackAnswered(uint64_t generation, bool granted, bool cancelled) {
    Finish(generation, granted     ? Outcome::kGranted
                       : cancelled ? Outcome::kCancelled
                                   : Outcome::kDenied);
  }

  void Finish(uint64_t generation, Outcome outcome) {
    if (generation != generation_ || !done_) {
      return;
    }
    const bool granted = outcome == Outcome::kGranted;
    if (granted && validity_.is_positive()) {
      grants_.Grant(NowMs());
    }
    base::OnceCallback<void(bool)> done = std::move(done_);
    prompting_ = false;
    cancellation_.clear();
    Report(purpose_, outcome, granted);
    using_fallback_ = false;
    std::move(done).Run(granted);
  }

  void Report(const std::u16string& purpose, Outcome outcome, bool granted) {
    Emit("reauth.requested", profile(),
         base::DictValue()
             .Set("purpose", purpose)
             .Set("granted", granted)
             .Set("result", reauth_linux::OutcomeName(outcome))
             .Set("method", using_fallback_ ? "loginPassword" : "polkit"));
  }

  scoped_refptr<dbus::Bus> bus_;
  base::OnceCallback<void(bool)> done_;
  std::u16string purpose_;
  base::TimeDelta validity_;
  std::string cancellation_;
  bool prompting_ = false;
  bool using_fallback_ = false;
  uint64_t generation_ = 0;
  reauth_linux::GrantWindow grants_;
  base::WeakPtrFactory<ReauthState> weak_factory_{this};
};

}

void SetReauthFallback(ReauthFallback fallback) {
  CHECK(content::BrowserThread::CurrentlyOn(content::BrowserThread::UI));
  Fallback() = std::move(fallback);
}

void ProbeReauth(base::OnceCallback<void(bool, std::string)> done) {
  CHECK(content::BrowserThread::CurrentlyOn(content::BrowserThread::UI));
  if (raycore::BackgroundInstance()) {
    return FinishProbe(std::move(done),
                       reauth_linux::Availability::kBackground);
  }
  scoped_refptr<dbus::Bus> bus = dbus_thread_linux::GetSharedSystemBus();
  if (!bus) {
    return FinishProbe(std::move(done), reauth_linux::Availability::kNoPolkit);
  }
  bus->GetDBusTaskRunner()->PostTaskAndReplyWithResult(
      FROM_HERE, base::BindOnce(&UniqueName, bus),
      base::BindOnce(&ProbeAs, bus, std::move(done)));
}

bool ReauthAvailable() {
  return !raycore::BackgroundInstance();
}

void Reauth(Profile* profile,
            device_reauth::DeviceAuthSource,
            const std::u16string& purpose,
            base::TimeDelta validity,
            base::OnceCallback<void(bool)> done) {
  CHECK(content::BrowserThread::CurrentlyOn(content::BrowserThread::UI));
  if (!profile || profile->IsOffTheRecord() || !ReauthAvailable()) {
    Emit("reauth.requested", profile,
         base::DictValue()
             .Set("purpose", purpose)
             .Set("granted", false)
             .Set("result",
                  reauth_linux::OutcomeName(Outcome::kUnavailable)));
    return std::move(done).Run(false);
  }
  StateFor<ReauthState>(profile).Start(purpose, validity, std::move(done));
}

}
