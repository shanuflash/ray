#ifndef RAY_CORE_AC_EXTENSION_DROP_H_
#define RAY_CORE_AC_EXTENSION_DROP_H_

namespace content {
struct DropData;
class WebContents;
}

namespace raycore {

bool InstallDroppedExtensions(content::WebContents* contents,
                              const content::DropData& drop);

}

#endif
