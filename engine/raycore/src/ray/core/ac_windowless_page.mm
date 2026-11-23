// Copyright 2026 Ray. Apache-2.0.

#include "ray/core/ac_windowless_page.h"

#import <AppKit/AppKit.h>

#include <algorithm>

#include "ray/core/ac_browser.h"
#include "ray/core/ac_content_hooks.h"
#include "base/auto_reset.h"
#include "chrome/browser/ui/browser.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "content/public/browser/render_view_host.h"
#include "content/public/browser/render_widget_host.h"
#include "content/public/browser/render_widget_host_view.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_user_data.h"
#include "ui/gfx/geometry/point.h"
#include "ui/gfx/geometry/rect.h"
#include "ui/gfx/geometry/size.h"
#include "ui/gfx/mac/coordinate_conversion.h"

namespace raycore {

namespace {

WindowlessPageTotals g_totals;

class WindowlessPageCounted
    : public content::WebContentsUserData<WindowlessPageCounted> {
 public:
  static void Note(content::WebContents* contents, bool given) {
    CreateForWebContents(contents);
    WindowlessPageCounted* counted = FromWebContents(contents);
    if (given && !counted->given_) {
      counted->given_ = true;
      ++g_totals.given;
    } else if (!given && !counted->missed_) {
      counted->missed_ = true;
      ++g_totals.missed;
    }
  }

 private:
  explicit WindowlessPageCounted(content::WebContents* contents)
      : content::WebContentsUserData<WindowlessPageCounted>(*contents) {}
  friend class content::WebContentsUserData<WindowlessPageCounted>;
  WEB_CONTENTS_USER_DATA_KEY_DECL();

  bool given_ = false;
  bool missed_ = false;
};

WEB_CONTENTS_USER_DATA_KEY_IMPL(WindowlessPageCounted);

bool ShowsPages(WindowHost* host) {
  return host && !host->internal() && !host->automation() &&
         host->ns_window().visible;
}

WindowHost* FrontWindowShowingPages() {
  for (NSWindow* window in NSApp.orderedWindows) {
    WindowHost* host = WindowHost::ForNSWindow(window);
    if (ShowsPages(host)) {
      return host;
    }
  }
  return nullptr;
}

content::RenderWidgetHostView* ShownPageView(WindowHost* host,
                                             content::WebContents* except) {
  NSWindow* window = host->ns_window();
  for (Browser* browser : host->browsers()) {
    TabStripModel* model = browser->GetTabStripModel();
    for (int i = 0; i < model->count(); ++i) {
      content::WebContents* contents = model->GetWebContentsAt(i);
      content::RenderWidgetHostView* view =
          contents && contents != except ? contents->GetRenderWidgetHostView()
                                         : nullptr;
      NSView* page = view ? view->GetNativeView().GetNativeNSView() : nil;
      if (page.window == window && !page.hiddenOrHasHiddenAncestor &&
          !NSIsEmptyRect(page.bounds)) {
        return view;
      }
    }
  }
  return nullptr;
}

content::WebContents* PageContents(content::RenderWidgetHost* widget) {
  content::RenderViewHost* page =
      widget ? content::RenderViewHost::From(widget) : nullptr;
  return page ? content::WebContents::FromRenderViewHost(page) : nullptr;
}

bool HiddenWidgetTakesScreenRects(content::RenderWidgetHost* widget) {
  return WindowHost::ForContents(PageContents(widget));
}

bool WindowlessPageScreenRects(content::RenderWidgetHost* widget,
                               const gfx::Size& view_size,
                               gfx::Rect* window_frame,
                               gfx::Point* view_origin) {
  static bool answering = false;
  if (answering) {
    return false;
  }
  base::AutoReset<bool> answer(&answering, true);
  content::WebContents* contents = PageContents(widget);
  WindowHost* holder = WindowHost::ForContents(contents);
  if (!holder) {
    return false;
  }
  WindowHost* shown = ShowsPages(holder) ? holder : FrontWindowShowingPages();
  if (!shown) {
    WindowlessPageCounted::Note(contents, false);
    return false;
  }
  WindowlessPageCounted::Note(contents, true);
  *window_frame = gfx::ScreenRectFromNSRect(shown->ns_window().frame);
  if (content::RenderWidgetHostView* sibling = ShownPageView(shown, contents)) {
    const gfx::Rect bounds = sibling->GetViewBounds();
    *view_origin = gfx::Point(bounds.x() - window_frame->x(),
                              bounds.y() - window_frame->y());
  } else {
    *view_origin =
        gfx::Point(std::max(0, window_frame->width() - view_size.width()),
                   std::max(0, window_frame->height() - view_size.height()));
  }
  return true;
}

}

WindowlessPageTotals WindowlessPagesSoFar() {
  return g_totals;
}

void InstallWindowlessPageGeometry() {
  g_ray_windowless_page_screen_rects = &WindowlessPageScreenRects;
  g_ray_hidden_widget_takes_screen_rects = &HiddenWidgetTakesScreenRects;
}

}
