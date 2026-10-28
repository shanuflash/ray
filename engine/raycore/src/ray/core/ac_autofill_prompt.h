#ifndef RAY_CORE_AC_AUTOFILL_PROMPT_H_
#define RAY_CORE_AC_AUTOFILL_PROMPT_H_

#import <Foundation/Foundation.h>

#include <memory>

namespace autofill {
class AutofillBubbleBase;
class SaveAddressBubbleController;
class SaveCardBubbleController;
class UpdateAddressBubbleController;
}

namespace content {
class WebContents;
}

namespace raycore {

autofill::AutofillBubbleBase* ShowSaveAddressPrompt(
    content::WebContents* contents,
    std::unique_ptr<autofill::SaveAddressBubbleController> controller);
autofill::AutofillBubbleBase* ShowUpdateAddressPrompt(
    content::WebContents* contents,
    std::unique_ptr<autofill::UpdateAddressBubbleController> controller);
autofill::AutofillBubbleBase* ShowSaveCardPrompt(
    content::WebContents* contents,
    autofill::SaveCardBubbleController* controller);
autofill::AutofillBubbleBase* SkipIbanBubble(content::WebContents* contents);
autofill::AutofillBubbleBase* SkipOfferNotification(content::WebContents* contents);
autofill::AutofillBubbleBase* SkipAddressSignInPromo(content::WebContents* contents);

NSDictionary<NSString*, id>* AutofillPrompt(content::WebContents* contents);

void ResolveAutofillPrompt(content::WebContents* contents,
                           NSInteger prompt_id,
                           NSString* action);

}

#endif
