// Copyright 2026 Ray. Apache-2.0.

#include <algorithm>
#include <memory>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "base/functional/bind.h"
#include "base/functional/callback.h"
#include "base/json/string_escape.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/raw_ref.h"
#include "base/memory/scoped_refptr.h"
#include "base/memory/weak_ptr.h"
#include "base/strings/strcat.h"
#include "base/strings/utf_string_conversions.h"
#include "base/task/sequenced_task_runner.h"
#include "base/time/time.h"
#include "base/types/expected.h"
#include "base/values.h"
#include "chrome/browser/ray/ac_engine.h"
#include "chrome/browser/ray/ac_reauth.h"
#include "chrome/browser/ray/ac_sensitive_args.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/password_manager/factories/account_password_store_factory.h"
#include "chrome/browser/password_manager/factories/profile_password_store_factory.h"
#include "chrome/browser/profiles/profile.h"
#include "components/keyed_service/core/service_access_type.h"
#include "components/password_manager/core/browser/form_saver_impl.h"
#include "components/password_manager/core/browser/password_feature_manager_impl.h"
#include "components/password_manager/core/browser/password_form.h"
#include "components/password_manager/core/browser/password_form_digest.h"
#include "components/password_manager/core/browser/password_manager_util.h"
#include "components/password_manager/core/browser/password_store/password_form_converters.h"
#include "components/password_manager/core/browser/password_store/password_store_backend_error.h"
#include "components/password_manager/core/browser/password_store/password_store_consumer.h"
#include "components/password_manager/core/browser/password_store/password_store_interface.h"
#include "components/password_manager/core/browser/password_store/stored_credential.h"
#include "components/password_manager/core/browser/password_string.h"
#include "components/password_manager/core/common/password_manager_constants.h"
#include "components/strings/grit/components_strings.h"
#include "ui/base/l10n/l10n_util.h"
#include "url/gurl.h"

namespace ray {
namespace {

using password_manager::PasswordForm;
using password_manager::PasswordFormDigest;
using password_manager::PasswordStoreBackendError;
using password_manager::PasswordStoreInterface;
using password_manager::PasswordString;
using password_manager::StoredCredential;
using password_manager_util::GetLoginMatchType;
using Credentials = std::vector<StoredCredential>;
using CredentialsOrError = base::expected<Credentials, PasswordStoreBackendError>;
using Candidates =
    std::vector<raw_ptr<const StoredCredential, VectorExperimental>>;
using Stores = std::vector<scoped_refptr<PasswordStoreInterface>>;
using Found = base::OnceCallback<void(Credentials, bool complete)>;

constexpr size_t kMaxSecretArgsBytes = 64 * 1024;
constexpr char kStoreUnavailable[] = "password store unavailable";

struct Page {
  GURL url;
  PasswordFormDigest digest;
};

std::optional<Page> PageAt(const std::string& spec) {
  const GURL url(spec);
  if (!url.is_valid() || !url.SchemeIsHTTPOrHTTPS()) {
    return std::nullopt;
  }
  GURL stripped = password_manager_util::StripAuthAndParams(url);
  PasswordFormDigest digest(PasswordForm::Scheme::kHtml,
                            password_manager_util::GetSignonRealm(stripped),
                            stripped);
  return Page{std::move(stripped), std::move(digest)};
}

scoped_refptr<PasswordStoreInterface> ProfileStoreOf(Profile* profile) {
  return ProfilePasswordStoreFactory::GetForProfile(
      profile->GetOriginalProfile(), ServiceAccessType::EXPLICIT_ACCESS);
}

Stores StoresOf(Profile* profile) {
  Stores stores;
  if (scoped_refptr<PasswordStoreInterface> store = ProfileStoreOf(profile)) {
    stores.push_back(std::move(store));
  }
  if (scoped_refptr<PasswordStoreInterface> store =
          AccountPasswordStoreFactory::GetForProfile(
              profile->GetOriginalProfile(),
              ServiceAccessType::EXPLICIT_ACCESS)) {
    stores.push_back(std::move(store));
  }
  return stores;
}

bool Fillable(const StoredCredential& credential) {
  return !credential.blocked_by_user &&
         !credential.federation_origin.IsValid() &&
         credential.scheme == PasswordForm::Scheme::kHtml &&
         !credential.password_value.empty();
}

bool Blocked(const Credentials& credentials) {
  return std::ranges::any_of(credentials, [](const StoredCredential& c) {
    return c.blocked_by_user && c.scheme == PasswordForm::Scheme::kHtml &&
           password_manager_util::GetMatchType(c) == GetLoginMatchType::kExact;
  });
}

Candidates CandidatesIn(const Credentials& credentials) {
  Candidates candidates;
  for (const StoredCredential& credential : credentials) {
    if (Fillable(credential)) {
      candidates.push_back(&credential);
    }
  }
  std::stable_sort(
      candidates.begin(), candidates.end(),
      [](const StoredCredential* a, const StoredCredential* b) {
        const GetLoginMatchType first = password_manager_util::GetMatchType(*a);
        const GetLoginMatchType second =
            password_manager_util::GetMatchType(*b);
        if (first != second) {
          return first < second;
        }
        return a->date_last_used > b->date_last_used;
      });
  return candidates;
}

const char* MatchName(GetLoginMatchType type) {
  switch (type) {
    case GetLoginMatchType::kExact:
      return "exact";
    case GetLoginMatchType::kAffiliated:
      return "affiliated";
    case GetLoginMatchType::kPSL:
      return "psl";
    case GetLoginMatchType::kGrouped:
      return "grouped";
  }
  return "exact";
}

class PageState;

class PageRead : public password_manager::PasswordStoreConsumer {
 public:
  PageRead(PageState& owner, Stores stores, Found found)
      : owner_(owner), stores_(std::move(stores)), found_(std::move(found)) {}

