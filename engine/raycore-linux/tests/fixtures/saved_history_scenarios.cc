#include <cassert>
#include <cstdio>
#include <optional>
#include <string>

#include "ray/linux/ac_linux_saved_history.h"

using namespace raycore::linux_saved_history;

namespace {

SavedHistoryRequest Wake() {
  SavedHistoryRequest request;
  request.key = "tab-1";
  request.url = "https://example.net/";
  return request;
}

SavedTabHistory Saved() {
  SavedTabHistory saved;
  saved.version = 1;
  saved.url = "https://example.net/";
  saved.virtual_url = "https://example.net/";
  saved.generation = "g1";
  saved.state = "STATE";
  return saved;
}

void ReadsOnlyForAQuietWakeOfARegularTab() {
  assert(ReadsSavedHistory(Wake()));
  auto request = Wake();
  request.off_the_record = true;
  assert(!ReadsSavedHistory(request));
  request = Wake();
  request.temporary = true;
  assert(!ReadsSavedHistory(request));
  request = Wake();
  request.user_initiated = true;
  assert(!ReadsSavedHistory(request));
  request = Wake();
  request.already_read = true;
  assert(!ReadsSavedHistory(request));
  request = Wake();
  request.adoption = "restore:tab-1";
  assert(!ReadsSavedHistory(request));
  request = Wake();
  request.key.clear();
  assert(!ReadsSavedHistory(request));
  request = Wake();
  request.url = "about:blank";
  assert(!ReadsSavedHistory(request));
  request.url.clear();
  assert(!ReadsSavedHistory(request));
}

void NamesTheFileAsTheEngineWritesIt() {
  assert(SavedHistoryFileName("tab-1") == "7461622D31");
  assert(SavedHistoryFileName(std::string("\xff\x00", 2)) == "FF00");
  assert(SavedHistoryFileName("").empty());
}

void RestoresOnlyAMatchingVersionOneFile() {
  const std::optional<std::string> g1 = std::string("g1");
  assert(RestorableState(Saved(), 100, "https://example.net/", g1) == "STATE");
  assert(RestorableState(Saved(), 100, "https://example.net/#part", g1) == "STATE");
  assert(!RestorableState(std::nullopt, 0, "https://example.net/", g1));
  assert(!RestorableState(Saved(), 0, "https://example.net/", g1));
  assert(!RestorableState(Saved(), kMaxSavedHistoryBytes + 1, "https://example.net/", g1));

  auto saved = Saved();
  saved.version = 2;
  assert(!RestorableState(saved, 100, "https://example.net/", g1));
  saved.version = std::nullopt;
  assert(!RestorableState(saved, 100, "https://example.net/", g1));

  saved = Saved();
  saved.state.clear();
  assert(!RestorableState(saved, 100, "https://example.net/", g1));

  assert(!RestorableState(Saved(), 100, "https://example.com/", g1));
  saved = Saved();
  saved.url = "https://example.net/redirected";
  assert(RestorableState(saved, 100, "https://example.net/", g1) == "STATE");
  saved.virtual_url = "https://example.net/other";
  assert(!RestorableState(saved, 100, "https://example.net/", g1));

  assert(!RestorableState(Saved(), 100, "https://example.net/", std::string("g2")));
  assert(!RestorableState(Saved(), 100, "https://example.net/", std::nullopt));
  saved = Saved();
  saved.generation = std::nullopt;
  assert(!RestorableState(saved, 100, "https://example.net/", g1));
}

void ReadsTheGenerationFromTheMarkerAsTheMacDoes() {
  assert(MarkerGeneration(false, std::nullopt) == std::string());
  assert(MarkerGeneration(true, std::string(" g7\n")) == std::string("g7"));
  assert(!MarkerGeneration(true, std::nullopt));
}

}

int main() {
  ReadsOnlyForAQuietWakeOfARegularTab();
  NamesTheFileAsTheEngineWritesIt();
  RestoresOnlyAMatchingVersionOneFile();
  ReadsTheGenerationFromTheMarkerAsTheMacDoes();
  std::puts("saved history scenarios passed");
  return 0;
}
