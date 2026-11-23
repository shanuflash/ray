#ifndef RAY_LINUX_AC_LINUX_WINDOW_COMMANDS_H_
#define RAY_LINUX_AC_LINUX_WINDOW_COMMANDS_H_

#include <optional>
#include <string_view>

namespace ray::linux_commands {

inline constexpr char kToggleFullScreenCall[] = "RayShell.toggleFullScreen";
inline constexpr char kEditCapability[] = "tab.edit";
inline constexpr char kEditCommand[] = "edit";
inline constexpr char kReadTextCall[] = "RayShell.readText";
inline constexpr const char* kWindowCommandCapabilities[] = {"RayShell.toggleFullScreen", "tab.edit",
                                                             "RayShell.readText"};

enum class EditAction { kUndo, kRedo, kCut, kCopy, kPaste, kPasteAndMatchStyle, kSelectAll };

struct EditName {
  std::string_view name;
  EditAction action;
};

inline constexpr EditName kEditActions[] = {
    {"undo", EditAction::kUndo},
    {"redo", EditAction::kRedo},
    {"cut", EditAction::kCut},
    {"copy", EditAction::kCopy},
    {"paste", EditAction::kPaste},
    {"pasteAndMatchStyle", EditAction::kPasteAndMatchStyle},
    {"selectAll", EditAction::kSelectAll},
};

constexpr std::optional<EditAction> ParseEditAction(std::string_view name) {
  for (const EditName& known : kEditActions) {
    if (known.name == name) return known.action;
  }
  return std::nullopt;
}

constexpr bool FullScreenAfterToggle(bool window_full_screen) {
  return !window_full_screen;
}

}

#endif