  void Start(const PasswordFormDigest& digest) {
    waiting_ = stores_.size();
    for (const scoped_refptr<PasswordStoreInterface>& store : stores_) {
      store->GetLogins(digest, weak_factory_.GetWeakPtr());
    }
  }

  void OnGetPasswordStoreResultsOrErrorFrom(PasswordStoreInterface*,
                                            CredentialsOrError result) override {
    if (result.has_value()) {
      for (StoredCredential& credential : *result) {
        credentials_.push_back(std::move(credential));
      }
    } else {
      complete_ = false;
    }
    if (waiting_ == 0 || --waiting_ > 0) {
      return;
    }
    Finish();
  }

 private:
  void Finish();

  const raw_ref<PageState> owner_;
  Stores stores_;
  Found found_;
  Credentials credentials_;
  bool complete_ = true;
  size_t waiting_ = 0;
  base::WeakPtrFactory<PageRead> weak_factory_{this};
};

class PageState : public ProfileState {
 public:
  explicit PageState(Profile* profile) : ProfileState(profile) {}

  void Read(const PasswordFormDigest& digest, Stores stores, Found found) {
    if (stores.empty()) {
      std::move(found).Run(Credentials(), false);
      return;
    }
    reads_.push_back(std::make_unique<PageRead>(*this, std::move(stores),
                                                std::move(found)));
    reads_.back()->Start(digest);
  }

  void Done(PageRead* read) {
    auto found = std::ranges::find_if(
        reads_, [read](const auto& owned) { return owned.get() == read; });
    if (found == reads_.end()) {
      return;
    }
    base::SequencedTaskRunner::GetCurrentDefault()->DeleteSoon(
        FROM_HERE, std::move(*found));
    reads_.erase(found);
  }

 private:
  void Release() override { reads_.clear(); }

