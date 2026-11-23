#include "ray/linux/ac_linux_secret_text.h"

#include <sys/mman.h>
#include <unistd.h>

#include <algorithm>
#include <cstring>

namespace ray::linux_password {
namespace {

bool IsLead(char16_t unit) {
  return unit >= 0xD800 && unit <= 0xDBFF;
}

bool IsTrail(char16_t unit) {
  return unit >= 0xDC00 && unit <= 0xDFFF;
}

bool Typeable(char16_t unit) {
  return unit >= 0x20 && (unit < 0x7F || unit > 0x9F);
}

size_t EncodeUtf8(char32_t point, char* out) {
  if (point < 0x80) {
    out[0] = static_cast<char>(point);
    return 1;
  }
  if (point < 0x800) {
    out[0] = static_cast<char>(0xC0 | (point >> 6));
    out[1] = static_cast<char>(0x80 | (point & 0x3F));
    return 2;
  }
  if (point < 0x10000) {
    out[0] = static_cast<char>(0xE0 | (point >> 12));
    out[1] = static_cast<char>(0x80 | ((point >> 6) & 0x3F));
    out[2] = static_cast<char>(0x80 | (point & 0x3F));
    return 3;
  }
  out[0] = static_cast<char>(0xF0 | (point >> 18));
  out[1] = static_cast<char>(0x80 | ((point >> 12) & 0x3F));
  out[2] = static_cast<char>(0x80 | ((point >> 6) & 0x3F));
  out[3] = static_cast<char>(0x80 | (point & 0x3F));
  return 4;
}

}

void WipeBytes(void* data, size_t size) {
  volatile unsigned char* bytes = static_cast<volatile unsigned char*>(data);
  for (size_t i = 0; i < size; ++i) {
    bytes[i] = 0;
  }
  __asm__ __volatile__("" : : "r"(data) : "memory");
}

SecretPage::SecretPage(size_t bytes) {
  const long page = sysconf(_SC_PAGESIZE);
  const size_t unit = page > 0 ? static_cast<size_t>(page) : 4096;
  const size_t length = (std::max<size_t>(bytes, 1) + unit - 1) / unit * unit;
  void* mapped = mmap(nullptr, length, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  if (mapped == MAP_FAILED) {
    return;
  }
  madvise(mapped, length, MADV_DONTDUMP);
#ifdef MADV_WIPEONFORK
  madvise(mapped, length, MADV_WIPEONFORK);
#endif
  mlock(mapped, length);
  data_ = static_cast<unsigned char*>(mapped);
  size_ = bytes;
  mapped_ = length;
}

SecretPage::~SecretPage() {
  if (!data_) {
    return;
  }
  WipeBytes(data_, mapped_);
  munlock(data_, mapped_);
  munmap(data_, mapped_);
}

SecretBytes::SecretBytes(size_t capacity) : page_(capacity + 1), capacity_(page_.ok() ? capacity : 0) {}

std::string_view SecretBytes::view() const {
  if (!page_.ok()) {
    return std::string_view();
  }
  return std::string_view(reinterpret_cast<const char*>(page_.data()), size_);
}

bool SecretBytes::Append(std::string_view bytes) {
  if (!page_.ok() || bytes.size() > capacity_ - size_) {
    return false;
  }
  std::memcpy(page_.data() + size_, bytes.data(), bytes.size());
  size_ += bytes.size();
  return true;
}

void SecretBytes::Clear() {
  if (page_.ok()) {
    WipeBytes(page_.data(), page_.size());
  }
  size_ = 0;
}

SecretText::SecretText(size_t capacity_units)
    : page_(capacity_units * sizeof(char16_t)), capacity_(page_.ok() ? capacity_units : 0) {}

char16_t* SecretText::units() const {
  return reinterpret_cast<char16_t*>(page_.data());
}

std::u16string_view SecretText::view() const {
  if (!page_.ok()) {
    return std::u16string_view();
  }
  return std::u16string_view(units(), size_);
}

size_t SecretText::Before(size_t at) const {
  const char16_t* data = units();
  if (at >= 2 && IsTrail(data[at - 1]) && IsLead(data[at - 2])) {
    return at - 2;
  }
  return at - 1;
}

size_t SecretText::After(size_t at) const {
  const char16_t* data = units();
  if (at + 1 < size_ && IsLead(data[at]) && IsTrail(data[at + 1])) {
    return at + 2;
  }
  return at + 1;
}

size_t SecretText::CodePoints() const {
  size_t count = 0;
  for (size_t at = 0; at < size_; at = After(at)) {
    ++count;
  }
  return count;
}

size_t SecretText::CodePointsBeforeCursor() const {
  size_t count = 0;
  for (size_t at = 0; at < cursor_; at = After(at)) {
    ++count;
  }
  return count;
}

void SecretText::Erase(size_t from, size_t to) {
  to = std::min(to, size_);
  if (from >= to) {
    return;
  }
  char16_t* data = units();
  const size_t removed = to - from;
  std::memmove(data + from, data + to, (size_ - to) * sizeof(char16_t));
  WipeBytes(data + size_ - removed, removed * sizeof(char16_t));
  size_ -= removed;
  if (cursor_ >= to) {
    cursor_ -= removed;
  } else if (cursor_ > from) {
    cursor_ = from;
  }
}

bool SecretText::TakeSelection() {
  if (!all_selected()) {
    all_selected_ = false;
    return false;
  }
  Clear();
  return true;
}

bool SecretText::Insert(std::u16string_view text) {
  if (!ok()) {
    return false;
  }
  size_t accepted = 0;
  for (char16_t unit : text) {
    accepted += Typeable(unit) ? 1 : 0;
  }
  if (accepted == 0) {
    return true;
  }
  const size_t kept = all_selected() ? 0 : size_;
  if (accepted > capacity_ - kept) {
    return false;
  }
  TakeSelection();
  char16_t* data = units();
  std::memmove(data + cursor_ + accepted, data + cursor_, (size_ - cursor_) * sizeof(char16_t));
  size_t at = cursor_;
  for (char16_t unit : text) {
    if (Typeable(unit)) {
      data[at++] = unit;
    }
  }
  size_ += accepted;
  cursor_ += accepted;
  return true;
}

void SecretText::Backspace() {
  if (TakeSelection() || cursor_ == 0) {
    return;
  }
  Erase(Before(cursor_), cursor_);
}

void SecretText::BackspaceToStart() {
  if (TakeSelection()) {
    return;
  }
  Erase(0, cursor_);
}

void SecretText::DeleteForward() {
  if (TakeSelection() || cursor_ >= size_) {
    return;
  }
  Erase(cursor_, After(cursor_));
}

void SecretText::DeleteSurrounding(size_t before, size_t after) {
  all_selected_ = false;
  const char16_t* data = units();
  size_t from = cursor_ > before ? cursor_ - before : 0;
  size_t to = std::min(size_, cursor_ + std::min(after, size_));
  if (from > 0 && from < size_ && IsTrail(data[from]) && IsLead(data[from - 1])) {
    --from;
  }
  if (to > 0 && to < size_ && IsTrail(data[to]) && IsLead(data[to - 1])) {
    ++to;
  }
  Erase(from, to);
}

void SecretText::MoveLeft() {
  if (all_selected()) {
    all_selected_ = false;
    cursor_ = 0;
    return;
  }
  all_selected_ = false;
  if (cursor_ > 0) {
    cursor_ = Before(cursor_);
  }
}

void SecretText::MoveRight() {
  if (all_selected()) {
    all_selected_ = false;
    cursor_ = size_;
    return;
  }
  all_selected_ = false;
  if (cursor_ < size_) {
    cursor_ = After(cursor_);
  }
}

void SecretText::MoveHome() {
  all_selected_ = false;
  cursor_ = 0;
}

void SecretText::MoveEnd() {
  all_selected_ = false;
  cursor_ = size_;
}

void SecretText::SelectAll() {
  all_selected_ = size_ > 0;
  cursor_ = size_;
}

void SecretText::Clear() {
  if (page_.ok()) {
    WipeBytes(page_.data(), page_.size());
  }
  size_ = 0;
  cursor_ = 0;
  all_selected_ = false;
}

std::unique_ptr<SecretBytes> SecretText::Utf8() const {
  auto out = std::make_unique<SecretBytes>(capacity_ * 3);
  if (!out->ok()) {
    return nullptr;
  }
  const char16_t* data = units();
  char encoded[4];
  for (size_t at = 0; at < size_;) {
    char32_t point = data[at];
    size_t next = at + 1;
    if (IsLead(data[at]) && next < size_ && IsTrail(data[next])) {
      point = 0x10000 + ((static_cast<char32_t>(data[at]) - 0xD800) << 10) + (data[next] - 0xDC00);
      ++next;
    } else if (IsLead(data[at]) || IsTrail(data[at])) {
      point = 0xFFFD;
    }
    const size_t length = EncodeUtf8(point, encoded);
    const bool appended = out->Append(std::string_view(encoded, length));
    WipeBytes(encoded, sizeof(encoded));
    if (!appended) {
      return nullptr;
    }
    at = next;
  }
  return out;
}

}
