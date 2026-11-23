#include <cassert>
#include <cstdio>
#include <string>

#include "ray/linux/ac_linux_bang_list_policy.h"

namespace bang_list = ray::linux_bang_list;

int main() {
  using bang_list::Failure;
  assert(bang_list::kListUrl == "https://services.helium.imput.net/bangs.json");
  assert(bang_list::kMaxBytes == 5000000);

  assert(bang_list::EtagSent("\"abc\""));
  assert(bang_list::EtagSent("W/\"abc def\""));
  assert(bang_list::EtagSent(std::string(bang_list::kMaxEtagBytes, 'e')));
  assert(!bang_list::EtagSent(""));
  assert(!bang_list::EtagSent(std::string(bang_list::kMaxEtagBytes + 1, 'e')));
  assert(!bang_list::EtagSent("\"a\"\r\nCookie: x"));
  assert(!bang_list::EtagSent("\"a\"\n"));
  assert(!bang_list::EtagSent(std::string("\"a\0\"", 4)));
  assert(!bang_list::EtagSent("\"a\x7f\""));

  assert(bang_list::Admits(0) && bang_list::Admits(1));
  assert(!bang_list::Admits(2) && !bang_list::Admits(-1));

  assert(bang_list::BodyReturned(200));
  assert(!bang_list::BodyReturned(304) && !bang_list::BodyReturned(404) && !bang_list::BodyReturned(0));

  assert(bang_list::Judge(true, true, true, false, true, 200) == Failure::kNone);
  assert(bang_list::Judge(true, true, true, false, true, 304) == Failure::kNone);
  assert(bang_list::Judge(true, true, true, false, false, 404) == Failure::kNone);
  assert(bang_list::Judge(true, true, true, false, false, 200) == Failure::kNotUtf8);
  assert(bang_list::Judge(true, true, false, false, false, 200) == Failure::kNetwork);
  assert(bang_list::Judge(false, true, false, true, false, 200) == Failure::kTooLarge);
  assert(bang_list::Judge(false, false, false, false, false, 0) == Failure::kNetwork);
  assert(bang_list::Judge(true, false, true, false, true, 0) == Failure::kNoResponse);

  assert(bang_list::FailureMessage(Failure::kTooLarge) == "too large");
  assert(bang_list::FailureMessage(Failure::kNotUtf8) == "not UTF-8");
  assert(bang_list::FailureMessage(Failure::kNoResponse) == "no response");
  assert(!bang_list::FailureMessage(Failure::kNetwork).empty());
  assert(bang_list::FailureMessage(Failure::kNone).empty());
  std::puts("ok");
  return 0;
}
