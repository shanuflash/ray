// Copyright 2026 Ray. Apache-2.0.

#include "chrome/browser/ray/ac_engine.h"

#include <algorithm>
#include <cmath>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "base/barrier_callback.h"
#include "base/functional/bind.h"
#include "base/functional/callback.h"
#include "base/memory/weak_ptr.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/string_util.h"
#include "base/time/time.h"
#include "base/types/expected.h"
#include "base/values.h"
#include "chrome/browser/ray/ac_sensitive_args.h"
#include "content/public/browser/storage_partition.h"
#include "net/cookies/canonical_cookie.h"
#include "net/cookies/cookie_access_result.h"
#include "net/cookies/cookie_constants.h"
#include "net/cookies/cookie_inclusion_status.h"
#include "net/cookies/cookie_options.h"
#include "net/cookies/cookie_partition_key.h"
#include "services/network/public/mojom/cookie_manager.mojom.h"
#include "url/gurl.h"
#include "url/third_party/mozilla/url_parse.h"

namespace ray {
namespace {

constexpr size_t kMaxCookies = 1000;
constexpr size_t kMaxArgsBytes = 4 * 1024 * 1024;

std::optional<base::Time> TimeArg(const base::DictValue& dict,
                                  std::string_view key) {
  std::optional<double> ms = dict.FindDouble(key);
  if (!ms || !std::isfinite(*ms) || *ms <= 0) {
    return std::nullopt;
  }
  return base::Time::FromMillisecondsSinceUnixEpoch(*ms);
}

std::string_view StringArg(const base::DictValue& dict, std::string_view key) {
  const std::string* value = dict.FindString(key);
  return value ? std::string_view(*value) : std::string_view();
}

net::CookieSameSite SameSiteArg(std::string_view value) {
  if (value == "none") {
    return net::CookieSameSite::NO_RESTRICTION;
  }
  if (value == "lax") {
    return net::CookieSameSite::LAX_MODE;
  }
  if (value == "strict") {
    return net::CookieSameSite::STRICT_MODE;
  }
  return net::CookieSameSite::UNSPECIFIED;
}

net::CookiePriority PriorityArg(std::string_view value) {
  if (value == "low") {
    return net::COOKIE_PRIORITY_LOW;
  }
  if (value == "high") {
    return net::COOKIE_PRIORITY_HIGH;
  }
  return net::COOKIE_PRIORITY_MEDIUM;
}

int PortArg(const base::DictValue& dict) {
  if (std::optional<int> port = dict.FindInt("sourcePort")) {
    return *port;
  }
  std::optional<double> port = dict.FindDouble("sourcePort");
  if (port && std::isfinite(*port) && *port >= 0 && *port <= 65535) {
    return static_cast<int>(*port);
  }
  return url::PORT_UNSPECIFIED;
}

struct Imported {
  std::unique_ptr<net::CanonicalCookie> cookie;
  GURL source_url;
  bool dated = false;
};

std::optional<Imported> ToCookie(const base::Value& entry, base::Time now) {
  const base::DictValue* dict = entry.GetIfDict();
  if (!dict) {
    return std::nullopt;
  }
  const std::string* name = dict->FindString("name");
  const std::string* value = dict->FindString("value");
  const std::string* domain = dict->FindString("domain");
  const std::string* path = dict->FindString("path");
  if (!name || !value || !domain || !path || domain->empty()) {
    return std::nullopt;
  }
  const bool secure = dict->FindBool("secure").value_or(false);
  const bool source_secure = StringArg(*dict, "sourceScheme") == "secure";
  const int source_port = PortArg(*dict);

  const bool domain_cookie = domain->starts_with('.');
  std::string_view host = *domain;
  if (domain_cookie) {
    host.remove_prefix(1);
  }
  std::string spec = secure || source_secure ? "https://" : "http://";
  spec.append(host);
  if (source_port > 0 && source_port <= 65535) {
    spec.append(":").append(base::NumberToString(source_port));
  }
  spec.append(*path);
  GURL source_url(spec);
  if (!source_url.is_valid()) {
    return std::nullopt;
  }

  const std::optional<base::Time> created = TimeArg(*dict, "created");
  base::Time creation = created.value_or(now);
  if (creation > now) {
    creation = now;
  }
  base::Time last_access = TimeArg(*dict, "lastAccess").value_or(creation);
  if (last_access < creation) {
    last_access = creation;
  }
  if (last_access > now) {
    last_access = now;
  }

  std::optional<net::CookiePartitionKey> partition_key;
  if (const base::DictValue* key = dict->FindDict("partitionKey")) {
    const std::string* site = key->FindString("topLevelSite");
    base::expected<std::optional<net::CookiePartitionKey>, std::string> parsed =
        net::CookiePartitionKey::FromStorage(
            site ? *site : std::string(),
            key->FindBool("crossSite").value_or(false));
    if (!parsed.has_value()) {
      return std::nullopt;
    }
    partition_key = std::move(parsed).value();
  }

  net::CookieInclusionStatus status;
  std::unique_ptr<net::CanonicalCookie> cookie =
      net::CanonicalCookie::CreateSanitizedCookie(
          source_url, *name, *value, domain_cookie ? *domain : std::string(),
          *path, creation, TimeArg(*dict, "expires").value_or(base::Time()),
          last_access, secure, dict->FindBool("httpOnly").value_or(false),
          SameSiteArg(StringArg(*dict, "sameSite")),
          PriorityArg(StringArg(*dict, "priority")), std::move(partition_key),
          &status);
  if (!cookie || cookie->IsExpired(now)) {
    return std::nullopt;
  }
  if (cookie->Domain() != base::ToLowerASCII(*domain) ||
      cookie->Path() != *path) {
    return std::nullopt;
  }
  return Imported{std::move(cookie), std::move(source_url),
                  created.has_value()};
}

struct Counts {
  int imported = 0;
  int rejected = 0;
  int existing = 0;
  int replaced = 0;
};

enum class Existing { kKeep, kReplaceOlder };

bool Changed(const net::CanonicalCookie& from, const net::CanonicalCookie& to) {
  return from.Value() != to.Value() || from.ExpiryDate() != to.ExpiryDate() ||
         from.SecureAttribute() != to.SecureAttribute() ||
         from.IsHttpOnly() != to.IsHttpOnly() ||
         from.SameSite() != to.SameSite();
}

bool Supersedes(const Imported& imported, const net::CanonicalCookie& present) {
  return imported.dated && Changed(present, *imported.cookie) &&
         imported.cookie->CreationDate() >
             std::max(present.CreationDate(), present.LastUpdateDate());
}

network::mojom::CookieManager* CookieManagerOf(Profile* profile) {
  return profile->GetDefaultStoragePartition()
      ->GetCookieManagerForBrowserProcess();
}

struct Write {
  const Imported* imported;
  bool replaces;
};

enum class Outcome { kRejected, kImported, kReplaced };

void Written(base::WeakPtr<Profile> profile,
             Counts counts,
             Reply reply,
             const std::vector<Outcome>& results) {
  for (Outcome outcome : results) {
    switch (outcome) {
      case Outcome::kRejected:
        ++counts.rejected;
        break;
      case Outcome::kImported:
        ++counts.imported;
        break;
      case Outcome::kReplaced:
        ++counts.replaced;
        break;
    }
  }
  if (!profile) {
    return reply.Error("profile closed");
  }
  CookieManagerOf(profile.get())
      ->FlushCookieStore(base::BindOnce(
          [](Reply reply, Counts counts) {
            reply.Send(base::DictValue()
                           .Set("imported", counts.imported)
                           .Set("rejected", counts.rejected)
                           .Set("existing", counts.existing)
                           .Set("replaced", counts.replaced));
          },
          std::move(reply), counts));
}

void WriteNew(base::WeakPtr<Profile> profile,
              std::vector<Imported> cookies,
              Existing existing,
              Counts counts,
              Reply reply,
              const std::vector<net::CanonicalCookie>& present) {
  if (!profile) {
    return reply.Error("profile closed");
  }
  std::map<std::string_view, std::vector<const net::CanonicalCookie*>>
      by_domain;
  for (const net::CanonicalCookie& cookie : present) {
    by_domain[cookie.Domain()].push_back(&cookie);
  }
  std::vector<Write> writes;
  for (const Imported& imported : cookies) {
    std::vector<const net::CanonicalCookie*>& same_domain =
        by_domain[imported.cookie->Domain()];
    auto equivalent = std::ranges::find_if(
        same_domain, [&](const net::CanonicalCookie* other) {
          return imported.cookie->IsEquivalent(*other);
        });
    if (equivalent == same_domain.end()) {
      writes.push_back({&imported, false});
      same_domain.push_back(imported.cookie.get());
    } else if (existing == Existing::kReplaceOlder &&
               Supersedes(imported, **equivalent)) {
      writes.push_back({&imported, true});
      *equivalent = imported.cookie.get();
    } else {
      ++counts.existing;
    }
  }

  base::RepeatingCallback<void(Outcome)> barrier =
      base::BarrierCallback<Outcome>(
          writes.size(),
          base::BindOnce(&Written, profile, counts, std::move(reply)));
  network::mojom::CookieManager* manager = CookieManagerOf(profile.get());
  for (const Write& write : writes) {
    manager->SetCanonicalCookie(
        *write.imported->cookie, write.imported->source_url,
        net::CookieOptions::MakeAllInclusive(),
        base::BindOnce(
            [](base::RepeatingCallback<void(Outcome)> done, bool replaces,
               net::CookieAccessResult result) {
              done.Run(!result.status.IsInclude() ? Outcome::kRejected
                       : replaces                 ? Outcome::kReplaced
                                                  : Outcome::kImported);
            },
            barrier, write.replaces));
  }
}

}
}