  std::vector<std::unique_ptr<PageRead>> reads_;
};

void PageRead::Finish() {
  Credentials credentials = std::move(credentials_);
  const bool complete = complete_;
  Found found = std::move(found_);
  owner_->Done(this);
  std::move(found).Run(std::move(credentials), complete);
}

void ReadPage(Profile* profile, const Page& page, Found found) {
  Profile* original = profile->GetOriginalProfile();
  StateFor<PageState>(original).Read(page.digest, StoresOf(original),
                                     std::move(found));
}

void ReadStore(Profile* profile,
               const PasswordFormDigest& digest,
               scoped_refptr<PasswordStoreInterface> store,
               Found found) {
  Profile* original = profile->GetOriginalProfile();
  StateFor<PageState>(original).Read(digest, Stores{std::move(store)},
                                     std::move(found));
}

std::u16string FillPrompt(const std::string& host) {
#if BUILDFLAG(IS_LINUX)
  return base::StrCat({u"Fill your password on ", base::UTF8ToUTF16(host)});
#else
  return l10n_util::GetStringFUTF16(IDS_PASSWORD_MANAGER_FILLING_REAUTH,
                                    base::UTF8ToUTF16(host));
#endif
}

bool Saved(const Credentials& credentials,
           const std::string& realm,
           const std::u16string& username,
           const PasswordString& password) {
  return std::ranges::any_of(credentials, [&](const StoredCredential& c) {
    return c.signon_realm == realm && c.username_value == username &&
           c.password_value == password;
  });
}

bool ReauthBeforeFilling(Profile* profile) {
  return password_manager::PasswordFeatureManagerImpl(
             profile->GetOriginalProfile()->GetPrefs(),
             g_browser_process->local_state(), nullptr)
      .IsBiometricAuthenticationBeforeFillingEnabled();
}

void SendLogin(Reply reply,
               const std::u16string& username,
               const PasswordString& password) {
  std::u16string plain = password.value();
  std::string json = "{\"username\":";
  bool valid = base::EscapeJSONString(username, true, &json);
  json += ",\"password\":";
  valid &= base::EscapeJSONString(plain, true, &json);
  json += '}';
  Cleanse(plain);
  if (!valid) {
    Cleanse(json);
    return reply.Error("unreadable");
  }
  reply.SendSecretJSON(json);
}

std::optional<PasswordString> PasswordArg(const ArgsCall& call) {
  std::optional<Secret> secret = call.SecretAt("password");
  if (!secret || secret->value().empty()) {
    return std::nullopt;
  }
  std::u16string password = base::UTF8ToUTF16(secret->value());
  return PasswordString(std::move(password));
}

PasswordForm Submitted(const Page& page,
                       const std::string& username,
                       PasswordString password) {
  PasswordForm form;
  form.scheme = PasswordForm::Scheme::kHtml;
  form.signon_realm = page.digest.signon_realm;
  form.url = page.url;
  form.username_value = base::UTF8ToUTF16(username);
  form.password_value = std::move(password);
  form.type = PasswordForm::Type::kFormSubmission;
  return form;
}

base::ListValue UsernamesOf(const Candidates& candidates) {
  std::vector<std::string> seen;
  base::ListValue names;
  for (const StoredCredential* credential : candidates) {
    if (password_manager_util::IsCredentialWeakMatch(*credential)) {
      continue;
    }
    std::string name = base::UTF16ToUTF8(credential->username_value);
    if (std::find(seen.begin(), seen.end(), name) != seen.end()) {
      continue;
    }
    seen.push_back(name);
    names.Append(std::move(name));
  }
  return names;
}

base::ListValue OneName(const std::u16string& username) {
  base::ListValue names;
  names.Append(base::UTF16ToUTF8(username));
  return names;
}

}
}

using ray::Reply;

AC_PROFILE_CALL(ac_passwords_page_logins, ray::OffTheRecord::kAllow) {
  std::optional<ray::Page> page = ray::PageAt(call.String("url"));
  if (!page) {
    return call.TakeReply().Error("not a web page");
  }
  ray::ReadPage(
      call.profile(), *page,
      base::BindOnce(
          [](Reply reply, ray::Credentials credentials, bool complete) {
            if (!complete && credentials.empty()) {
              return reply.Error(ray::kStoreUnavailable);
            }
            base::ListValue logins;
            for (const password_manager::StoredCredential* credential :
                 ray::CandidatesIn(credentials)) {
              logins.Append(
                  base::DictValue()
                      .Set("username",
                           base::UTF16ToUTF8(credential->username_value))
                      .Set("realm", credential->signon_realm)
                      .Set("match", ray::MatchName(
                                        password_manager_util::GetMatchType(
                                            *credential))));
            }
            reply.Send(base::DictValue()
                           .Set("logins", std::move(logins))
                           .Set("blocked", ray::Blocked(credentials)));
          },
          call.TakeReply()));
}

