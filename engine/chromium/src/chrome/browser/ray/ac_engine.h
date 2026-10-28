// Copyright 2026 Ray. Apache-2.0.

#ifndef CHROME_BROWSER_RAY_AC_ENGINE_H_
#define CHROME_BROWSER_RAY_AC_ENGINE_H_

#include <memory>
#include <string>
#include <string_view>

#include "base/memory/raw_ptr.h"
#include "base/scoped_observation.h"
#include "base/supports_user_data.h"
#include "base/values.h"
#include "chrome/browser/ray/public/ac_engine.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/profiles/profile_observer.h"

#define AC_ENGINE_CALL(name)                                            \
  extern "C" AC_ENGINE_EXPORT void name(                                \
      const char* profile_dir, const char* args_json,                   \
      ac_engine_reply_t reply, void* context)

namespace ray {

class Reply {
 public:
  Reply(ac_engine_reply_t reply, void* context);
  Reply(Reply&& other);
  Reply& operator=(Reply&& other);
  Reply(const Reply&) = delete;
  Reply& operator=(const Reply&) = delete;
  ~Reply();

  void Send(base::DictValue result);
  void Ok();
  void Error(std::string_view message);

 private:
  ac_engine_reply_t reply_;
  void* context_;
};

enum class OffTheRecord { kRefuse, kAllow };

class Call {
 public:
  Call(const char* profile_dir,
       const char* args_json,
       ac_engine_reply_t reply,
       void* context,
       OffTheRecord off_the_record = OffTheRecord::kRefuse);
  Call(const Call&) = delete;
  Call& operator=(const Call&) = delete;
  ~Call();

  explicit operator bool() const { return profile_ != nullptr; }
  Profile* profile() const { return profile_; }
  const base::DictValue& args() const { return args_; }
  std::string String(std::string_view key) const;
  bool Bool(std::string_view key, bool fallback = false) const;
  double Double(std::string_view key, double fallback = 0) const;

  Reply TakeReply() { return std::move(reply_); }

 private:
  Profile* profile_ = nullptr;
  base::DictValue args_;
  Reply reply_;
};

Profile* ProfileAt(std::string_view dir);

class ProfileState : public base::SupportsUserData::Data,
                     public ProfileObserver {
 public:
  explicit ProfileState(Profile* profile);
  ~ProfileState() override;

  Profile* profile() const { return profile_; }

 protected:
  virtual void Release() {}

 private:
  void OnProfileWillBeDestroyed(Profile* profile) override;

  raw_ptr<Profile> profile_;
  base::ScopedObservation<Profile, ProfileObserver> observation_{this};
};

template <typename T>
T& StateFor(Profile* profile) {
  static const int kKey = 0;
  auto* state = static_cast<T*>(profile->GetUserData(&kKey));
  if (!state) {
    auto owned = std::make_unique<T>(profile);
    state = owned.get();
    profile->SetUserData(&kKey, std::move(owned));
  }
  return *state;
}

void Emit(std::string_view topic, Profile* profile, base::DictValue payload);

}

#endif
