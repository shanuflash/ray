// Copyright 2026 Ray. Apache-2.0.

#ifndef CHROME_BROWSER_RAY_AC_SENSITIVE_ARGS_H_
#define CHROME_BROWSER_RAY_AC_SENSITIVE_ARGS_H_

#include <cstddef>
#include <optional>
#include <string>
#include <string_view>

#include "base/values.h"

namespace ray {

void Cleanse(std::string& string);
void Cleanse(std::u16string& string);
void Cleanse(base::Value& value);

class Secret {
 public:
  Secret();
  explicit Secret(const std::string* value);
  explicit Secret(std::string&& value);
  Secret(const Secret& other);
  Secret(Secret&& other);
  Secret& operator=(const Secret& other);
  Secret& operator=(Secret&& other);
  ~Secret();

  bool present() const { return present_; }
  const std::string& value() const { return value_; }

 private:
  std::string value_;
  bool present_ = false;
};

class SensitiveArgs {
 public:
  SensitiveArgs(const char* json, size_t max_bytes);
  SensitiveArgs(const SensitiveArgs&) = delete;
  SensitiveArgs& operator=(const SensitiveArgs&) = delete;
  ~SensitiveArgs();

  bool too_large() const { return too_large_; }
  base::DictValue* dict();
  std::string String(std::string_view key);
  std::optional<Secret> SecretAt(std::string_view key);

 private:
  std::optional<base::Value> value_;
  bool too_large_ = false;
};

}

#endif
