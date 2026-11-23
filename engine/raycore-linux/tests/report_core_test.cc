#include <cassert>
#include <cstdio>
#include <cstring>
#include <string>
#include <string_view>
#include <vector>

#include "ray/linux/ac_linux_report_core.h"

using namespace ray::linux_report;

namespace {

constexpr std::string_view kDrafts = "/home/u/.config/ray/Default/Ray/Report Drafts";
constexpr std::string_view kDraft = "/home/u/.config/ray/Default/Ray/Report Drafts/0f8fad5b-d9cb-469f-a165-70867728950e";

std::string In(std::string_view tail) {
  return std::string(kDraft) + std::string(tail);
}

void OnlyPathsInsideADraftFolderAreTouched() {
  assert(InsideDrafts(kDrafts, kDraft));
  assert(InsideDrafts(kDrafts, In("/recording.mp4")));
  assert(InsideDrafts(kDrafts, In("/nested/local-events.jsonl.gz")));
  assert(!InsideDrafts(kDrafts, kDrafts));
  assert(!InsideDrafts(kDrafts, std::string(kDrafts) + "/"));
  assert(!InsideDrafts(kDrafts, std::string(kDrafts) + "/notes.txt"));
  assert(!InsideDrafts(kDrafts, std::string(kDrafts) + "/../Preferences"));
  assert(!InsideDrafts(kDrafts, In("/../../Preferences")));
  assert(!InsideDrafts(kDrafts, In("/./a")));
  assert(!InsideDrafts(kDrafts, In("//a")));
  assert(!InsideDrafts(kDrafts, In("/a/")));
  assert(!InsideDrafts(kDrafts, In("/a/..")));
  assert(!InsideDrafts(kDrafts, std::string(kDrafts) + "x/0f8fad5b-d9cb-469f-a165-70867728950e/a"));
  assert(!InsideDrafts(kDrafts, "/etc/passwd"));
  assert(!InsideDrafts(kDrafts, ""));
  assert(!InsideDrafts(kDrafts, "relative/0f8fad5b-d9cb-469f-a165-70867728950e"));
  assert(!InsideDrafts("", In("/a")));
  assert(!InsideDrafts("relative", "relative/0f8fad5b-d9cb-469f-a165-70867728950e/a"));
  assert(!InsideDrafts(std::string(kDrafts) + "/", In("/a")));
  assert(!InsideDrafts(kDrafts, In(std::string("/a\0b", 4))));
  assert(!InsideDrafts(kDrafts, In("/" + std::string(kPathMaxBytes, 'a'))));
  assert(DraftFolderName("0f8fad5b-d9cb-469f-a165-70867728950e"));
  assert(DraftFolderName("0F8FAD5B-D9CB-469F-A165-70867728950E"));
  assert(!DraftFolderName("0f8fad5b-d9cb-469f-a165-70867728950"));
  assert(!DraftFolderName("0f8fad5b_d9cb-469f-a165-70867728950e"));
  assert(!DraftFolderName("0f8fad5b-d9cb-469f-a165-70867728950g"));
  assert(!DraftFolderName(".."));
}

void OnlyTheFeedbackEndpointIsReached() {
  const std::string_view endpoint = kEndpoint;
  assert(endpoint == "https://github.com/shanuflash/ray/api/feedback");
  assert(ClassifyUrl(endpoint, "https://github.com/shanuflash/ray/api/feedback").target == Target::kCreate);
  const Request complete = ClassifyUrl(endpoint, "https://github.com/shanuflash/ray/api/feedback/FB-7K2Q/complete");
  assert(complete.target == Target::kComplete && complete.id == "FB-7K2Q");
  const Request file = ClassifyUrl(endpoint, "https://github.com/shanuflash/ray/api/feedback/FB-7K2QX/files/recording.mp4");
  assert(file.target == Target::kFile && file.id == "FB-7K2QX" && file.file == "recording.mp4" && file.max_bytes == 100 * kMiB);
  for (const char* refused : {
           "https://github.com/shanuflash/ray/api/feedback/",
           "https://github.com/shanuflash/ray/api/feedback?x=1",
           "https://github.com/shanuflash/ray/api/feedback#x",
           "https://github.com/shanuflash/ray/api/feedbackx",
           "https://github.com/shanuflash/ray/api/feedback/FB-7K2Q",
           "https://github.com/shanuflash/ray/api/feedback/FB-7K2Q/",
           "https://github.com/shanuflash/ray/api/feedback/FB-7K2Q/complete/",
           "https://github.com/shanuflash/ray/api/feedback/FB-7K2Q/complete?x",
           "https://github.com/shanuflash/ray/api/feedback/FB-7K2Q/files/",
           "https://github.com/shanuflash/ray/api/feedback/FB-7K2Q/files/notes.txt",
           "https://github.com/shanuflash/ray/api/feedback/FB-7K2Q/files/recording.mp4/x",
           "https://github.com/shanuflash/ray/api/feedback/FB-7K2Q/files/..%2Fcomplete",
           "https://github.com/shanuflash/ray/api/feedback/../feedback",
           "https://github.com/shanuflash/ray/api/feedback/FB-7K1Q/complete",
           "https://github.com/shanuflash/ray/api/feedback/FB-7KOQ/complete",
           "https://github.com/shanuflash/ray/api/feedback/fb-7k2q/complete",
           "https://github.com/shanuflash/ray/api/feedback/FB-7K2QXY/complete",
           "https://github.com/shanuflash/ray/api/feedback/FB-7K/complete",
           "https://github.com/shanuflash/ray.evil.example/api/feedback",
           "https://evil.example/api/feedback",
           "http://github.com/shanuflash/ray/api/feedback",
           "https://github.com/shanuflash/ray:8443/api/feedback",
           "https://user@github.com/shanuflash/ray/api/feedback",
           "HTTPS://RAY.DEV/api/feedback",
           " https://github.com/shanuflash/ray/api/feedback",
           "file:///etc/passwd",
           ""}) {
    assert(ClassifyUrl(endpoint, refused).target == Target::kRefused);
  }
  assert(ClassifyUrl("", "").target == Target::kRefused);
  assert(ClassifyUrl(endpoint, std::string(endpoint) + "/FB-7K2Q/files/attachment-1." + std::string(3000, 'a')).target == Target::kRefused);
}

void AttachmentNamesAndCapsAreTheServices() {
  assert(FileLimit("recording.mp4") == 100 * kMiB);
  assert(FileLimit("trace.json.gz") == 50 * kMiB);
  assert(FileLimit("local-events.jsonl.gz") == 10 * kMiB);
  assert(FileLimit("crash-1.ips") == 10 * kMiB);
  assert(FileLimit("crash-99.ips") == 10 * kMiB);
  assert(FileLimit("attachment-7.png") == 10 * kMiB);
  assert(FileLimit("attachment-12.jsonl") == 10 * kMiB);
  for (const char* refused : {"", "recording.mov", "Recording.mp4", "crash-0.ips", "crash-100.ips", "crash-01.ips", "crash-1.txt",
                              "crash-.ips", "attachment-1.", "attachment-1.PNG", "attachment-1.toolongext", "attachment-a.png",
                              "attachment-1.p/g", "attachment-1", "../recording.mp4", "recording.mp4 "}) {
    assert(!FileLimit(refused));
  }
  const Request file = ClassifyUrl(kEndpoint, "https://github.com/shanuflash/ray/api/feedback/FB-7K2Q/files/local-events.jsonl.gz");
  assert(UploadSizeAllowed(file, 1));
  assert(UploadSizeAllowed(file, 10 * kMiB));
  assert(!UploadSizeAllowed(file, 10 * kMiB + 1));
  assert(!UploadSizeAllowed(file, 0));
  assert(!UploadSizeAllowed(file, -1));
  assert(!UploadSizeAllowed(ClassifyUrl(kEndpoint, kEndpoint), 10));
}

void EachRequestTakesItsOwnMethodAndHeaders() {
  assert(MethodAllowed(Target::kCreate, "POST") && MethodAllowed(Target::kComplete, "POST") && MethodAllowed(Target::kFile, "PUT"));
  assert(!MethodAllowed(Target::kCreate, "PUT") && !MethodAllowed(Target::kFile, "POST") && !MethodAllowed(Target::kFile, "DELETE"));
  assert(!MethodAllowed(Target::kRefused, "POST") && !MethodAllowed(Target::kCreate, "post") && !MethodAllowed(Target::kCreate, ""));
  const Header key{"X-Ray-Key", "ak_app_41b5d0762fd8ade6949ac2ac"};
  const Header json{"Content-Type", "application/json"};
  const Header bearer{"Authorization", "Bearer eyJhbGciOi.abc-_~+/="};
  const auto create = AllowedHeaders(Target::kCreate, {json, key});
  assert(create && create->size() == 2);
  assert(AllowedHeaders(Target::kCreate, {key}));
  assert(!AllowedHeaders(Target::kCreate, {json}));
  assert(!AllowedHeaders(Target::kCreate, {json, key, bearer}));
  assert(!AllowedHeaders(Target::kCreate, {key, {"Content-Type", "text/plain"}}));
  assert(AllowedHeaders(Target::kComplete, {json, bearer, key}));
  assert(!AllowedHeaders(Target::kComplete, {json, key}));
  const auto put = AllowedHeaders(Target::kFile, {bearer, {"x-ray-key", key.second}, {"content-type", "video/mp4"}});
  assert(put && (*put)[1].first == "X-Ray-Key" && (*put)[2].first == "Content-Type" && (*put)[2].second == "video/mp4");
  assert(!AllowedHeaders(Target::kFile, {bearer, key}));
  assert(!AllowedHeaders(Target::kFile, {key, {"Content-Type", "video/mp4"}}));
  assert(!AllowedHeaders(Target::kFile, {bearer, key, {"Content-Type", "video"}}));
  assert(!AllowedHeaders(Target::kFile, {bearer, key, {"Content-Type", "video/mp4; x=1"}}));
  assert(!AllowedHeaders(Target::kFile, {bearer, key, {"Content-Type", "video/mp4"}, {"Cookie", "a=b"}}));
  assert(!AllowedHeaders(Target::kFile, {bearer, key, {"Content-Type", "video/mp4"}, {"Host", "evil.example"}}));
  assert(!AllowedHeaders(Target::kFile, {bearer, bearer, key, {"Content-Type", "video/mp4"}}));
  assert(!AllowedHeaders(Target::kFile, {{"Authorization", "Basic abc"}, key, {"Content-Type", "video/mp4"}}));
  assert(!AllowedHeaders(Target::kFile, {{"Authorization", "Bearer a b"}, key, {"Content-Type", "video/mp4"}}));
  assert(!AllowedHeaders(Target::kFile, {{"Authorization", "Bearer abc\r\nX-Evil: 1"}, key, {"Content-Type", "video/mp4"}}));
  assert(!AllowedHeaders(Target::kFile, {bearer, {"X-Ray-Key", "a\nb"}, {"Content-Type", "video/mp4"}}));
  assert(!AllowedHeaders(Target::kFile, {bearer, {"X-Ray-Key", std::string(65, 'a')}, {"Content-Type", "video/mp4"}}));
  assert(!AllowedHeaders(Target::kFile, {bearer, {"X-Ray-Key", ""}, {"Content-Type", "video/mp4"}}));
  assert(!AllowedHeaders(Target::kRefused, {key}));
  assert(!AllowedHeaders(Target::kCreate, std::vector<Header>(9, key)));
}

void RepliesAreCutAtAWholeCharacter() {
  assert(ReplyText("hello", 4096) == "hello");
  assert(ReplyText("hello", 3) == "hel");
  assert(ReplyText("a\xc3\xa9z", 2) == "a");
  assert(ReplyText("a\xc3\xa9z", 3) == "a\xc3\xa9");
  assert(ReplyText("ok\xff\xfe", 4096) == "ok");
  assert(ReplyText("\xe2\x82", 4096).empty());
  assert(ReplyText("\xed\xa0\x80", 4096).empty());
  assert(ReplyText("\xc0\xaf", 4096).empty());
  assert(ReplyText("\xf0\x9f\x98\x80!", 4096) == "\xf0\x9f\x98\x80!");
  assert(ReplyText("\xf4\x90\x80\x80", 4096).empty());
  assert(ReplyText("", 0).empty());
  assert(ReplyText(std::string_view("a\0b", 3), 4096) == std::string_view("a\0b", 3));
}

int GzipFile(const char* source, const char* destination) {
  std::FILE* in = std::fopen(source, "rb");
  std::FILE* out = std::fopen(destination, "wb");
  if (!in || !out) return 3;
  const int64_t written = Gzip(
      [&](uint8_t* buffer, size_t capacity) { return static_cast<int64_t>(std::fread(buffer, 1, capacity, in)); },
      [&](const uint8_t* data, size_t size) { return std::fwrite(data, 1, size, out) == size; });
  std::fclose(in);
  std::fclose(out);
  std::printf("%lld\n", static_cast<long long>(written));
  return written < 0 ? 4 : 0;
}

void AFailedReadOrWriteFailsTheWholeGzip() {
  int reads = 0;
  assert(Gzip([&](uint8_t* buffer, size_t capacity) { std::memset(buffer, 'a', capacity); return ++reads < 3 ? static_cast<int64_t>(capacity) : -1; },
              [](const uint8_t*, size_t) { return true; }) == -1);
  assert(Gzip([](uint8_t*, size_t capacity) { return static_cast<int64_t>(capacity) + 1; },
              [](const uint8_t*, size_t) { return true; }) == -1);
  bool sent = false;
  assert(Gzip([&](uint8_t* buffer, size_t) { if (sent) return int64_t{0}; sent = true; buffer[0] = 'x'; return int64_t{1}; },
              [](const uint8_t*, size_t) { return false; }) == -1);
  std::string empty;
  const int64_t bytes = Gzip([](uint8_t*, size_t) { return int64_t{0}; },
                             [&](const uint8_t* data, size_t size) { empty.append(reinterpret_cast<const char*>(data), size); return true; });
  assert(bytes == static_cast<int64_t>(empty.size()) && bytes >= 18);
  assert(static_cast<unsigned char>(empty[0]) == 0x1f && static_cast<unsigned char>(empty[1]) == 0x8b);
}

}

int main(int argc, char** argv) {
  if (argc == 4 && std::string_view(argv[1]) == "gzip") return GzipFile(argv[2], argv[3]);
  if (argc != 1) return 2;
  OnlyPathsInsideADraftFolderAreTouched();
  OnlyTheFeedbackEndpointIsReached();
  AttachmentNamesAndCapsAreTheServices();
  EachRequestTakesItsOwnMethodAndHeaders();
  RepliesAreCutAtAWholeCharacter();
  AFailedReadOrWriteFailsTheWholeGzip();
  std::puts("ok");
  return 0;
}
