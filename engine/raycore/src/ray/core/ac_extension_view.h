#ifndef RAY_CORE_AC_EXTENSION_VIEW_H_
#define RAY_CORE_AC_EXTENSION_VIEW_H_

class Browser;
class GURL;

namespace content {
class WebContents;
}

namespace gfx {
class Size;
}

namespace raycore {

enum class ExtensionViewKind { kPopup, kSidePanel };

content::WebContents* OpenExtensionView(Browser* browser,
                                        const GURL& url,
                                        ExtensionViewKind kind);

bool CloseExtensionView(content::WebContents* contents);

void CloseAllExtensionViews();

gfx::Size ExtensionPopupPreferredSize(content::WebContents* contents);

void InstallActionPopupHook();

}

#endif
