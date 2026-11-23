#include "ray/linux/ac_linux_page_evaluation.h"

#include <cmath>
#include <utility>

#include "base/strings/stringprintf.h"

namespace raycore {

namespace {

bool BoundedText(const base::Value& value) {
  if (!value.is_string()) return false;
  const std::string& text = value.GetString();
  return text.size() <= kLinuxPageReplaceTextMax && text.find('\0') == std::string::npos;
}

}

std::optional<LinuxPageOperationMatch> MatchLinuxPageOperation(
    std::string_view code, const LinuxPageDigest& digest, std::span<const LinuxPageOperation> operations) {
  if (code.empty() || code.size() > kLinuxPageEvaluationCodeMax || !digest) return std::nullopt;
  for (const LinuxPageOperation& operation : operations) {
    if (operation.args == LinuxPageOperationArgs::kNone) {
      if (code.size() == operation.length && digest(code) == operation.sha256)
        return LinuxPageOperationMatch{&operation, {}};
      continue;
    }
    const std::string_view suffix = operation.suffix;
    if (suffix.empty() || code.size() <= operation.length + suffix.size() || !code.ends_with(suffix)) continue;
    if (digest(code.substr(0, operation.length)) != operation.sha256) continue;
    return LinuxPageOperationMatch{&operation, code.substr(operation.length, code.size() - operation.length - suffix.size())};
  }
  return std::nullopt;
}

std::string LinuxJavaScriptString(std::string_view text) {
  std::string out = "\"";
  for (size_t i = 0; i < text.size(); ++i) {
    const unsigned char c = static_cast<unsigned char>(text[i]);
    if (c == '"' || c == '\\') {
      out += '\\';
      out += static_cast<char>(c);
    } else if (c < 0x20 || c == '<' || c == '>' || c == 0x7f) {
      out += base::StringPrintf("\\u%04x", c);
    } else if (c == 0xe2 && i + 2 < text.size() && static_cast<unsigned char>(text[i + 1]) == 0x80 &&
               (static_cast<unsigned char>(text[i + 2]) == 0xa8 || static_cast<unsigned char>(text[i + 2]) == 0xa9)) {
      out += static_cast<unsigned char>(text[i + 2]) == 0xa8 ? "\\u2028" : "\\u2029";
      i += 2;
    } else {
      out += static_cast<char>(c);
    }
  }
  return out + "\"";
}

std::optional<std::string> LinuxReplaceArguments(const base::Value& arguments) {
  if (!arguments.is_list()) return std::nullopt;
  const auto& list = arguments.GetList();
  if (list.size() != 3 || !BoundedText(list[0]) || !BoundedText(list[1]) || !list[2].is_bool()) return std::nullopt;
  return LinuxJavaScriptString(list[0].GetString()) + ", " + LinuxJavaScriptString(list[1].GetString()) + ", " +
         (list[2].GetBool() ? "true" : "false");
}

std::optional<std::string> LinuxReaderLookArgument(const base::Value& arguments) {
  if (!arguments.is_list() || arguments.GetList().size() != 1 || !arguments.GetList()[0].is_dict()) return std::nullopt;
  const auto& look = arguments.GetList()[0].GetDict();
  const auto dark = look.FindBool("dark");
  const auto size = look.FindInt("size");
  const std::string* font = look.FindString("font");
  if (look.size() != 3 || !dark || !size || *size < 0 || *size >= kLinuxReaderLookSizes || !font) return std::nullopt;
  for (std::string_view known : kLinuxReaderLookFonts) {
    if (*font == known) {
      return base::StringPrintf("{\"dark\":%s,\"size\":%d,\"font\":\"%s\"}", *dark ? "true" : "false", *size,
                                std::string(known).c_str());
    }
  }
  return std::nullopt;
}

std::optional<std::string> LinuxPickerPointArgument(const base::Value& arguments) {
  if (!arguments.is_list() || arguments.GetList().size() != 1) return std::nullopt;
  const base::Value& point = arguments.GetList()[0];
  if (point.is_none()) return std::string("null");
  if (!point.is_list() || point.GetList().size() != 2) return std::nullopt;
  std::string out = "[";
  for (size_t i = 0; i < 2; ++i) {
    const base::Value& coordinate = point.GetList()[i];
    if (!coordinate.is_int() && !coordinate.is_double()) return std::nullopt;
    const double value = coordinate.GetDouble();
    if (!std::isfinite(value) || std::fabs(value) > kLinuxPickerCoordinateMax) return std::nullopt;
    out += (i ? "," : "") + base::StringPrintf("%.17g", value);
  }
  return out + "]";
}

std::optional<std::string> LinuxPickerSelectorsArgument(const base::Value& arguments) {
  if (!arguments.is_list() || arguments.GetList().size() != 1 || !arguments.GetList()[0].is_list()) return std::nullopt;
  const auto& selectors = arguments.GetList()[0].GetList();
  if (selectors.size() > kLinuxPickerSelectorsMax) return std::nullopt;
  std::string out = "[";
  for (size_t i = 0; i < selectors.size(); ++i) {
    const base::Value& selector = selectors[i];
    if (!selector.is_string() || selector.GetString().empty() || selector.GetString().size() > kLinuxPickerSelectorMax ||
        selector.GetString().find('\0') != std::string::npos) {
      return std::nullopt;
    }
    if (i) out += ",";
    out += LinuxJavaScriptString(selector.GetString());
  }
  return out + "]";
}

std::optional<std::string> LinuxPageEvaluationScript(
    std::string_view code, const LinuxPageDigest& digest, const LinuxPageJsonList& parse_list,
    std::span<const LinuxPageOperation> operations) {
  auto match = MatchLinuxPageOperation(code, digest, operations);
  if (!match) return std::nullopt;
  std::string body;
  if (match->operation->args == LinuxPageOperationArgs::kNone) {
    body = std::string(code);
  } else {
    if (!parse_list) return std::nullopt;
    auto parsed = parse_list("[" + std::string(match->arguments) + "]");
    std::optional<std::string> arguments;
    if (parsed && match->operation->args == LinuxPageOperationArgs::kReplace) arguments = LinuxReplaceArguments(*parsed);
    if (parsed && match->operation->args == LinuxPageOperationArgs::kLook) arguments = LinuxReaderLookArgument(*parsed);
    if (parsed && match->operation->args == LinuxPageOperationArgs::kPoint) arguments = LinuxPickerPointArgument(*parsed);
    if (parsed && match->operation->args == LinuxPageOperationArgs::kSelectors) arguments = LinuxPickerSelectorsArgument(*parsed);
    if (!arguments) return std::nullopt;
    body = std::string(code.substr(0, match->operation->length)) + *arguments + std::string(match->operation->suffix);
  }
  return "(() => {\n"
         "let rayResult = null;\n"
         "const post = (kind, value) => { if (kind === \"result\" && rayResult === null && typeof value === \"string\") rayResult = value; };\n"
         "try {\n" + body + "\n;\n} catch (rayError) {}\n"
         "return rayResult;\n"
         "})()";
}

std::optional<std::string> LinuxPageEvaluationResult(const base::Value& value) {
  if (!value.is_string() || value.GetString().size() > kLinuxPageEvaluationResultMax) return std::nullopt;
  return value.GetString();
}

}
