#include <cassert>
#include <cstdio>
#include <string>
#include <vector>

#include "ray/linux/ac_linux_notifications_core.cc"

namespace notifications = ray::linux_notifications;

namespace {

notifications::Post Posted(std::string id, bool dismissible = false, int owner = 7) {
  notifications::Post post;
  post.id = std::move(id);
  post.dismissible = dismissible;
  post.owner = owner;
  post.tab_id = "tab-1";
  post.data = "{\"meeting\":\"m1\"}";
  return post;
}

void Text() {
  assert(notifications::ValidId("meeting:2026-11-14T10:00"));
  assert(notifications::ValidId(std::string(notifications::kIdBytes, 'a')));
  assert(!notifications::ValidId(""));
  assert(!notifications::ValidId(std::string(notifications::kIdBytes + 1, 'a')));
  assert(!notifications::ValidId("a\nb"));
  assert(!notifications::ValidId(std::string("a\0b", 3)));
  assert(!notifications::ValidId("a\x7f"));
  assert(notifications::ValidReference(""));
  assert(notifications::ValidReference("window-1"));
  assert(!notifications::ValidReference(std::string(notifications::kReferenceBytes + 1, 'a')));
  assert(!notifications::ValidReference("a\tb"));

  assert(notifications::Clip("hello", 10) == "hello");
  assert(notifications::Clip("hello", 5) == "hello");
  assert(notifications::Clip("hello", 2) == "he");
  assert(notifications::Clip("", 0).empty());
  assert(notifications::Clip("a\xC3\xA9", 2) == "a");
  assert(notifications::Clip("a\xC3\xA9", 3) == "a\xC3\xA9");
  assert(notifications::Clip("\xF0\x9F\x98\x80\xF0\x9F\x98\x80", 7) == "\xF0\x9F\x98\x80");
  assert(notifications::Clip("\xF0\x9F\x98\x80", 3).empty());
  assert(notifications::Clip("\x80\x80\x80\x80", 2).empty());

  assert(notifications::BodyText("", "Starts in 5 min") == "Starts in 5 min");
  assert(notifications::BodyText("Calendar", "") == "Calendar");
  assert(notifications::BodyText("Calendar", "Starts in 5 min") == "Calendar\nStarts in 5 min");
  assert(notifications::BodyText("", "").empty());
  assert(notifications::BodyText("s", std::string(notifications::kBodyBytes, 'b')).size() == notifications::kBodyBytes);

  assert(notifications::ChromiumId("meeting:1") == "ray:meeting:1");
  assert(notifications::RayId("ray:meeting:1") == "meeting:1");
  assert(!notifications::RayId("meeting:1"));
  assert(!notifications::RayId("ray:"));
  assert(!notifications::RayId("p#https://example.com#1"));
  assert(!notifications::RayId("ray:a\nb"));
  assert(notifications::PermissionName(false) == "granted");
  assert(notifications::PermissionName(true) == "denied");
}

void Responses() {
  notifications::Ledger ledger;
  assert(ledger.Add(Posted("one")).empty());
  assert(ledger.Add(Posted("two", true, 9)).empty());
  assert(ledger.size() == 2);

  const auto clicked = ledger.Clicked("one");
  assert(clicked && clicked->id == "one" && clicked->action == "click" && clicked->owner == 7);
  assert(clicked->tab_id == "tab-1" && !clicked->window_id && clicked->data == "{\"meeting\":\"m1\"}");
  assert(!ledger.Clicked("one"));
  assert(!ledger.Closed("one", true));

  const auto closed = ledger.Closed("two", true);
  assert(closed && closed->action == "close" && closed->owner == 9);
  assert(ledger.size() == 0);

  ledger.Add(Posted("quiet", false));
  assert(!ledger.Closed("quiet", true));
  assert(!ledger.Clicked("quiet"));
  ledger.Add(Posted("expired", true));
  assert(!ledger.Closed("expired", false));
  assert(!ledger.Clicked("expired"));
  assert(!ledger.Clicked("never"));
  assert(!ledger.Remove("never"));

  ledger.Add(Posted("again", false, 1));
  ledger.Add(Posted("again", true, 2));
  assert(ledger.size() == 1);
  const auto replaced = ledger.Closed("again", true);
  assert(replaced && replaced->owner == 2);

  ledger.Add(Posted("gone"));
  assert(ledger.Remove("gone"));
  assert(!ledger.Clicked("gone"));
}

void Limit() {
  notifications::Ledger ledger;
  for (size_t index = 0; index < notifications::kLiveNotifications; ++index) {
    assert(ledger.Add(Posted("n" + std::to_string(index))).empty());
  }
  assert(ledger.Add(Posted("n1")).empty());
  const std::vector<std::string> evicted = ledger.Add(Posted("extra"));
  assert(evicted == std::vector<std::string>{"n0"});
  assert(ledger.size() == notifications::kLiveNotifications);
  assert(!ledger.Clicked("n0"));
  assert(ledger.Clicked("n2"));
  assert(ledger.Add(Posted("more")).empty());
  assert(ledger.Add(Posted("most")) == std::vector<std::string>{"n3"});
}

}

int main(int argc, char** argv) {
  assert(argc == 2);
  const std::string scenario = argv[1];
  if (scenario == "text") Text();
  else if (scenario == "responses") Responses();
  else if (scenario == "limit") Limit();
  else return 2;
  std::puts("ok");
  return 0;
}
