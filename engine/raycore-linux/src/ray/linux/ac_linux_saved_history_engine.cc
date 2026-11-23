#include "ray/linux/ac_linux_saved_history_engine.h"

#include <memory>
#include <optional>
#include <utility>

#include "ray/linux/ac_linux_saved_history.h"
#include "base/files/file_path.h"
#include "base/files/file_util.h"
#include "base/functional/bind.h"
#include "base/json/json_reader.h"
#include "base/location.h"
#include "base/task/thread_pool.h"
#include "base/values.h"
#include "chrome/browser/ray/public/ac_engine.h"
#include "chrome/browser/profiles/profile.h"

namespace raycore {

namespace {

namespace saved_history = linux_saved_history;

struct GenerationRead {
  base::FilePath profile_dir;
  std::string key;
  std::string url;
  base::OnceCallback<void(std::string)> done;
};

std::optional<saved_history::SavedTabHistory> ParseSavedHistory(const std::string& text) {
  const auto value = base::JSONReader::Read(text, base::JSON_PARSE_RFC);
  const base::DictValue* dict = value && value->is_dict() ? &value->GetDict() : nullptr;
  if (!dict) return std::nullopt;
  saved_history::SavedTabHistory saved;
  saved.version = dict->FindInt("version");
  if (const std::string* url = dict->FindString("url")) saved.url = *url;
  if (const std::string* shown = dict->FindString("virtualUrl")) saved.virtual_url = *shown;
  if (const std::string* generation = dict->FindString("generation")) saved.generation = *generation;
  if (const std::string* state = dict->FindString("state")) saved.state = *state;
  return saved;
}

std::string ReadSavedState(base::FilePath profile_dir, std::string key, std::string url,
                           std::optional<std::string> generation) {
  if (!generation) {
    const base::FilePath marker = profile_dir.AppendASCII(saved_history::kTabHistoryMarker);
    std::string contents;
    const bool exists = base::PathExists(marker);
    const bool read = exists && base::ReadFileToStringWithMaxSize(marker, &contents, 64);
    generation = saved_history::MarkerGeneration(exists, read ? std::optional<std::string>(contents) : std::nullopt);
  }
  const base::FilePath file = profile_dir.AppendASCII(saved_history::kTabHistoryDir)
                                  .AppendASCII(saved_history::SavedHistoryFileName(key));
  std::string text;
  if (!base::ReadFileToStringWithMaxSize(file, &text, saved_history::kMaxSavedHistoryBytes)) return std::string();
  return saved_history::RestorableState(ParseSavedHistory(text), text.size(), url, generation).value_or(std::string());
}

void GenerationReplied(void* context, const char* json) {
  std::unique_ptr<GenerationRead> read(static_cast<GenerationRead*>(context));
  const auto value = json ? base::JSONReader::Read(json, base::JSON_PARSE_RFC) : std::nullopt;
  const base::DictValue* reply = value && value->is_dict() ? &value->GetDict() : nullptr;
  if (!reply || reply->Find("error")) return std::move(read->done).Run(std::string());
  std::optional<std::string> generation;
  if (const std::string* known = reply->FindString("generation")) {
    generation = *known;
  } else if (reply->FindBool("fromMarker") != true) {
    return std::move(read->done).Run(std::string());
  }
  base::ThreadPool::PostTaskAndReplyWithResult(
      FROM_HERE, {base::MayBlock(), base::TaskPriority::USER_BLOCKING},
      base::BindOnce(&ReadSavedState, read->profile_dir, read->key, read->url, std::move(generation)),
      std::move(read->done));
}

}

void ReadLinuxSavedTabHistory(Profile* profile, const std::string& key, const std::string& url,
                              base::OnceCallback<void(std::string)> done) {
  if (!profile || profile->IsOffTheRecord()) return std::move(done).Run(std::string());
  auto* read = new GenerationRead{profile->GetPath(), key, url, std::move(done)};
  ac_engine_call("ac_tab_history_generation", profile->GetPath().value().c_str(), "{}", &GenerationReplied, read);
}

}
