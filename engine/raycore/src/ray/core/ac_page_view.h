#ifndef RAY_CORE_AC_PAGE_VIEW_H_
#define RAY_CORE_AC_PAGE_VIEW_H_

#import <Cocoa/Cocoa.h>

@protocol RenderWidgetHostViewMacDelegate;

namespace content {
class RenderWidgetHost;
}

namespace raycore {

NSObject<RenderWidgetHostViewMacDelegate>* CreatePageViewDelegate(
    content::RenderWidgetHost* host);

}

#endif
