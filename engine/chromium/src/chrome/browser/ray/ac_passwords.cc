// Copyright 2026 Ray. Apache-2.0.

#include "chrome/browser/ray/ac_passwords.h"

#include <algorithm>
#include <memory>
#include <optional>
#include <utility>
#include <vector>

#include "base/files/file_path.h"
#include "base/functional/bind.h"
#include "base/functional/callback_helpers.h"
#include "base/memory/scoped_refptr.h"
#include "base/memory/weak_ptr.h"
#include "base/scoped_observation.h"
#include "base/strings/string_util.h"
#include "base/strings/utf_string_conversions.h"
#include "base/task/sequenced_task_runner.h"
#include "base/time/time.h"
#include "base/timer/timer.h"
#include "chrome/browser/extensions/api/passwords_private/passwords_private_delegate.h"
#include "chrome/browser/extensions/api/passwords_private/passwords_private_delegate_factory.h"
#include "chrome/browser/ray/ac_reauth.h"
#include "chrome/browser/ray/ac_sensitive_args.h"
#include "chrome/common/extensions/api/passwords_private.h"
#include "chrome/grit/generated_resources.h"
#include "components/password_manager/core/browser/export/export_progress_status.h"
#include "components/password_manager/core/browser/export/password_manager_exporter.h"
#include "components/password_manager/core/browser/ui/credential_ui_entry.h"
#include "components/password_manager/core/browser/ui/saved_passwords_presenter.h"
#include "components/password_manager/core/common/password_manager_constants.h"
#include "ui/base/l10n/l10n_util.h"

namespace ray {
namespace {

using extensions::PasswordsPrivateDelegate;
namespace pp = extensions::api::passwords_private;
using Entries = PasswordsPrivateDelegate::UiEntries;

constexpr int kSettleChecks = 20;
constexpr size_t kMaxSecretArgsBytes = 64 * 1024;
constexpr base::TimeDelta kSettleStep = base::Milliseconds(50);
constexpr base::TimeDelta kIdle = base::Seconds(60);

std::string WithoutSlash(std::string realm) {
  if (base::EndsWith(realm, "/")) {
    realm.pop_back();
  }
  return realm;
}

std::string OriginOf(const pp::PasswordUiEntry& entry) {
  return entry.affiliated_domains.empty()
             ? std::string()
             : WithoutSlash(entry.affiliated_domains[0].signon_realm);
}

const pp::PasswordUiEntry* Find(const Entries& entries,
                                const std::string& origin,
                                const std::string& username) {
  for (const pp::PasswordUiEntry& entry : entries) {
    if (!entry.is_passkey && entry.username == username &&
        OriginOf(entry) == origin) {
      return &entry;
    }
  }
  return nullptr;
}

std::string ExceptionOrigin(const pp::ExceptionEntry& entry) {
  return WithoutSlash(entry.urls.signon_realm.empty() ? entry.urls.link
                                                      : entry.urls.signon_realm);
}

const char* StatusName(password_manager::ExportProgressStatus status) {
  switch (status) {
    case password_manager::ExportProgressStatus::kNotStarted:
      return "notStarted";
    case password_manager::ExportProgressStatus::kInProgress:
      return "inProgress";
    case password_manager::ExportProgressStatus::kSucceeded:
      return "succeeded";
    case password_manager::ExportProgressStatus::kFailedCancelled:
      return "cancelled";
    case password_manager::ExportProgressStatus::kFailedWrite:
      return "writeFailed";
  }
  return "unknown";
}

class PasswordsState : public ProfileState {
 public:
  explicit PasswordsState(Profile* profile) : ProfileState(profile) {}

  base::WeakPtr<PasswordsState> GetWeakPtr() {
    return weak_factory_.GetWeakPtr();
  }

  PasswordsPrivateDelegate* Use(base::ScopedClosureRunner* busy) {
    if (!delegate_) {
      delegate_ = extensions::PasswordsPrivateDelegateFactory::
          GetForBrowserContext(profile(), true);
    }
    ++busy_;
    *busy = base::ScopedClosureRunner(base::BindOnce(
        &PasswordsState::Done, weak_factory_.GetWeakPtr()));
    idle_.Stop();
    return delegate_.get();
  }