AC_PROFILE_CALL(ac_cookies_import, ray::Sensitive{ray::kMaxArgsBytes}) {
  std::vector<ray::Imported> cookies;
  ray::Counts counts;
  const base::ListValue* list = call.args().FindList("cookies");
  if (!list) {
    return call.TakeReply().Error("cookies must be a list");
  }
  if (list->size() > ray::kMaxCookies) {
    return call.TakeReply().Error("too many cookies in one call");
  }
  const base::Time now = base::Time::Now();
  cookies.reserve(list->size());
  for (const base::Value& entry : *list) {
    std::optional<ray::Imported> cookie =
        ray::ToCookie(entry, now);
    if (cookie) {
      cookies.push_back(std::move(*cookie));
    } else {
      ++counts.rejected;
    }
  }

  if (cookies.empty()) {
    return call.TakeReply().Send(base::DictValue()
                                     .Set("imported", 0)
                                     .Set("rejected", counts.rejected)
                                     .Set("existing", 0)
                                     .Set("replaced", 0));
  }
  const ray::Existing existing = call.Bool("replaceOlder")
                                       ? ray::Existing::kReplaceOlder
                                       : ray::Existing::kKeep;
  ray::CookieManagerOf(call.profile())
      ->GetAllCookies(base::BindOnce(&ray::WriteNew,
                                     call.profile()->GetWeakPtr(),
                                     std::move(cookies), existing, counts,
                                     call.TakeReply()));
}