AC_PROFILE_CALL(ac_passwords_page_fill, ray::OffTheRecord::kAllow) {
  std::optional<ray::Page> page = ray::PageAt(call.String("url"));
  if (!page) {
    return call.TakeReply().Error("not a web page");
  }
  ray::ReadPage(
      call.profile(), *page,
      base::BindOnce(
          [](base::WeakPtr<Profile> profile, std::string host,
             std::string realm, std::u16string username, Reply reply,
             ray::Credentials credentials, bool complete) {
            const ray::Candidates candidates =
                ray::CandidatesIn(credentials);
            auto match = std::find_if(
                candidates.begin(), candidates.end(),
                [&](const password_manager::StoredCredential* c) {
                  return c->signon_realm == realm &&
                         c->username_value == username;
                });
            if (match == candidates.end()) {
              return reply.Error(complete ? "No such password"
                                          : ray::kStoreUnavailable);
            }
            password_manager::PasswordString password =
                (*match)->password_value;
            if (!profile) {
              return reply.Error("profile closed");
            }
            if (!ray::ReauthBeforeFilling(profile.get())) {
              return ray::SendLogin(std::move(reply), username, password);
            }
            ray::Reauth(
                profile->GetOriginalProfile(),
                device_reauth::DeviceAuthSource::kPasswordManager,
                ray::FillPrompt(host),
                password_manager::constants::kPasswordManagerAuthValidity,
                base::BindOnce(
                    [](Reply reply, std::u16string username,
                       password_manager::PasswordString password,
                       bool authenticated) {
                      if (!authenticated) {
                        return reply.Error("Not authenticated");
                      }
                      ray::SendLogin(std::move(reply), username, password);
                    },
                    std::move(reply), username, std::move(password)));
          },
          call.profile()->GetWeakPtr(), std::string(page->url.host()),
          call.String("realm"),
          base::UTF8ToUTF16(call.String("username")), call.TakeReply()));
}

AC_PROFILE_CALL(ac_passwords_page_submitted,
                ray::Sensitive{ray::kMaxSecretArgsBytes}) {
  std::optional<ray::Page> page = ray::PageAt(call.String("url"));
  std::optional<password_manager::PasswordString> password =
      ray::PasswordArg(call);
  if (!page || !password) {
    return call.TakeReply().Error("bad arguments");
  }
  password_manager::PasswordForm submitted =
      ray::Submitted(*page, call.String("username"), std::move(*password));
  ray::ReadPage(
      call.profile(), *page,
      base::BindOnce(
          [](password_manager::PasswordForm submitted, Reply reply,
             ray::Credentials credentials, bool complete) {
            const bool blocked = ray::Blocked(credentials);
            const ray::Candidates candidates =
                ray::CandidatesIn(credentials);
            const password_manager::StoredCredential* match =
                password_manager_util::GetMatchForUpdating(submitted,
                                                           candidates);
            if (!match && !complete) {
              submitted.password_value.clear();
              return reply.Error(ray::kStoreUnavailable);
            }
            base::DictValue result;
            if (!match) {
              result.Set("state", blocked ? "none" : "save");
              result.Set("usernames", ray::OneName(submitted.username_value));
              result.Set("username",
                         base::UTF16ToUTF8(submitted.username_value));
            } else if (match->password_value == submitted.password_value) {
              result.Set("state", "none");
            } else {
              const std::string username =
                  base::UTF16ToUTF8(match->username_value);
              base::ListValue usernames =
                  submitted.username_value.empty()
                      ? ray::UsernamesOf(candidates)
                      : ray::OneName(match->username_value);
              if (usernames.empty()) {
                usernames = ray::OneName(match->username_value);
              }
              result.Set("state", "update");
              result.Set("username", username);
              result.Set("usernames", std::move(usernames));
            }
            result.Set("blocked", blocked);
            submitted.password_value.clear();
            reply.Send(std::move(result));
          },
          std::move(submitted), call.TakeReply()));
}

