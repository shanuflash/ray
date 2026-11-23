#include "ray/linux/ac_linux_notifications_core.h"

#include <algorithm>
#include <utility>

namespace ray::linux_notifications {

namespace {

bool Control(char c) {
  const unsigned char byte = static_cast<unsigned char>(c);
  return byte < 0x20 || byte == 0x7f;
}

Response ResponseFor(Post post, std::string_view action) {
  Response response;
  response.id = std::move(post.id);
  response.action = std::string(action);
  response.tab_id = std::move(post.tab_id);
  response.window_id = std::move(post.window_id);
  response.data = std::move(post.data);
  response.owner = post.owner;
  return response;
}

}

bool ValidId(std::string_view id) {
  return !id.empty() && id.size() <= kIdBytes && std::ranges::none_of(id, Control);
}

bool ValidReference(std::string_view text) {
  return text.size() <= kReferenceBytes && std::ranges::none_of(text, Control);
}

std::string Clip(std::string_view utf8, size_t bytes) {
  if (utf8.size() <= bytes) return std::string(utf8);
  size_t end = bytes;
  while (end > 0 && (static_cast<unsigned char>(utf8[end]) & 0xC0) == 0x80) --end;
  return std::string(utf8.substr(0, end));
}

std::string BodyText(std::string_view subtitle, std::string_view body) {
  if (subtitle.empty()) return Clip(body, kBodyBytes);
  if (body.empty()) return Clip(subtitle, kBodyBytes);
  std::string text(subtitle);
  text += '\n';
  text += body;
  return Clip(text, kBodyBytes);
}

std::string ChromiumId(std::string_view id) {
  return std::string(kChromiumPrefix) + std::string(id);
}

std::optional<std::string> RayId(std::string_view chromium_id) {
  const std::string_view prefix(kChromiumPrefix);
  if (!chromium_id.starts_with(prefix)) return std::nullopt;
  const std::string_view id = chromium_id.substr(prefix.size());
  if (!ValidId(id)) return std::nullopt;
  return std::string(id);
}

std::string_view PermissionName(bool background) {
  return background ? "denied" : "granted";
}

Ledger::Ledger() = default;
Ledger::~Ledger() = default;

std::vector<std::string> Ledger::Add(Post post) {
  std::vector<std::string> evicted;
  Take(post.id);
  while (posts_.size() >= kLiveNotifications) {
    evicted.push_back(std::move(posts_.front().id));
    posts_.erase(posts_.begin());
  }
  posts_.push_back(std::move(post));
  return evicted;
}

bool Ledger::Remove(std::string_view id) {
  return Take(id).has_value();
}

std::optional<Response> Ledger::Clicked(std::string_view id) {
  auto post = Take(id);
  if (!post) return std::nullopt;
  return ResponseFor(std::move(*post), "click");
}

std::optional<Response> Ledger::Closed(std::string_view id, bool by_user) {
  auto post = Take(id);
  if (!post || !by_user || !post->dismissible) return std::nullopt;
  return ResponseFor(std::move(*post), "close");
}

std::optional<Post> Ledger::Take(std::string_view id) {
  const auto found = std::ranges::find_if(posts_, [id](const Post& post) { return post.id == id; });
  if (found == posts_.end()) return std::nullopt;
  Post post = std::move(*found);
  posts_.erase(found);
  return post;
}

}
