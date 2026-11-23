#ifndef RAY_LINUX_AC_LINUX_PAGE_OPERATIONS_H_
#define RAY_LINUX_AC_LINUX_PAGE_OPERATIONS_H_

#include <stddef.h>

#include <array>
#include <string_view>

namespace raycore {

enum class LinuxPageOperationArgs { kNone, kReplace, kLook, kPoint, kSelectors };

struct LinuxPageOperation {
  std::string_view name;
  size_t length;
  std::string_view sha256;
  LinuxPageOperationArgs args;
  std::string_view suffix;
};

inline constexpr int kLinuxReaderLookSizes = 5;
inline constexpr std::array<std::string_view, 2> kLinuxReaderLookFonts = {{"serif", "sans"}};

inline constexpr std::array<LinuxPageOperation, 16> kLinuxPageOperations = {{
    {"selectionContext", 1008, "62ba51dd7be1cd91d50b0589d3ed77c5f255976d926e396238962989cfe5bab6", LinuxPageOperationArgs::kNone, ""},
    {"hasSelection", 69, "9bb48919244a58886c424cbc69298a078e3d3958c320cb696c7ac697facdb811", LinuxPageOperationArgs::kNone, ""},
    {"jumpToSelection", 1751, "bac34cf89afc24d8bb87418864914717a177d14adeb141e91fdd111b0ecba730", LinuxPageOperationArgs::kNone, ""},
    {"replaceInField", 3685, "47debcd4188e773db97bd81d575c0b524ef0c4d1b444eb012a6f50a074cb9b2c", LinuxPageOperationArgs::kReplace, ")"},
    {"selectedText", 81, "e981a1488b91874e78f575240afb0c8fa7431ef388b18bb0c2338d0b31c77252", LinuxPageOperationArgs::kNone, ""},
    {"readerCheck", 18409, "0c26c24a94b2d2030e9b9c618ca2acfcd13f234524542e0979e82e91df45b8c4", LinuxPageOperationArgs::kNone, ""},
    {"readerState", 17147, "4f0ed0c89ce38fdec3af8252822057b58f3ca0a738757fd9c3a9a0155d8caad2", LinuxPageOperationArgs::kNone, ""},
    {"readerHide", 17146, "6c1f8760dc42acce73c0622573ea41c2fb081b92c53686a04bf2ffe4dcb4b852", LinuxPageOperationArgs::kNone, ""},
    {"readerToggle", 49893, "d308bd02475dcedefef0db7b1bbb8af12f29ce4c00d75669fac7917e43dbf097", LinuxPageOperationArgs::kLook, ")));"},
    {"readerOpen", 49891, "38f24060b18afbf6c013b629935341e66f45afd8a78881e0a77fcc6288167651", LinuxPageOperationArgs::kLook, ")));"},
    {"readerSetLook", 17144, "64bf8983a477d7a4adfde4a9d08140a14874fe44e135d2174259a14c94e0f9d1", LinuxPageOperationArgs::kLook, "])));"},
    {"elementPickerStart", 11671, "33829e4d5f85222208e734c9a767bba59aac7488860d00b99ee37c11cfb9be48", LinuxPageOperationArgs::kPoint, "])).then((v) => { window[Symbol.for(\"ray.elementPicker\")].linuxPick = { value: v === undefined ? null : v }; }, () => { window[Symbol.for(\"ray.elementPicker\")].linuxPick = { value: null }; });"},
    {"elementPickerTake", 324, "0f0eaa1b3b91b91af67550c35b0afcfe7d0310c9ef3a06855624985631327045", LinuxPageOperationArgs::kNone, ""},
    {"elementPickerCancel", 11753, "e13d35dad4acfc37802e6ac1fdb2547453cc7f80e5607026542d3788a5d984ce", LinuxPageOperationArgs::kNone, ""},
    {"elementPickerApply", 11671, "9796cc69325a00533bdc7dd50a588aaaa21c615ca4f6be04f6f4722703408589", LinuxPageOperationArgs::kSelectors, "])).then((v) => post(\"result\", JSON.stringify(v)), () => post(\"result\", \"null\"));"},
    {"elementPickerUnhide", 11672, "184e2774a14737606df07e951ed6444d36e2a5fc39747f902caceb61acc1a339", LinuxPageOperationArgs::kSelectors, "])).then((v) => post(\"result\", JSON.stringify(v)), () => post(\"result\", \"null\"));"},
}};

}

#endif