AC_PROFILE_CALL(ac_passwords_page_update,
                ray::Sensitive{ray::kMaxSecretArgsBytes}) {
  std::optional<ray::Page> page = ray::PageAt(call.String("url"));
  std::optional<password_manager::PasswordString> password =
      ray::PasswordArg(call);
  if (!page || !password) {
    return call.TakeReply().Error("bad arguments");
  }
  ray::ReadPage(
      call.profile(), *page,
      base::BindOnce(
          [](base::WeakPtr<Profile> profile,
             password_manager::PasswordFormDigest digest,
             std::u16string username,
             password_manager::PasswordString password, Reply reply,
             ray::Credentials credentials, bool complete) {
            ray::Candidates strong;
            for (const password_manager::StoredCredential* credential :
                 ray::CandidatesIn(credentials)) {
              if (!password_manager_util::IsCredentialWeakMatch(*credential)) {
                strong.push_back(credential);
              }
            }
            const password_manager::StoredCredential* match =
                password_manager_util::FindCredentialByUsername(strong,
                                                                username);
            if (!profile) {
              return reply.Error("profile closed");
            }
            if (!match) {
              return reply.Error(complete ? "No such password"
                                          : ray::kStoreUnavailable);
            }
            scoped_refptr<password_manager::PasswordStoreInterface> store =
                match->IsUsingAccountStore()
                    ? AccountPasswordStoreFactory::GetForProfile(
                          profile->GetOriginalProfile(),
                          ServiceAccessType::EXPLICIT_ACCESS)
                    : ray::ProfileStoreOf(profile.get());
            if (!store) {
              return reply.Error("no password store");
            }
            password_manager::StoredCredential changed =
                password_manager::CloneStoredCredential(*match);
            const std::string realm = changed.signon_realm;
            const std::u16string saved_username = changed.username_value;
            password_manager::PasswordString expected = password;
            changed.password_value = std::move(password);
            changed.date_password_modified = base::Time::Now();
            changed.match_type = std::nullopt;
            auto verify = base::BindOnce(
                [](base::WeakPtr<Profile> profile,
                   password_manager::PasswordFormDigest digest,
                   scoped_refptr<password_manager::PasswordStoreInterface>
                       store,
                   std::string realm, std::u16string username,
                   password_manager::PasswordString expected, Reply reply) {
                  if (!profile) {
                    return reply.Error("profile closed");
                  }
                  ray::ReadStore(
                      profile.get(), digest, std::move(store),
                      base::BindOnce(
                          [](std::string realm, std::u16string username,
                             password_manager::PasswordString expected,
                             Reply reply, ray::Credentials credentials,
                             bool complete) {
                            const bool saved = ray::Saved(
                                credentials, realm, username, expected);
                            expected.clear();
                            if (!saved) {
                              return reply.Error(
                                  complete ? "the password wasn't saved"
                                           : ray::kStoreUnavailable);
                            }
                            reply.Ok();
                          },
                          std::move(realm), std::move(username),
                          std::move(expected), std::move(reply)));
                },
                profile, std::move(digest), store, realm, saved_username,
                std::move(expected), std::move(reply));
            store->UpdateLogin(std::move(changed), std::move(verify));
          },
          call.profile()->GetWeakPtr(), page->digest,
          base::UTF8ToUTF16(call.String("username")), std::move(*password),
          call.TakeReply()));
}

AC_PROFILE_CALL(ac_passwords_page_never) {
  std::optional<ray::Page> page = ray::PageAt(call.String("url"));
  if (!page) {
    return call.TakeReply().Error("not a web page");
  }
  scoped_refptr<password_manager::PasswordStoreInterface> store =
      ray::ProfileStoreOf(call.profile());
  if (!store) {
    return call.TakeReply().Error("no password store");
  }
  password_manager::FormSaverImpl(store.get()).Blocklist(page->digest);
  call.TakeReply().Ok();
}