  void Export(PasswordsPrivateDelegate* delegate,
              const base::FilePath& path,
              base::ScopedClosureRunner busy,
              Reply reply) {
    if (exporter_) {
      return reply.Send(base::DictValue().Set("status", "inProgress"));
    }
    export_reply_.emplace(std::move(reply));
    export_busy_ = std::move(busy);
    exporter_ = std::make_unique<password_manager::PasswordManagerExporter>(
        *delegate->GetSavedPasswordsPresenter(),
        base::BindRepeating(&PasswordsState::ExportProgress,
                            weak_factory_.GetWeakPtr()),
        base::DoNothing());
    exporter_->PreparePasswordsForExport();
    exporter_->SetDestination(path);
  }

 private:
  void Release() override {
    idle_.Stop();
    weak_factory_.InvalidateWeakPtrs();
    exporter_.reset();
    export_reply_.reset();
    export_busy_.ReplaceClosure(base::DoNothing());
    delegate_ = nullptr;
  }

  void Done() {
    if (--busy_ == 0) {
      idle_.Start(FROM_HERE, kIdle,
                  base::BindOnce(&PasswordsState::Idle, base::Unretained(this)));
    }
  }

  void Idle() {
    if (busy_ == 0) {
      delegate_ = nullptr;
    }
  }

  void ExportProgress(const password_manager::PasswordExportInfo& info) {
    Emit("passwords.export", profile(),
         base::DictValue()
             .Set("status", StatusName(info.status))
             .Set("folder", info.folder_name));
    if (info.status == password_manager::ExportProgressStatus::kInProgress ||
        info.status == password_manager::ExportProgressStatus::kNotStarted) {
      return;
    }
    if (export_reply_) {
      export_reply_->Send(
          base::DictValue().Set("status", StatusName(info.status)));
      export_reply_.reset();
    }
    base::SequencedTaskRunner::GetCurrentDefault()->DeleteSoon(
        FROM_HERE, std::move(exporter_));
    export_busy_.RunAndReset();
  }

  scoped_refptr<PasswordsPrivateDelegate> delegate_;
  int busy_ = 0;
  base::OneShotTimer idle_;
  std::unique_ptr<password_manager::PasswordManagerExporter> exporter_;
  std::optional<Reply> export_reply_;
  base::ScopedClosureRunner export_busy_;
  base::WeakPtrFactory<PasswordsState> weak_factory_{this};
};

struct Session {
  base::WeakPtr<PasswordsState> state;
  base::WeakPtr<PasswordsPrivateDelegate> delegate;
  base::ScopedClosureRunner busy;

