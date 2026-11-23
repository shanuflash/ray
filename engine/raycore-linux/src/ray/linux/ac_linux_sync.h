#ifndef RAY_LINUX_AC_LINUX_SYNC_H_
#define RAY_LINUX_AC_LINUX_SYNC_H_

#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "ray/linux/ac_linux_sync_crypto.h"
#include "ray/linux/ac_linux_sync_json.h"
#include "ray/linux/ac_linux_sync_keystore.h"

namespace ray::linux_sync {

enum class Route {
  kCore,
  kLeased,
  kDisclose,
  kChooseFolder,
  kSaveKit,
  kReveal,
  kPasswords,
  kClaim,
  kRelease,
  kNothing,
};

struct Method {
  const char* name;
  Route route;
};

inline constexpr Method kMethods[] = {
    {"RaySync.folderInfo", Route::kCore},
    {"RaySync.chooseFolder", Route::kChooseFolder},
    {"RaySync.deviceName", Route::kCore},
    {"RaySync.status", Route::kCore},
    {"RaySync.createPhrase", Route::kLeased},
    {"RaySync.enterPhrase", Route::kLeased},
    {"RaySync.unlock", Route::kLeased},
    {"RaySync.forget", Route::kLeased},
    {"RaySync.chainStatus", Route::kCore},
    {"RaySync.createChain", Route::kLeased},
    {"RaySync.write", Route::kLeased},
    {"RaySync.read", Route::kLeased},
    {"RaySync.remove", Route::kLeased},
    {"RaySync.deleteChain", Route::kLeased},
    {"RaySync.sealLocal", Route::kLeased},
    {"RaySync.openLocal", Route::kLeased},
    {"RaySync.recoveryWords", Route::kDisclose},
    {"RaySync.qrCode", Route::kDisclose},
    {"RaySync.copyRecoveryPhrase", Route::kDisclose},
    {"RaySync.saveRecoveryKit", Route::kSaveKit},
    {"RaySync.recoveryKitPreview", Route::kNothing},
    {"RaySync.copyRecoveryKit", Route::kNothing},
    {"RaySync.shareRecoveryKit", Route::kNothing},
    {"RaySync.revealFolder", Route::kReveal},
    {"RaySync.readPasswords", Route::kPasswords},
    {"RaySync.savePassword", Route::kPasswords},
    {"RaySync.claimAuthority", Route::kClaim},
    {"RaySync.releaseAuthority", Route::kRelease},
};

inline constexpr int64_t kAuthorityLeaseMs = 30000;
inline constexpr int64_t kDisclosureValidityMs = 60000;
inline constexpr size_t kMaxPayloadBytes = 32u * 1024 * 1024;
inline constexpr size_t kMaxPhraseBytes = 4096;
inline constexpr size_t kMaxScopeBytes = 512;
inline constexpr size_t kMaxKnownIds = 200000;
inline constexpr char kLocalScopeTag[] = "local";
inline constexpr char kLocalFileId[] = "state";
inline constexpr char kKitTextName[] = "Ray Recovery Kit.txt";
inline constexpr size_t kMaxProfileBytes = 256;
inline constexpr size_t kMaxLoginOriginBytes = 2048;
inline constexpr size_t kMaxLoginUsernameBytes = 1024;
inline constexpr size_t kMaxLoginPasswordBytes = 65536;
inline constexpr size_t kMaxSealedPasswordBytes = 131072;
inline constexpr size_t kMaxSyncedFieldBytes = 65536;

std::optional<Route> RouteOf(std::string_view method);

struct Outcome {
  static Outcome Value(JsonValue value);
  static Outcome Error(std::string code, std::string message);

  bool ok = true;
  JsonValue value;
  std::string code;
  std::string message;
};

class StoredLogin {
 public:
  StoredLogin() = default;
  StoredLogin(std::string realm, std::string username, std::string&& password, double created_ms);
  StoredLogin(StoredLogin&& other) noexcept;
  StoredLogin& operator=(StoredLogin&& other) noexcept;
  StoredLogin(const StoredLogin&) = delete;
  StoredLogin& operator=(const StoredLogin&) = delete;
  ~StoredLogin();

