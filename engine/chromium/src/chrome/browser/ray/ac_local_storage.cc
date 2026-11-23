// Copyright 2026 Ray. Apache-2.0.

#include <algorithm>
#include <cstdint>
#include <map>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "base/functional/bind.h"
#include "base/functional/callback_helpers.h"
#include "base/memory/ref_counted.h"
#include "base/memory/scoped_refptr.h"
#include "base/strings/utf_string_conversions.h"
#include "base/values.h"
#include "chrome/browser/ray/ac_engine.h"
#include "chrome/browser/profiles/profile.h"
#include "components/services/storage/public/mojom/local_storage_control.mojom.h"
#include "content/public/browser/storage_partition.h"
#include "mojo/public/cpp/bindings/remote.h"
#include "net/base/registry_controlled_domains/registry_controlled_domain.h"
#include "third_party/blink/public/common/storage_key/storage_key.h"
#include "third_party/blink/public/mojom/dom_storage/storage_area.mojom.h"
#include "url/gurl.h"
#include "url/origin.h"

namespace ray {
namespace {

constexpr size_t kMaxStorageArgsBytes = 8 * 1024 * 1024;
constexpr size_t kMaxStorageBytes = 2'000'000;
constexpr size_t kMaxStorageWrites = 4000;
constexpr uint8_t kUtf16Format = 0;
constexpr uint8_t kLatin1Format = 1;

std::optional<std::u16string> Decode(const std::vector<uint8_t>& bytes) {
  if (bytes.empty()) {
    return std::u16string();
  }
  if (bytes[0] == kLatin1Format) {
    return std::u16string(bytes.begin() + 1, bytes.end());
  }
  if (bytes[0] != kUtf16Format || (bytes.size() - 1) % 2) {
    return std::nullopt;
  }
  std::u16string text((bytes.size() - 1) / 2, u'\0');
  for (size_t i = 0; i < text.size(); ++i) {
    text[i] = static_cast<char16_t>(bytes[1 + 2 * i] | (bytes[2 + 2 * i] << 8));
  }
  return text;
}

bool OnlyLatin1(const std::u16string& text) {
  return std::ranges::all_of(text, [](char16_t c) { return c <= 0xff; });
}

std::vector<uint8_t> EncodeAs(const std::u16string& text, uint8_t format) {
  std::vector<uint8_t> bytes;
  bytes.reserve(1 + text.size() * (format == kLatin1Format ? 1 : 2));
  bytes.push_back(format);
  for (char16_t c : text) {
    bytes.push_back(static_cast<uint8_t>(c & 0xff));
    if (format == kUtf16Format) {
      bytes.push_back(static_cast<uint8_t>(c >> 8));
    }
  }
  return bytes;
}

std::vector<uint8_t> Encode(const std::u16string& text) {
  return EncodeAs(text, OnlyLatin1(text) ? kLatin1Format : kUtf16Format);
}

std::optional<std::vector<uint8_t>> StrayUtf16Form(const std::u16string& text) {
  if (!OnlyLatin1(text)) {
    return std::nullopt;
  }
  return EncodeAs(text, kUtf16Format);
}

bool WellFormed(const std::u16string& text) {
  for (size_t i = 0; i < text.size(); ++i) {
    const char16_t c = text[i];
    if (c >= 0xd800 && c <= 0xdbff) {
      if (i + 1 >= text.size() || text[i + 1] < 0xdc00 || text[i + 1] > 0xdfff) {
        return false;
      }
      ++i;
    } else if (c >= 0xdc00 && c <= 0xdfff) {
      return false;
    }
  }
  return true;
}

std::optional<blink::StorageKey> KeyFor(const std::string& text) {
  const GURL url(text);
  if (!url.is_valid() || !url.SchemeIsHTTPOrHTTPS()) {
    return std::nullopt;
  }
  return blink::StorageKey::CreateFirstParty(url::Origin::Create(url));
}

mojo::Remote<blink::mojom::StorageArea> AreaFor(Profile* profile,
                                                const blink::StorageKey& key) {
  mojo::Remote<blink::mojom::StorageArea> area;
  profile->GetDefaultStoragePartition()->GetLocalStorageControl()->BindStorageArea(
      key, area.BindNewPipeAndPassReceiver());
  return area;
}

void SendItems(mojo::Remote<blink::mojom::StorageArea>,
               Reply reply,
               std::vector<blink::mojom::KeyValuePtr> data) {
  base::ListValue items;
  size_t bytes = 0;
  for (const blink::mojom::KeyValuePtr& entry : data) {
    std::optional<std::u16string> key = Decode(entry->key);
    std::optional<std::u16string> value = Decode(entry->value);
    if (!key || !value || !WellFormed(*key) || !WellFormed(*value)) {
      return reply.Send(base::DictValue().Set("items", base::Value()));
    }
    bytes += key->size() + value->size();
    if (bytes > kMaxStorageBytes) {
      return reply.Send(base::DictValue().Set("items", base::Value()));
    }
    items.Append(base::ListValue()
                     .Append(base::UTF16ToUTF8(*key))
                     .Append(base::UTF16ToUTF8(*value)));
  }
  reply.Send(base::DictValue().Set("items", std::move(items)));
}

struct StorageChange {
  std::u16string key;
  std::optional<std::u16string> value;
};

using StoredItem = std::pair<std::vector<uint8_t>, std::vector<uint8_t>>;

std::vector<StorageChange> LastChangePerKey(std::vector<StorageChange> changes) {
  std::map<std::u16string, size_t> last;
  for (size_t i = 0; i < changes.size(); ++i) {
    last[changes[i].key] = i;
  }
  std::vector<StorageChange> kept;
  kept.reserve(last.size());
  for (size_t i = 0; i < changes.size(); ++i) {
    if (last[changes[i].key] == i) {
      kept.push_back(std::move(changes[i]));
    }
  }
  return kept;
}

class StorageWrite : public base::RefCounted<StorageWrite> {
 public:
  StorageWrite(mojo::Remote<blink::mojom::StorageArea> area,
               std::vector<StorageChange> changes,
               Reply reply)
      : area_(std::move(area)), changes_(std::move(changes)), reply_(std::move(reply)) {}