  bool alive() const { return state && delegate; }
  Profile* profile() const { return state->profile(); }
};

std::optional<Session> Open(const Call& call) {
  PasswordsState& state = StateFor<PasswordsState>(call.profile());
  Session session{state.GetWeakPtr(), nullptr, {}};
  PasswordsPrivateDelegate* delegate = state.Use(&session.busy);
  if (!delegate) {
    return std::nullopt;
  }
  session.delegate = delegate->AsWeakPtr();
  return session;
}

using Then = base::OnceCallback<void(Session, Reply, const Entries&)>;

void WithList(Session session, Reply reply, Then then) {
  if (!session.alive()) {
    return reply.Error("closed");
  }
  base::WeakPtr<PasswordsPrivateDelegate> delegate = session.delegate;
  delegate->GetSavedPasswordsList(base::BindOnce(
      [](Session session, Reply reply, Then then, const Entries& entries) {
        if (!session.alive()) {
          return reply.Error("closed");
        }
        std::move(then).Run(std::move(session), std::move(reply), entries);
      },
      std::move(session), std::move(reply), std::move(then)));
}

using Authenticated = base::OnceCallback<void(Session, Reply, bool)>;

void Reauthenticate(Session session,
                    Reply reply,
                    int prompt,
                    base::TimeDelta validity,
                    Authenticated then) {
  Profile* profile = session.profile();
  Reauth(profile, device_reauth::DeviceAuthSource::kPasswordManager,
         l10n_util::GetStringUTF16(prompt), validity,
         base::BindOnce(
             [](Session session, Reply reply, Authenticated then,
                bool authenticated) {
               if (!session.alive()) {
                 return reply.Error("closed");
               }
               std::move(then).Run(std::move(session), std::move(reply),
                                   authenticated);
             },
             std::move(session), std::move(reply), std::move(then)));
}

using Check =
    base::RepeatingCallback<bool(PasswordsPrivateDelegate*, const Entries&)>;

void Settle(Session session, Reply reply, Check landed, int checks_left) {
  WithList(
      std::move(session), std::move(reply),
      base::BindOnce(
          [](Check landed, int checks_left, Session session, Reply reply,
             const Entries& entries) {
            if (landed.Run(session.delegate.get(), entries)) {
              return reply.Ok();
            }
            if (checks_left <= 1) {
              return reply.Error("The password store didn't take the change");
            }
            base::SequencedTaskRunner::GetCurrentDefault()->PostDelayedTask(
                FROM_HERE,
                base::BindOnce(&Settle, std::move(session), std::move(reply),
                               landed, checks_left - 1),
                kSettleStep);
          },
          landed, checks_left));
}

Check Saved(std::string origin, std::string username, Secret password) {
  return base::BindRepeating(
      [](const std::string& origin, const std::string& username,
         const Secret& password, PasswordsPrivateDelegate* delegate,
         const Entries& entries) {
        const pp::PasswordUiEntry* entry = Find(entries, origin, username);
        if (!entry || !password.present()) {
          return !!entry;
        }
        std::optional<password_manager::CredentialUIEntry> credential =
            delegate->GetCredentialFromId(entry->id);
        if (!credential) {
          return false;
        }
        std::string saved = base::UTF16ToUTF8(credential->password);
        const bool same = saved == password.value();
        Cleanse(saved);
        Cleanse(credential->password);
        return same;
      },
      std::move(origin), std::move(username), std::move(password));
}

std::u16string UTF16Of(const Secret& secret) {
  return base::UTF8ToUTF16(secret.value());
}

Check Gone(std::string origin, std::string username) {
  return base::BindRepeating(
      [](const std::string& origin, const std::string& username,
         PasswordsPrivateDelegate*, const Entries& entries) {
        return !Find(entries, origin, username);
      },
      std::move(origin), std::move(username));
}

}
}

using ray::Call;
using ray::Entries;
using ray::Reply;
using ray::Session;

#define AC_PASSWORDS_OPEN_WITH(json)                         \
  Call call(profile_dir, json, reply, context);              \
  if (!call) {                                               \
    return;                                                  \
  }                                                          \
  std::optional<Session> session = ray::Open(call);        \
  if (!session) {                                            \
    return call.TakeReply().Error("no password manager");    \
  }

#define AC_PASSWORDS_OPEN() AC_PASSWORDS_OPEN_WITH(args_json)

#define AC_PASSWORDS_SENSITIVE_ARGS(args)                                   \
  ray::SensitiveArgs args(args_json, ray::kMaxSecretArgsBytes);         \
  if (!args.dict()) {                                                       \
    return call.TakeReply().Error(args.too_large()                          \
                                      ? "arguments too large"               \
                                      : "arguments are not a JSON object"); \
  }                                                                         \
  if (args.dict()->FindBool("offTheRecord").value_or(false)) {              \
    return call.TakeReply().Error("not for a private session");             \
  }

AC_ENGINE_CALL(ac_passwords_list) {
  AC_PASSWORDS_OPEN();
  ray::WithList(
      std::move(*session), call.TakeReply(),
      base::BindOnce([](Session, Reply reply, const Entries& entries) {
        base::ListValue list;
        for (const auto& entry : entries) {
          if (entry.is_passkey) {
            continue;
          }
          list.Append(base::DictValue()
                          .Set("origin", ray::OriginOf(entry))
                          .Set("username", entry.username));
        }
        reply.Send(base::DictValue().Set("passwords", std::move(list)));
      }));
}

