#ifndef RAY_LINUX_AC_LINUX_SEARCH_ENGINES_H_
#define RAY_LINUX_AC_LINUX_SEARCH_ENGINES_H_

#include <optional>
#include <string>

namespace raycore {

std::optional<std::string> SetLinuxDefaultSearchEngine(std::string name, std::string keyword, std::string url);

}

#endif