  std::string realm;
  std::string username;
  std::string password;
  double created_ms = 0;
};

struct LoginRead {
  bool complete = false;
  std::vector<StoredLogin> logins;
};

struct PasswordSave {
  std::string profile;
  std::string origin;
  std::string username;
  std::string sealed;
  bool replacing = false;
  bool holdable = true;
};

std::optional<std::string> LoginOrigin(std::string_view realm);
std::optional<std::string> ReadPasswordsProfile(const std::vector<JsonValue>& args);
std::optional<PasswordSave> ParsePasswordSave(const std::vector<JsonValue>& args);

class AuthorityLease {
 public:
  bool Claim(std::string_view caller, int64_t now_ms);
  void Release(std::string_view caller);
  bool Holds(std::string_view caller, int64_t now_ms) const;
  const std::string& holder() const { return holder_; }

 private:
  std::string holder_;
  int64_t expires_ms_ = 0;
};

class DisclosureWindow {
 public:
  bool Fresh(int64_t now_ms) const { return granted_ms_ && now_ms - *granted_ms_ < kDisclosureValidityMs; }
  void Grant(int64_t now_ms) { granted_ms_ = now_ms; }
  void Revoke() { granted_ms_.reset(); }

 private:
  std::optional<int64_t> granted_ms_;
};

struct CoreOptions {
  std::string default_folder;
  std::string device_name;
};

class SyncCore {
 public:
  SyncCore(std::unique_ptr<KeyStore> store, CoreOptions options);
  ~SyncCore();
  SyncCore(const SyncCore&) = delete;
  SyncCore& operator=(const SyncCore&) = delete;

  Outcome Dispatch(std::string_view method, const std::vector<JsonValue>& args, int64_t now_seconds);
  Outcome SaveKit(const std::string& path, std::string_view created);
  Outcome SealLogins(LoginRead read);
  std::optional<StoredLogin> OpenLogin(const PasswordSave& save);

  bool unlocked() const { return keys_ != nullptr; }
  bool unreadable() const { return unreadable_; }
  bool forgotten_since(uint64_t generation) const { return generation_ != generation; }
  uint64_t generation() const { return generation_; }
  const CoreOptions& options() const { return options_; }

 private:
  Outcome FolderInfo(const std::vector<JsonValue>& args);
  Outcome CreatePhrase(const std::vector<JsonValue>& args);
  Outcome EnterPhrase(const std::vector<JsonValue>& args);
  Outcome Unlock(const std::vector<JsonValue>& args);
  Outcome ResumeFromKeyring(const std::string& account, const std::string& folder);
  Outcome Forget(const std::vector<JsonValue>& args);
  Outcome ChainStatus(const std::vector<JsonValue>& args);
  Outcome CreateChain(const std::vector<JsonValue>& args);
  Outcome Write(const std::vector<JsonValue>& args);
  Outcome Read(const std::vector<JsonValue>& args, int64_t now_seconds);
  Outcome Remove(const std::vector<JsonValue>& args);
  Outcome DeleteChain(const std::vector<JsonValue>& args);
  Outcome SealLocal(const std::vector<JsonValue>& args);
  Outcome OpenLocal(const std::vector<JsonValue>& args);
  Outcome RecoveryWords();
  Outcome Status();

  void SetEntropy(std::optional<Bytes> entropy, std::string account = std::string());
  bool HoldsKeyFor(const std::string& account) const;
  void SaveHeldKey(int64_t now_seconds);

  std::unique_ptr<KeyStore> store_;
  CoreOptions options_;
  Bytes entropy_;
  std::unique_ptr<SyncKeys> keys_;
  bool unreadable_ = false;
  uint64_t generation_ = 0;
  KeyStatus last_key_status_ = KeyStatus::kNotFound;
  std::string key_account_;
  std::string unreadable_account_;
  std::string unsaved_account_;
  int64_t next_held_key_save_ = 0;
};

inline constexpr char kPasswordManagerHintFormat[] = "x-kde-passwordManagerHint";
inline constexpr char kPasswordManagerHintValue[] = "secret";

struct ClipboardWrite {
  std::string text;
  std::vector<std::pair<std::string, std::string>> raw;
  bool confidential = true;
};

ClipboardWrite PhraseClipboard(std::string words);

std::string KitText(const std::vector<std::string>& words, std::string_view created, std::string_view device);
std::string LossyUtf8(const Bytes& data);
std::string HostDeviceName();
std::string DefaultFolder(std::string_view home);

}

#endif