  static void Start(scoped_refptr<StorageWrite> write) {
    blink::mojom::StorageArea* area = write->area_.get();
    area->GetAll(mojo::NullRemote(), base::BindOnce(&StorageWrite::Read, std::move(write)));
  }

 private:
  friend class base::RefCounted<StorageWrite>;
  ~StorageWrite() = default;

  static void Read(scoped_refptr<StorageWrite> write,
                   std::vector<blink::mojom::KeyValuePtr> data) {
    for (blink::mojom::KeyValuePtr& entry : data) {
      write->stored_.emplace(std::move(entry->key), std::move(entry->value));
    }
    Step(std::move(write), 0);
  }

  static void Step(scoped_refptr<StorageWrite> write, size_t index) {
    if (index >= write->changes_.size()) {
      write->reply_.Send(base::DictValue().Set("written", write->written_));
      return;
    }
    blink::mojom::StorageArea* area = write->area_.get();
    const StorageChange& change = write->changes_[index];
    std::vector<uint8_t> key = Encode(change.key);
    std::optional<StoredItem> legacy;
    if (std::optional<std::vector<uint8_t>> stray = StrayUtf16Form(change.key)) {
      auto found = write->stored_.find(*stray);
      if (found != write->stored_.end()) {
        legacy.emplace(found->first, found->second);
        area->Delete(std::move(*stray), std::nullopt, nullptr, base::DoNothing());
      }
    }
    if (!change.value) {
      area->Delete(std::move(key), std::nullopt, nullptr,
                   base::BindOnce(&StorageWrite::Removed, std::move(write), index));
      return;
    }
    std::vector<uint8_t> value = Encode(*change.value);
    area->Put(std::move(key), std::move(value), std::nullopt, nullptr,
              base::BindOnce(&StorageWrite::Put, std::move(write), index, std::move(legacy)));
  }

