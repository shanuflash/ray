#ifndef RAY_CORE_AC_AUTOFILL_TRIGGER_H_
#define RAY_CORE_AC_AUTOFILL_TRIGGER_H_

namespace content {
class WebContents;
}

namespace raycore {

void TrackAutofillFocus(content::WebContents* contents);
bool ShowAutofillSuggestions(content::WebContents* contents, bool passwords);

}

#endif