AC_ENGINE_CALL(ac_passwords_unlock) {
  AC_PASSWORDS_OPEN();
  ray::WithList(
      std::move(*session), call.TakeReply(),
      base::BindOnce([](Session session, Reply reply, const Entries& entries) {
        const bool any = std::ranges::any_of(
            entries, [](const auto& entry) { return !entry.is_passkey; });
        if (!any) {
          return reply.Send(base::DictValue().Set("unlocked", true));
        }
        ray::Reauthenticate(
            std::move(session), std::move(reply),
            IDS_PASSWORDS_PAGE_AUTHENTICATION_PROMPT_BIOMETRIC_SUFFIX,
            password_manager::constants::kPasswordManagerAuthValidity,
            base::BindOnce([](Session, Reply reply, bool unlocked) {
              reply.Send(base::DictValue().Set("unlocked", unlocked));
            }));
      }));
}

AC_ENGINE_CALL(ac_passwords_reveal) {
  AC_PASSWORDS_OPEN();
  ray::WithList(
      std::move(*session), call.TakeReply(),
      base::BindOnce(
          [](std::string origin, std::string username, Session session,
             Reply reply, const Entries& entries) {
            const auto* entry = ray::Find(entries, origin, username);
            if (!entry) {
              return reply.Error("No such password");
            }
            ray::Reauthenticate(
                std::move(session), std::move(reply),
                IDS_PASSWORDS_PAGE_AUTHENTICATION_PROMPT_BIOMETRIC_SUFFIX,
                password_manager::constants::kPasswordManagerAuthValidity,
                base::BindOnce(
                    [](int id, Session session, Reply reply,
                       bool authenticated) {
                      std::optional<password_manager::CredentialUIEntry>
                          credential;
                      if (authenticated) {
                        credential = session.delegate->GetCredentialFromId(id);
                      }
                      base::DictValue result;
                      if (credential) {
                        result.Set("password", credential->password);
                      } else {
                        result.Set("password", base::Value());
                      }
                      reply.Send(std::move(result));
                    },
                    entry->id));
          },
          call.String("origin"), call.String("username")));
}

AC_ENGINE_CALL(ac_passwords_add) {
  AC_PASSWORDS_OPEN_WITH(nullptr);
  AC_PASSWORDS_SENSITIVE_ARGS(args);
  const std::string origin = args.String("origin");
  std::optional<ray::Secret> secret = args.SecretAt("password");
  if (!secret) {
    return call.TakeReply().Error("bad arguments");
  }
  ray::Secret password = std::move(*secret);
  if (origin.empty() || password.value().empty()) {
    return call.TakeReply().Error("origin and password required");
  }
  ray::WithList(
      std::move(*session), call.TakeReply(),
      base::BindOnce(
          [](std::string origin, std::string username, ray::Secret password,
             Session session, Reply reply, const Entries&) {
            std::u16string password16 = ray::UTF16Of(password);
            const bool added = session.delegate->AddPassword(
                origin, base::UTF8ToUTF16(username), password16, u"", false);
            ray::Cleanse(password16);
            if (!added) {
              return reply.Error(
                  "Could not save the password (invalid, or already saved)");
            }
            ray::Settle(std::move(session), std::move(reply),
                          ray::Saved(origin, username, std::move(password)),
                          ray::kSettleChecks);
          },
          origin, args.String("username"), std::move(password)));
}

AC_ENGINE_CALL(ac_passwords_update) {
  AC_PASSWORDS_OPEN_WITH(nullptr);
  AC_PASSWORDS_SENSITIVE_ARGS(args);
  std::optional<ray::Secret> new_password = args.SecretAt("newPassword");
  if (!new_password) {
    return call.TakeReply().Error("bad arguments");
  }
  ray::WithList(
      std::move(*session), call.TakeReply(),
      base::BindOnce(
          [](std::string origin, std::string username,
             std::optional<std::string> new_username,
             ray::Secret new_password, Session session, Reply reply,
             const Entries& entries) {
            const auto* entry = ray::Find(entries, origin, username);
            if (!entry) {
              return reply.Error("No such password");
            }
            ray::Reauthenticate(
                std::move(session), std::move(reply),
                IDS_PASSWORDS_PAGE_EDIT_AUTHENTICATION_PROMPT_BIOMETRIC_SUFFIX,
                password_manager::constants::kPasswordManagerAuthValidity,
                base::BindOnce(
                    [](int id, std::string origin, std::string username,
                       ray::Secret new_password, Session session,
                       Reply reply, bool authenticated) {
                      if (!authenticated) {
                        return reply.Error("Not authenticated");
                      }
                      ray::pp::PasswordUiEntry change;
                      change.id = id;
                      change.username = username;
                      if (new_password.present()) {
                        change.password = new_password.value();
                      }
                      const bool changed =
                          session.delegate->ChangeCredential(change);
                      if (change.password) {
                        ray::Cleanse(*change.password);
                      }
                      if (!changed) {
                        return reply.Error("Could not change the password");
                      }
                      ray::Settle(
                          std::move(session), std::move(reply),
                          ray::Saved(origin, username,
                                       std::move(new_password)),
                          ray::kSettleChecks);
                    },
                    entry->id, origin, new_username.value_or(username),
                    std::move(new_password)));
          },
          args.String("origin"), args.String("username"),
          args.dict()->FindString("newUsername")
              ? std::optional<std::string>(args.String("newUsername"))
              : std::nullopt,
          std::move(*new_password)));
}

