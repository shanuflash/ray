#include "ray/linux/ac_linux_report_core.h"

#include <algorithm>
#include <memory>

#include "third_party/zlib/zlib.h"

namespace ray::linux_report {

namespace {

constexpr size_t kChunk = 1 << 16;
constexpr size_t kHeaderValueMax = 4096;

bool Among(char c, std::string_view set) {
  return set.find(c) != std::string_view::npos;
}

bool Digit(char c) {
  return c >= '0' && c <= '9';
}

bool LowerOrDigit(char c) {
  return Digit(c) || (c >= 'a' && c <= 'z');
}

bool Hex(char c) {
  return Digit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
}

bool Numbered(std::string_view number) {
  if (number.empty() || number.size() > 2 || number[0] == '0') return false;
  return std::ranges::all_of(number, Digit);
}

bool NumberedName(std::string_view name, std::string_view prefix, bool fixed_extension) {
  if (!name.starts_with(prefix)) return false;
  name.remove_prefix(prefix.size());
  const size_t dot = name.find('.');
  if (dot == std::string_view::npos || !Numbered(name.substr(0, dot))) return false;
  const std::string_view extension = name.substr(dot + 1);
  if (fixed_extension) return extension == "ips";
  return !extension.empty() && extension.size() <= 8 && std::ranges::all_of(extension, LowerOrDigit);
}

bool EqualsIgnoringCase(std::string_view a, std::string_view b) {
  return a.size() == b.size() && std::equal(a.begin(), a.end(), b.begin(), [](char x, char y) {
    const auto lower = [](char c) { return c >= 'A' && c <= 'Z' ? static_cast<char>(c - 'A' + 'a') : c; };
    return lower(x) == lower(y);
  });
}

bool PrintableValue(std::string_view value) {
  return !value.empty() && value.size() <= kHeaderValueMax &&
         std::ranges::all_of(value, [](char c) { return c >= 0x20 && c <= 0x7e; });
}

bool MediaType(std::string_view value) {
  const size_t slash = value.find('/');
  if (slash == std::string_view::npos) return false;
  const auto part = [](std::string_view text) {
    if (text.empty() || text.size() > 50) return false;
    const auto word = [](char c) { return LowerOrDigit(c) || (c >= 'A' && c <= 'Z'); };
    if (!word(text[0])) return false;
    return std::ranges::all_of(text, [&](char c) { return word(c) || Among(c, ".+-"); });
  };
  return part(value.substr(0, slash)) && part(value.substr(slash + 1));
}

bool BearerToken(std::string_view value) {
  constexpr std::string_view prefix = "Bearer ";
  if (!value.starts_with(prefix)) return false;
  value.remove_prefix(prefix.size());
  return !value.empty() && std::ranges::all_of(value, [](char c) {
    return LowerOrDigit(c) || (c >= 'A' && c <= 'Z') || Among(c, "-._~+/=");
  });
}

size_t Utf8Prefix(std::string_view text, size_t limit) {
  size_t at = 0;
  while (at < text.size()) {
    const unsigned char lead = static_cast<unsigned char>(text[at]);
    size_t length = 0;
    uint32_t point = 0;
    if (lead < 0x80) {
      length = 1;
      point = lead;
    } else if (lead >= 0xc2 && lead <= 0xdf) {
      length = 2;
      point = lead & 0x1f;
    } else if (lead >= 0xe0 && lead <= 0xef) {
      length = 3;
      point = lead & 0x0f;
    } else if (lead >= 0xf0 && lead <= 0xf4) {
      length = 4;
      point = lead & 0x07;
    } else {
      break;
    }
    if (at + length > text.size() || at + length > limit) break;
    bool valid = true;
    for (size_t i = 1; i < length; ++i) {
      const unsigned char next = static_cast<unsigned char>(text[at + i]);
      if ((next & 0xc0) != 0x80) valid = false;
      point = (point << 6) | (next & 0x3f);
    }
    if (!valid || (length == 3 && point < 0x800) || (length == 4 && (point < 0x10000 || point > 0x10ffff)) ||
        (point >= 0xd800 && point <= 0xdfff)) {
      break;
    }
    at += length;
  }
  return at;
}

}

bool InsideDrafts(std::string_view drafts, std::string_view path) {
  if (drafts.empty() || drafts.front() != '/' || drafts.back() == '/' || path.size() > kPathMaxBytes ||
      path.size() <= drafts.size() + 1 || !path.starts_with(drafts) || path[drafts.size()] != '/' ||
      path.find('\0') != std::string_view::npos || path.back() == '/') {
    return false;
  }
  std::string_view rest = path.substr(drafts.size() + 1);
  bool first = true;
  while (!rest.empty()) {
    const size_t slash = rest.find('/');
    const std::string_view part = rest.substr(0, slash);
    if (part.empty() || part == "." || part == "..") return false;
    if (first && !DraftFolderName(part)) return false;
    first = false;
    rest = slash == std::string_view::npos ? std::string_view() : rest.substr(slash + 1);
  }
  return true;
}

bool DraftFolderName(std::string_view name) {
  if (name.size() != 36) return false;
  for (size_t i = 0; i < name.size(); ++i) {
    const bool dash = i == 8 || i == 13 || i == 18 || i == 23;
    if (dash ? name[i] != '-' : !Hex(name[i])) return false;
  }
  return true;
}

bool ReportId(std::string_view id) {
  constexpr std::string_view prefix = "FB-";
  if (!id.starts_with(prefix)) return false;
  id.remove_prefix(prefix.size());
  return id.size() >= 4 && id.size() <= 5 && std::ranges::all_of(id, [](char c) {
    return (c >= '2' && c <= '9') || (c >= 'A' && c <= 'Z' && c != 'I' && c != 'O');
  });
}

std::optional<int64_t> FileLimit(std::string_view name) {
  if (name == "recording.mp4") return 100 * kMiB;
  if (name == "trace.json.gz") return 50 * kMiB;
  if (name == "local-events.jsonl.gz") return 10 * kMiB;
  if (NumberedName(name, "crash-", true) || NumberedName(name, "attachment-", false)) return 10 * kMiB;
  return std::nullopt;
}

Request ClassifyUrl(std::string_view endpoint, std::string_view url) {
  if (endpoint.empty() || url.size() > 2048) return {};
  Request request;
  if (url == endpoint) {
    request.target = Target::kCreate;
    return request;
  }
  if (!url.starts_with(endpoint) || url.size() <= endpoint.size() + 1 || url[endpoint.size()] != '/') return {};
  const std::string_view rest = url.substr(endpoint.size() + 1);
  const size_t slash = rest.find('/');
  if (slash == std::string_view::npos) return {};
  const std::string_view id = rest.substr(0, slash);
  const std::string_view tail = rest.substr(slash + 1);
  if (!ReportId(id)) return {};
  if (tail == "complete") {
    request.target = Target::kComplete;
    request.id = std::string(id);
    return request;
  }
  constexpr std::string_view files = "files/";
  if (!tail.starts_with(files)) return {};
  const std::string_view name = tail.substr(files.size());
  const std::optional<int64_t> limit = FileLimit(name);
  if (!limit) return {};
  request.target = Target::kFile;
  request.id = std::string(id);
  request.file = std::string(name);
  request.max_bytes = *limit;
  return request;
}

bool MethodAllowed(Target target, std::string_view method) {
  if (target == Target::kCreate || target == Target::kComplete) return method == "POST";
  return target == Target::kFile && method == "PUT";
}

std::optional<std::vector<Header>> AllowedHeaders(Target target, const std::vector<Header>& given) {
  if (target == Target::kRefused || given.size() > 8) return std::nullopt;
  std::vector<Header> allowed;
  bool key = false;
  bool authorization = false;
  bool type = false;
  for (const auto& [name, value] : given) {
    if (!PrintableValue(value)) return std::nullopt;
    if (EqualsIgnoringCase(name, "X-Ray-Key")) {
      if (key || value.size() > 64) return std::nullopt;
      key = true;
      allowed.emplace_back("X-Ray-Key", value);
    } else if (EqualsIgnoringCase(name, "Authorization")) {
      if (authorization || target == Target::kCreate || !BearerToken(value)) return std::nullopt;
      authorization = true;
      allowed.emplace_back("Authorization", value);
    } else if (EqualsIgnoringCase(name, "Content-Type")) {
      if (type || !MediaType(value)) return std::nullopt;
      if (target != Target::kFile && !EqualsIgnoringCase(value, "application/json")) return std::nullopt;
      type = true;
      allowed.emplace_back("Content-Type", value);
    } else {
      return std::nullopt;
    }
  }
  if (!key || (target != Target::kCreate && !authorization) || (target == Target::kFile && !type)) return std::nullopt;
  return allowed;
}

bool UploadSizeAllowed(const Request& request, int64_t bytes) {
  return request.target == Target::kFile && bytes >= 1 && bytes <= request.max_bytes;
}

std::string ReplyText(std::string_view body, size_t limit) {
  return std::string(body.substr(0, Utf8Prefix(body, limit)));
}

int64_t Gzip(const GzipRead& read, const GzipWrite& write) {
  z_stream stream = {};
  if (deflateInit2(&stream, 6, Z_DEFLATED, 31, 8, Z_DEFAULT_STRATEGY) != Z_OK) return -1;
  const auto input = std::make_unique<uint8_t[]>(kChunk);
  const auto output = std::make_unique<uint8_t[]>(kChunk);
  int64_t written = 0;
  int flush = Z_NO_FLUSH;
  bool failed = false;
  while (!failed && flush != Z_FINISH) {
    const int64_t count = read(input.get(), kChunk);
    if (count < 0 || static_cast<uint64_t>(count) > kChunk) {
      failed = true;
      break;
    }
    flush = count == 0 ? Z_FINISH : Z_NO_FLUSH;
    stream.next_in = input.get();
    stream.avail_in = static_cast<uInt>(count);
    do {
      stream.next_out = output.get();
      stream.avail_out = static_cast<uInt>(kChunk);
      if (deflate(&stream, flush) == Z_STREAM_ERROR) {
        failed = true;
        break;
      }
      const size_t produced = kChunk - stream.avail_out;
      if (produced > 0 && !write(output.get(), produced)) {
        failed = true;
        break;
      }
      written += static_cast<int64_t>(produced);
    } while (stream.avail_out == 0);
  }
  deflateEnd(&stream);
  return failed ? -1 : written;
}

}
