#ifndef RAY_LINUX_AC_LINUX_PAGE_EVALUATION_H_
#define RAY_LINUX_AC_LINUX_PAGE_EVALUATION_H_

#include <stddef.h>

#include <functional>
#include <optional>
#include <span>
#include <string>
#include <string_view>

#include "ray/linux/ac_linux_page_operations.h"
#include "base/values.h"

namespace raycore {

inline constexpr size_t kLinuxPageEvaluationCodeMax = 64 * 1024;
inline constexpr size_t kLinuxPageEvaluationResultMax = 4 * 1024 * 1024;
inline constexpr size_t kLinuxPageReplaceTextMax = 4096;
inline constexpr double kLinuxPickerCoordinateMax = 1e6;
inline constexpr size_t kLinuxPickerSelectorsMax = 512;
inline constexpr size_t kLinuxPickerSelectorMax = 3072;

using LinuxPageDigest = std::function<std::string(std::string_view)>;
using LinuxPageJsonList = std::function<std::optional<base::Value>(std::string_view)>;

struct LinuxPageOperationMatch {
  const LinuxPageOperation* operation = nullptr;
  std::string_view arguments;
};

std::optional<LinuxPageOperationMatch> MatchLinuxPageOperation(
    std::string_view code, const LinuxPageDigest& digest,
    std::span<const LinuxPageOperation> operations = kLinuxPageOperations);
std::optional<std::string> LinuxReplaceArguments(const base::Value& arguments);
std::optional<std::string> LinuxReaderLookArgument(const base::Value& arguments);
std::optional<std::string> LinuxPickerPointArgument(const base::Value& arguments);
std::optional<std::string> LinuxPickerSelectorsArgument(const base::Value& arguments);
std::string LinuxJavaScriptString(std::string_view text);
std::optional<std::string> LinuxPageEvaluationScript(
    std::string_view code, const LinuxPageDigest& digest, const LinuxPageJsonList& parse_list,
    std::span<const LinuxPageOperation> operations = kLinuxPageOperations);
std::optional<std::string> LinuxPageEvaluationResult(const base::Value& value);

}

#endif