  static void Removed(scoped_refptr<StorageWrite> write, size_t index) {
    ++write->written_;
    Step(std::move(write), index + 1);
  }

  static void Put(scoped_refptr<StorageWrite> write,
                  size_t index,
                  std::optional<StoredItem> legacy,
                  bool success) {
    if (success) {
      ++write->written_;
    }
    if (success || !legacy) {
      Step(std::move(write), index + 1);
      return;
    }
    blink::mojom::StorageArea* area = write->area_.get();
    area->Put(std::move(legacy->first), std::move(legacy->second), std::nullopt, nullptr,
              base::BindOnce(&StorageWrite::Restored, std::move(write), index));
  }

  static void Restored(scoped_refptr<StorageWrite> write, size_t index, bool) {
    Step(std::move(write), index + 1);
  }

  mojo::Remote<blink::mojom::StorageArea> area_;
  std::vector<StorageChange> changes_;
  Reply reply_;
  std::map<std::vector<uint8_t>, std::vector<uint8_t>> stored_;
  int written_ = 0;
};

}
}

AC_PROFILE_CALL(ac_local_storage_read, ray::Sensitive{ray::kMaxStorageArgsBytes}) {
  std::optional<blink::StorageKey> key = ray::KeyFor(call.String("origin"));
  if (!key) {
    return call.TakeReply().Error("origin must be an http or https origin");
  }
  mojo::Remote<blink::mojom::StorageArea> area = ray::AreaFor(call.profile(), *key);
  blink::mojom::StorageArea* raw = area.get();
  raw->GetAll(mojo::NullRemote(),
              base::BindOnce(&ray::SendItems, std::move(area), call.TakeReply()));
}

AC_PROFILE_CALL(ac_local_storage_write, ray::Sensitive{ray::kMaxStorageArgsBytes}) {
  std::optional<blink::StorageKey> key = ray::KeyFor(call.String("origin"));
  if (!key) {
    return call.TakeReply().Error("origin must be an http or https origin");
  }
  const base::ListValue* set = call.args().FindList("set");
  const base::ListValue* remove = call.args().FindList("remove");
  if ((set ? set->size() : 0) + (remove ? remove->size() : 0) > ray::kMaxStorageWrites) {
    return call.TakeReply().Error("too many writes in one call");
  }
  std::vector<ray::StorageChange> changes;
  if (set) {
    for (const base::Value& pair : *set) {
      const base::ListValue* entry = pair.GetIfList();
      if (entry && entry->size() == 2 && (*entry)[0].is_string() && (*entry)[1].is_string()) {
        changes.push_back({base::UTF8ToUTF16((*entry)[0].GetString()),
                           base::UTF8ToUTF16((*entry)[1].GetString())});
      }
    }
  }
  if (remove) {
    for (const base::Value& name : *remove) {
      if (name.is_string()) {
        changes.push_back({base::UTF8ToUTF16(name.GetString()), std::nullopt});
      }
    }
  }
  ray::StorageWrite::Start(base::MakeRefCounted<ray::StorageWrite>(
      ray::AreaFor(call.profile(), *key), ray::LastChangePerKey(std::move(changes)),
      call.TakeReply()));
}

AC_ARGS_CALL(ac_registrable_domains) {
  constexpr size_t kMaxHosts = 256;
  const base::ListValue* hosts = call.args().FindList("hosts");
  if (!hosts || hosts->size() > kMaxHosts) {
    return call.TakeReply().Error("hosts must be a list of at most 256 names");
  }
  base::ListValue domains;
  for (const base::Value& host : *hosts) {
    const std::string name = host.is_string() ? host.GetString() : std::string();
    const GURL url("https://" + name + "/");
    const std::string domain =
        url.is_valid() && url.host() == name
            ? net::registry_controlled_domains::GetDomainAndRegistry(
                  url, net::registry_controlled_domains::INCLUDE_PRIVATE_REGISTRIES)
            : std::string();
    domains.Append(domain.empty() ? name : domain);
  }
  call.TakeReply().Send(base::DictValue().Set("domains", std::move(domains)));
}
