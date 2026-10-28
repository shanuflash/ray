// Copyright 2026 Ray. Apache-2.0.

#include "ray/core/ac_contents_background.h"

#include "content/public/browser/devtools_agent_host.h"
#include "content/public/browser/devtools_agent_host_observer.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/navigation_entry.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/render_view_host.h"
#include "content/public/browser/render_widget_host_view.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_observer.h"
#include "content/public/browser/web_contents_user_data.h"

namespace raycore {

namespace {

enum class AheadBlank { kNone, kLoading, kShown, kEnded };

bool DevToolsAttached(content::WebContents& contents) {
  return content::DevToolsAgentHost::HasFor(&contents) &&
         content::DevToolsAgentHost::GetOrCreateFor(&contents)->IsAttached();
}

class ContentsBackground : public content::WebContentsObserver,
                           public content::WebContentsUserData<ContentsBackground>,
                           public content::DevToolsAgentHostObserver {
 public:
  ~ContentsBackground() override { StopWatchingDevTools(); }

  void SetColor(std::optional<SkColor> color) {
    color_ = color ? std::optional<SkColor>(SkColorSetA(*color, SK_AlphaOPAQUE)) : std::nullopt;
    ApplyView();
    ApplyPageBase();
  }

  void SetHostPageBase(std::optional<SkColor> color) {
    host_page_base_ = color;
    ApplyPageBase();
  }

  void MarkAheadBlank() {
    if (ahead_blank_ != AheadBlank::kNone) {
      return;
    }
    content::NavigationController& controller = GetWebContents().GetController();
    content::NavigationEntry* committed = controller.GetLastCommittedEntry();
    if (GetWebContents().HasOpener() || DevToolsAttached(GetWebContents())) {
      ahead_blank_ = AheadBlank::kEnded;
    } else if (!committed || committed->IsInitialEntry()) {
      ahead_blank_ = AheadBlank::kLoading;
    } else if (controller.GetEntryCount() == 1 && committed->GetURL().IsAboutBlank()) {
      ahead_blank_ = AheadBlank::kShown;
    } else {
      ahead_blank_ = AheadBlank::kEnded;
    }
    if (ahead_blank_ != AheadBlank::kEnded && !watching_devtools_) {
      watching_devtools_ = true;
      content::DevToolsAgentHost::AddObserver(this);
    }
    ApplyPageBase();
  }

  void EndAheadBlank() {
    if (ahead_blank_ == AheadBlank::kEnded) {
      return;
    }
    ahead_blank_ = AheadBlank::kEnded;
    StopWatchingDevTools();
    ApplyPageBase();
  }

  std::optional<SkColor> color() const { return color_; }

  bool in_ahead_blank() const {
    return ahead_blank_ == AheadBlank::kLoading || ahead_blank_ == AheadBlank::kShown;
  }

 private:
  explicit ContentsBackground(content::WebContents* contents)
      : content::WebContentsObserver(contents),
        content::WebContentsUserData<ContentsBackground>(*contents) {}
  friend class content::WebContentsUserData<ContentsBackground>;
  WEB_CONTENTS_USER_DATA_KEY_DECL();

  void StopWatchingDevTools() {
    if (watching_devtools_) {
      watching_devtools_ = false;
      content::DevToolsAgentHost::RemoveObserver(this);
    }
  }

  void DevToolsAgentHostAttached(content::DevToolsAgentHost* host) override {
    if (host->GetWebContents() == &GetWebContents()) {
      EndAheadBlank();
    }
  }

  bool AheadBlankShowsBackdrop() const {
    return color_ && !host_page_base_ &&
           (ahead_blank_ == AheadBlank::kLoading || ahead_blank_ == AheadBlank::kShown);
  }

  void ApplyView() {
    content::RenderWidgetHostView* view = GetWebContents().GetRenderWidgetHostView();
    if (view) {
      view->SetBackgroundColor(color_.value_or(SK_ColorWHITE));
    }
  }

  void ApplyPageBase() {
    std::optional<SkColor> base =
        AheadBlankShowsBackdrop() ? std::optional<SkColor>(SK_ColorTRANSPARENT) : host_page_base_;
    if (base == applied_page_base_) {
      return;
    }
    applied_page_base_ = base;
    GetWebContents().SetPageBaseBackgroundColor(base);
  }

  void RenderFrameHostChanged(content::RenderFrameHost* old_host,
                              content::RenderFrameHost* new_host) override {
    if (new_host && new_host == GetWebContents().GetPrimaryMainFrame()) {
      ApplyView();
    }
  }
  void RenderViewHostChanged(content::RenderViewHost* old_host,
                             content::RenderViewHost* new_host) override {
    ApplyView();
  }
  void RenderViewReady() override { ApplyView(); }

  void DidStartNavigation(content::NavigationHandle* navigation) override {
    if (navigation->IsInPrimaryMainFrame() && navigation->IsSameDocument()) {
      EndAheadBlank();
    }
    if (navigation->IsInPrerenderedMainFrame() && applied_page_base_ == SK_ColorTRANSPARENT) {
      prerender_saw_backdrop_ = true;
      EndAheadBlank();
    }
  }

  void ReadyToCommitNavigation(content::NavigationHandle* navigation) override {
    if (!navigation->IsInPrimaryMainFrame() || navigation->IsSameDocument()) {
      return;
    }
    if (ahead_blank_ == AheadBlank::kLoading && navigation->GetURL().IsAboutBlank()) {
      ahead_blank_ = AheadBlank::kShown;
      return;
    }
    EndAheadBlank();
  }

  void DidFinishNavigation(content::NavigationHandle* navigation) override {
    if (!prerender_saw_backdrop_ || !navigation->IsPrerenderedPageActivation() ||
        !navigation->HasCommitted()) {
      return;
    }
    prerender_saw_backdrop_ = false;
    GetWebContents().SetPageBaseBackgroundColor(SK_ColorWHITE);
    applied_page_base_ = SK_ColorWHITE;
    ApplyPageBase();
  }

  std::optional<SkColor> color_;
  std::optional<SkColor> host_page_base_;
  std::optional<SkColor> applied_page_base_;
  AheadBlank ahead_blank_ = AheadBlank::kNone;
  bool prerender_saw_backdrop_ = false;
  bool watching_devtools_ = false;
};

WEB_CONTENTS_USER_DATA_KEY_IMPL(ContentsBackground);

ContentsBackground* For(content::WebContents* contents) {
  ContentsBackground::CreateForWebContents(contents);
  return ContentsBackground::FromWebContents(contents);
}

}

bool InAheadBlank(content::WebContents* contents) {
  ContentsBackground* background = ContentsBackground::FromWebContents(contents);
  return background && background->in_ahead_blank();
}

void SetContentsBackgroundColor(content::WebContents* contents, std::optional<SkColor> color) {
  For(contents)->SetColor(color);
}

std::optional<SkColor> ContentsBackgroundColor(content::WebContents* contents) {
  ContentsBackground* background = ContentsBackground::FromWebContents(contents);
  return background ? background->color() : std::nullopt;
}

void SetHostPageBaseBackgroundColor(content::WebContents* contents, std::optional<SkColor> color) {
  For(contents)->SetHostPageBase(color);
}

void MarkAheadBlank(content::WebContents* contents) {
  For(contents)->MarkAheadBlank();
}

void EndAheadBlank(content::WebContents* contents) {
  if (ContentsBackground* background = ContentsBackground::FromWebContents(contents)) {
    background->EndAheadBlank();
  }
}

}
