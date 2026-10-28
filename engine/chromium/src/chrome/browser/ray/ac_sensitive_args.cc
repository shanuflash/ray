// Copyright 2026 Ray. Apache-2.0.

#include "chrome/browser/ray/ac_sensitive_args.h"

#include <string.h>

#include <utility>

#include "base/json/json_reader.h"
#include "base/strings/strcat.h"
#include "base/strings/string_util.h"
#include "third_party/boringssl/src/include/openssl/mem.h"

namespace ray {

void Cleanse(std::string& string) {
  if (!string.empty()) {
    OPENSSL_cleanse(string.data(), string.size());
  }
}

void Cleanse(std::u16string& string) {
  if (!string.empty()) {
    OPENSSL_cleanse(string.data(), string.size() * sizeof(char16_t));
  }
}

void Cleanse(base::Value& value) {
  if (value.is_string()) {
    Cleanse(value.GetString());
  } else if (value.is_dict()) {
    for (auto [key, child] : value.GetDict()) {
      Cleanse(child);
    }
  } else if (value.is_list()) {
    for (base::Value& child : value.GetList()) {
      Cleanse(child);
    }
  }
}

Secret::Secret() = default;

Secret::Secret(const std::string* value)
    : value_(value ? *value : std::string()), present_(value != nullptr) {}

Secret::Secret(std::string&& value)
    : value_(std::move(value)), present_(true) {
  Cleanse(value);
}

Secret::Secret(const Secret& other) = default;

Secret::Secret(Secret&& other)
    : value_(std::move(other.value_)), present_(other.present_) {
  Cleanse(other.value_);
}

Secret& Secret::operator=(const Secret& other) {
  if (this != &other) {
    Cleanse(value_);
    value_ = other.value_;
    present_ = other.present_;
  }
  return *this;
}

Secret& Secret::operator=(Secret&& other) {
  if (this != &other) {
    Cleanse(value_);
    value_ = std::move(other.value_);
    present_ = other.present_;
    Cleanse(other.value_);
  }
  return *this;
}

Secret::~Secret() {
  Cleanse(value_);
}

SensitiveArgs::SensitiveArgs(const char* json, size_t max_bytes) {
  if (!json || !*json) {
    return;
  }
  if (strnlen(json, max_bytes + 1) > max_bytes) {
    too_large_ = true;
    return;
  }
  value_ = base::JSONReader::Read(json, base::JSON_PARSE_CHROMIUM_EXTENSIONS);
}

SensitiveArgs::~SensitiveArgs() {
  if (value_) {
    Cleanse(*value_);
  }
}

base::DictValue* SensitiveArgs::dict() {
  return value_ && value_->is_dict() ? &value_->GetDict() : nullptr;
}

std::string SensitiveArgs::String(std::string_view key) {
  const std::string* value = dict() ? dict()->FindString(key) : nullptr;
  return value ? *value : std::string();
}

std::optional<Secret> SensitiveArgs::SecretAt(std::string_view key) {
  if (!dict()) {
    return Secret();
  }
  const std::string* hex = dict()->FindString(base::StrCat({key, "Hex"}));
  if (!hex) {
    return Secret(dict()->FindString(key));
  }
  if (hex->size() % 2) {
    return std::nullopt;
  }
  std::string bytes(hex->size() / 2, '\0');
  for (size_t i = 0; i < bytes.size(); ++i) {
    const char high = (*hex)[2 * i], low = (*hex)[2 * i + 1];
    if (!base::IsHexDigit(high) || !base::IsHexDigit(low)) {
      Cleanse(bytes);
      return std::nullopt;
    }
    bytes[i] = static_cast<char>(base::HexDigitToInt(high) * 16 +
                                 base::HexDigitToInt(low));
  }
  return Secret(std::move(bytes));
}

}