AC_ENGINE_CALL(ac_passwords_remove) {
  AC_PASSWORDS_OPEN();
  ray::WithList(
      std::move(*session), call.TakeReply(),
      base::BindOnce(
          [](std::string origin, std::string username, Session session,
             Reply reply, const Entries& entries) {
            const auto* entry = ray::Find(entries, origin, username);
            if (!entry) {
              return reply.Ok();
            }
            session.delegate->RemoveCredential(entry->id, entry->stored_in);
            ray::Settle(std::move(session), std::move(reply),
                              ray::Gone(origin, username),
                              ray::kSettleChecks);
          },
          call.String("origin"), call.String("username")));
}

AC_ENGINE_CALL(ac_passwords_exceptions) {
  AC_PASSWORDS_OPEN();
  base::WeakPtr<extensions::PasswordsPrivateDelegate> delegate =
      session->delegate;
  delegate->GetPasswordExceptionsList(base::BindOnce(
      [](Session, Reply reply,
         const extensions::PasswordsPrivateDelegate::ExceptionEntries&
             exceptions) {
        base::ListValue origins;
        for (const auto& exception : exceptions) {
          std::string origin = ray::ExceptionOrigin(exception);
          if (!origin.empty()) {
            origins.Append(std::move(origin));
          }
        }
        reply.Send(base::DictValue().Set("origins", std::move(origins)));
      },
      std::move(*session), call.TakeReply()));
}

AC_ENGINE_CALL(ac_passwords_allow) {
  AC_PASSWORDS_OPEN();
  base::WeakPtr<extensions::PasswordsPrivateDelegate> delegate =
      session->delegate;
  delegate->GetPasswordExceptionsList(base::BindOnce(
      [](std::string origin, Session session, Reply reply,
         const extensions::PasswordsPrivateDelegate::ExceptionEntries&
             exceptions) {
        std::vector<int> ids;
        for (const auto& exception : exceptions) {
          if (ray::ExceptionOrigin(exception) == origin) {
            ids.push_back(exception.id);
          }
        }
        for (int id : ids) {
          if (session.alive()) {
            session.delegate->RemovePasswordException(id);
          }
        }
        reply.Ok();
      },
      call.String("origin"), std::move(*session), call.TakeReply()));
}

AC_ENGINE_CALL(ac_passwords_export) {
  AC_PASSWORDS_OPEN();
  const std::string path = call.String("path");
  if (path.empty() || path[0] != '/') {
    return call.TakeReply().Error("an absolute path required");
  }
  ray::WithList(
      std::move(*session), call.TakeReply(),
      base::BindOnce(
          [](std::string path, Session session, Reply reply, const Entries&) {
            ray::Reauthenticate(
                std::move(session), std::move(reply),
                IDS_PASSWORDS_PAGE_EXPORT_AUTHENTICATION_PROMPT_BIOMETRIC_SUFFIX,
                base::TimeDelta(),
                base::BindOnce(
                    [](std::string path, Session session, Reply reply,
                       bool authenticated) {
                      if (!authenticated) {
                        return reply.Send(
                            base::DictValue().Set("status", "reauthFailed"));
                      }
                      session.state->Export(session.delegate.get(),
                                            base::FilePath(path),
                                            std::move(session.busy),
                                            std::move(reply));
                    },
                    path));
          },
          path));
}
