#ifndef RAY_CORE_AC_STRINGS_H_
#define RAY_CORE_AC_STRINGS_H_

#include <string>

#include "ui/base/resource/resource_bundle.h"

namespace raycore {

ui::ResourceBundle::Delegate* ProductStrings();

bool RenameProduct(std::u16string& text);

}

#endif
