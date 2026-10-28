#include "ray/core/ac_autofill_trigger.h"

#include "base/functional/bind.h"
#include "base/memory/weak_ptr.h"
#include "base/strings/sys_string_conversions.h"
#include "base/task/single_thread_task_runner.h"
#include "components/autofill/core/browser/suggestions/suggestion.h"
#include "components/autofill/core/browser/suggestions/suggestion_type.h"
#include "components/autofill/content/browser/content_autofill_client.h"
#include "components/autofill/content/browser/content_autofill_driver.h"
#include "components/autofill/core/browser/foundations/autofill_driver.h"
#include "components/autofill/core/browser/foundations/autofill_manager.h"
#include "components/autofill/core/browser/foundations/scoped_autofill_managers_observation.h"
#include "components/autofill/core/common/aliases.h"
#include "components/autofill/core/common/unique_ids.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_user_data.h"
#include "ray/core/ac_hooks.h"
#include "ray/core/ac_browser.h"
#import "ray/core/raycore_internal.h"

namespace raycore {

namespace {

using autofill::AutofillManager;
using autofill::AutofillSuggestionTriggerSource;
using autofill::FieldGlobalId;
using autofill::FormGlobalId;

class FocusedField : public content::WebContentsUserData<FocusedField>,
                     public AutofillManager::Observer {
 public:
  FocusedField(const FocusedField&) = delete;
  FocusedField& operator=(const FocusedField&) = delete;
  ~FocusedField() override = default;

  bool Trigger(AutofillSuggestionTriggerSource source) {
    AutofillManager* manager = manager_.get();
    content::RenderFrameHost* frame = GetWebContents().GetFocusedFrame();
    auto* driver =
        frame ? autofill::ContentAutofillDriver::GetForRenderFrameHost(frame)
              : nullptr;
    if (!manager || !driver || !driver->IsActive() ||
        &driver->GetAutofillManager() != manager) {
      return false;
    }
    static_cast<autofill::AutofillDriver*>(driver)
        ->RendererShouldTriggerSuggestions(field_, source);
    return true;
  }

 private:
  friend class content::WebContentsUserData<FocusedField>;

  FocusedField(content::WebContents* web_contents,
               autofill::ContentAutofillClient* client)
      : content::WebContentsUserData<FocusedField>(*web_contents) {
    observation_.Observe(client, autofill::ScopedAutofillManagersObservation::
                                     InitializationPolicy::
                                         kObservePreexistingManagers);
  }

  void OnAfterFocusOnFormField(AutofillManager& manager,
                               FormGlobalId form,
                               FieldGlobalId field) override {
    Focused(manager, field);
  }
  void OnAfterAskForValuesToFill(AutofillManager& manager,
                                 FormGlobalId form,
                                 FieldGlobalId field) override {
    Focused(manager, field);
  }
  void OnAfterFocusOnNonFormField(AutofillManager& manager) override {
    if (manager_.get() == &manager) {
      manager_.reset();
    }
  }

  void Focused(AutofillManager& manager, FieldGlobalId field) {
    manager_ = manager.GetWeakPtr();
    field_ = field;
  }

  base::WeakPtr<AutofillManager> manager_;
  FieldGlobalId field_;
  autofill::ScopedAutofillManagersObservation observation_{this};

  WEB_CONTENTS_USER_DATA_KEY_DECL();
};

WEB_CONTENTS_USER_DATA_KEY_IMPL(FocusedField);

void ReportShown(content::WebContents* contents,
                 base::span<const autofill::Suggestion> suggestions) {
  if (!contents || !FocusedField::FromWebContents(contents)) {
    return;
  }
  NSMutableArray* items = [NSMutableArray array];
  for (const autofill::Suggestion& suggestion : suggestions) {
    if (suggestion.type == autofill::SuggestionType::kSeparator) {
      continue;
    }
    NSMutableArray* labels = [NSMutableArray array];
    for (const auto& row : suggestion.labels) {
      for (const auto& text : row) {
        if (!text.value.empty()) {
          [labels addObject:base::SysUTF16ToNSString(text.value)];
        }
      }
    }
    NSMutableArray* minor = [NSMutableArray array];
    for (const auto& text : suggestion.minor_texts) {
      if (!text.value.empty()) {
        [minor addObject:base::SysUTF16ToNSString(text.value)];
      }
    }
    [items addObject:@{
      @"label" : base::SysUTF16ToNSString(suggestion.main_text.value),
      @"sublabel" : [labels componentsJoinedByString:@" "],
      @"minorText" : [minor componentsJoinedByString:@" "],
      @"type" : base::SysUTF8ToNSString(autofill::SuggestionTypeToString(suggestion.type)),
    }];
  }
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(
                     [](base::WeakPtr<content::WebContents> contents, NSArray* items) {
                       if (!contents) {
                         return;
                       }
                       RayCoreTab* tab = TabBridge::GetOrCreate(contents.get())->tab();
                       id<RayCoreTabDelegate> delegate = tab.delegate;
                       if ([delegate respondsToSelector:@selector
                                     (tab:didShowAutofillSuggestions:)]) {
                         [delegate tab:tab didShowAutofillSuggestions:items];
                       }
                     },
                     contents->GetWeakPtr(), items));
}

}

void TrackAutofillFocus(content::WebContents* contents) {
  autofill::g_ray_autofill_suggestions_shown = &ReportShown;
  auto* client =
      contents ? autofill::ContentAutofillClient::FromWebContents(contents) : nullptr;
  if (client && !FocusedField::FromWebContents(contents)) {
    FocusedField::CreateForWebContents(contents, client);
  }
}

bool ShowAutofillSuggestions(content::WebContents* contents, bool passwords) {
  if (!contents) {
    return false;
  }
  TrackAutofillFocus(contents);
  auto* focused = FocusedField::FromWebContents(contents);
  return focused &&
         focused->Trigger(passwords
                              ? AutofillSuggestionTriggerSource::kManualFallbackPasswords
                              : AutofillSuggestionTriggerSource::kFormControlElementClicked);
}

}
