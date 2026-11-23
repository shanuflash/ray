#ifndef RAY_LINUX_AC_LINUX_BANG_LIST_POLICY_H_
#define RAY_LINUX_AC_LINUX_BANG_LIST_POLICY_H_

#include <cstddef>
#include <string_view>

namespace ray::linux_bang_list {

inline constexpr char kCall[] = "RayShell.fetchBangList";
inline constexpr std::string_view kListUrl = "https://services.helium.imput.net/bangs.json";
inline constexpr size_t kMaxBytes = 5'000'000;
inline constexpr size_t kMaxEtagBytes = 200;
inline constexpr int kTimeoutSeconds = 60;
inline constexpr int kMaxInFlight = 2;
inline constexpr char kErrorCode[] = "ERR_BANG_LIST";

constexpr bool EtagSent(std::string_view etag) {
  if (etag.empty() || etag.size() > kMaxEtagBytes) return false;
  for (const char c : etag) {
    const unsigned char byte = static_cast<unsigned char>(c);
    if (byte < 0x20 || byte == 0x7f) return false;
  }
  return true;
}

constexpr bool Admits(int in_flight) {
  return in_flight >= 0 && in_flight < kMaxInFlight;
}

constexpr bool BodyReturned(int status) {
  return status == 200;
}

enum class Failure { kNone, kNetwork, kNoResponse, kTooLarge, kNotUtf8 };

constexpr Failure Judge(bool loaded, bool has_response, bool has_body, bool exceeded, bool utf8, int status) {
  if (exceeded) return Failure::kTooLarge;
  if (!loaded) return Failure::kNetwork;
  if (!has_response) return Failure::kNoResponse;
  if (BodyReturned(status) && (!has_body || !utf8)) return has_body ? Failure::kNotUtf8 : Failure::kNetwork;
  return Failure::kNone;
}

constexpr std::string_view FailureMessage(Failure failure) {
  switch (failure) {
    case Failure::kNone: return "";
    case Failure::kNetwork: return "The bang list could not be fetched";
    case Failure::kNoResponse: return "no response";
    case Failure::kTooLarge: return "too large";
    case Failure::kNotUtf8: return "not UTF-8";
  }
  return "";
}

}

#endif
