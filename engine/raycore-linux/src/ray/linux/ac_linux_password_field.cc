#include "ray/linux/ac_linux_password_field.h"

#include <algorithm>
#include <cstdint>
#include <string_view>
#include <utility>

#include "ray/linux/ac_linux_password_check.h"
#include "base/i18n/rtl.h"
#include "services/metrics/public/cpp/ukm_source_id.h"
#include "ui/accessibility/ax_enums.mojom.h"
#include "ui/base/ime/composition_text.h"
#include "ui/base/ime/input_method.h"
#include "ui/base/ime/text_input_flags.h"
#include "ui/base/ime/text_input_mode.h"
#include "ui/base/ime/text_input_type.h"
#include "ui/base/metadata/metadata_impl_macros.h"
#include "ui/color/color_id.h"
#include "ui/color/color_provider.h"
#include "ui/events/event.h"
#include "ui/events/event_constants.h"
#include "ui/events/keycodes/keyboard_codes.h"
#include "ui/gfx/canvas.h"
#include "ui/gfx/geometry/rect.h"
#include "ui/gfx/range/range.h"
#include "ui/gfx/render_text.h"
#include "ui/gfx/scoped_canvas.h"
#include "ui/gfx/text_utils.h"
#include "ui/views/accessibility/view_accessibility.h"
#include "ui/views/background.h"
#include "ui/views/controls/focus_ring.h"
#include "ui/views/controls/focusable_border.h"
#include "ui/views/controls/highlight_path_generator.h"
#include "ui/views/layout/layout_provider.h"
#include "ui/views/style/typography.h"
#include "ui/views/style/typography_provider.h"

namespace ray::linux_password {
namespace {

constexpr int kPreferredWidth = 240;
constexpr int kCaretWidth = 1;
constexpr int kUnderlineHeight = 1;
constexpr int kTextInputFlags = ui::TEXT_INPUT_FLAG_AUTOCOMPLETE_OFF | ui::TEXT_INPUT_FLAG_AUTOCORRECT_OFF |
                                ui::TEXT_INPUT_FLAG_SPELLCHECK_OFF | ui::TEXT_INPUT_FLAG_AUTOCAPITALIZE_NONE |
                                ui::TEXT_INPUT_FLAG_HAS_BEEN_PASSWORD;

const gfx::FontList& FieldFont() {
  return views::TypographyProvider::Get().GetFont(views::style::CONTEXT_TEXTFIELD, views::style::STYLE_PRIMARY);
}

std::u16string Bullets(size_t count) {
  return std::u16string(count, gfx::RenderText::kPasswordReplacementChar);
}

bool HasCommandModifier(const ui::KeyEvent& event) {
  return event.flags() & (ui::EF_CONTROL_DOWN | ui::EF_ALT_DOWN | ui::EF_COMMAND_DOWN);
}

}

PasswordField::PasswordField(std::u16string accessible_name) : text_(kMaxPasswordBytes), composition_(kMaxPasswordBytes) {
  const views::LayoutProvider* provider = views::LayoutProvider::Get();
  const float radius = provider->GetCornerRadiusMetric(views::ShapeContextTokens::kTextfieldRadius, gfx::Size());
  auto border = std::make_unique<views::FocusableBorder>(ui::kColorTextfieldOutline);
  border->SetInsets(gfx::Insets::VH(provider->GetDistanceMetric(views::DISTANCE_CONTROL_VERTICAL_TEXT_PADDING),
                                    provider->GetDistanceMetric(views::DISTANCE_TEXTFIELD_HORIZONTAL_TEXT_PADDING)));
  border->SetCornerRadius(radius);
  SetBorder(std::move(border));
  SetBackground(views::CreateRoundedRectBackground(ui::kColorTextfieldBackground, radius));
  SetFocusBehavior(FocusBehavior::ALWAYS);
  views::InstallRoundRectHighlightPathGenerator(this, gfx::Insets(), static_cast<int>(radius));
  views::FocusRing::Install(this);
  views::FocusRing::Get(this)->SetOutsetFocusRingDisabled(true);
  views::ViewAccessibility& accessibility = GetViewAccessibility();
  accessibility.SetRole(ax::mojom::Role::kTextField);
  accessibility.SetName(std::move(accessible_name));
  accessibility.SetIsProtected(true);
  accessibility.SetIsEditable(true);
  accessibility.SetIsLeaf(true);
}

PasswordField::~PasswordField() {
  weak_factory_.InvalidateWeakPtrs();
  Detach();
}

std::unique_ptr<SecretBytes> PasswordField::TakeUtf8() {
  std::unique_ptr<SecretBytes> utf8 = !overflowed_ && text_.Insert(composition_.view()) ? text_.Utf8() : nullptr;
  Clear();
  return utf8;
}

void PasswordField::Clear() {
  DropComposition();
  text_.Clear();
  overflowed_ = false;
  Changed();
}

void PasswordField::Accept(bool inserted) {
  overflowed_ = overflowed_ || !inserted;
}

void PasswordField::Changed() {
  SchedulePaint();
  if (text_.empty() && composition_.empty()) {
    overflowed_ = false;
  }
  const size_t caret = text_.CodePointsBeforeCursor() + composition_.CodePoints();
  const size_t total = text_.CodePoints() + composition_.CodePoints();
  const bool selected = text_.all_selected();
  views::ViewAccessibility& accessibility = GetViewAccessibility();
  accessibility.SetValue(Bullets(total));
  accessibility.SetTextSelStart(static_cast<int32_t>(selected ? 0 : caret));
  accessibility.SetTextSelEnd(static_cast<int32_t>(selected ? total : caret));
  if (ui::InputMethod* input = GetInputMethod(); input && input->GetTextInputClient() == this) {
    input->OnCaretBoundsChanged(this);
  }
}

void PasswordField::DropComposition() {
  if (composition_.empty()) {
    return;
  }
  composition_.Clear();
  if (ui::InputMethod* input = GetInputMethod(); input && input->GetTextInputClient() == this) {
    input->CancelComposition(this);
  }
}

void PasswordField::Detach() {
  if (ui::InputMethod* input = GetInputMethod(); input && input->GetTextInputClient() == this) {
    input->DetachTextInputClient(this);
  }
}

int PasswordField::BulletWidth(size_t count) const {
  return count ? gfx::GetStringWidth(Bullets(count), FieldFont()) : 0;
}

int PasswordField::CaretX() const {
  const gfx::Rect bounds = GetContentsBounds();
  const int caret = BulletWidth(text_.CodePointsBeforeCursor() + composition_.CodePoints());
  return bounds.x() + std::min(caret, std::max(0, bounds.width() - kCaretWidth));
}

gfx::Rect PasswordField::CaretRect() const {
  const gfx::Rect bounds = GetContentsBounds();
  return GetMirroredRect(gfx::Rect(CaretX(), bounds.y(), kCaretWidth, bounds.height()));
}

gfx::Size PasswordField::CalculatePreferredSize(const views::SizeBounds& available_size) const {
  return gfx::Size(kPreferredWidth, views::LayoutProvider::GetControlHeightForFont(
                                        views::style::CONTEXT_TEXTFIELD, views::style::STYLE_PRIMARY, FieldFont()));
}

void PasswordField::OnPaint(gfx::Canvas* canvas) {
  View::OnPaint(canvas);
  const ui::ColorProvider* colors = GetColorProvider();
  if (!colors) {
    return;
  }
  const gfx::Rect bounds = GetContentsBounds();
  const size_t before = text_.CodePointsBeforeCursor();
  const size_t composing = composition_.CodePoints();
  const size_t total = text_.CodePoints() + composing;
  const int scroll = std::max(0, BulletWidth(before + composing) - std::max(0, bounds.width() - kCaretWidth));
  const auto x_after = [&](size_t count) { return bounds.x() + BulletWidth(count) - scroll; };
  gfx::ScopedCanvas scoped(canvas);
  canvas->ClipRect(GetMirroredRect(bounds));
  const bool selected = text_.all_selected() && HasFocus();
  if (selected) {
    canvas->FillRect(GetMirroredRect(gfx::Rect(x_after(0), bounds.y(), BulletWidth(total), bounds.height())),
                     colors->GetColor(ui::kColorTextfieldSelectionBackground));
  }
  if (total) {
    const SkColor color = colors->GetColor(selected ? ui::kColorTextfieldSelectionForeground
                                                    : ui::kColorTextfieldForeground);
    canvas->DrawStringRect(Bullets(total), FieldFont(), color,
                           GetMirroredRect(gfx::Rect(x_after(0), bounds.y(), BulletWidth(total), bounds.height())));
  }
  if (composing) {
    const int start = x_after(before);
    canvas->FillRect(GetMirroredRect(gfx::Rect(start, bounds.bottom() - kUnderlineHeight - 1,
                                               x_after(before + composing) - start, kUnderlineHeight)),
                     colors->GetColor(ui::kColorTextfieldForeground));
  }
  if (HasFocus() && !selected) {
    canvas->FillRect(CaretRect(), colors->GetColor(ui::kColorTextfieldForeground));
  }
}

bool PasswordField::OnKeyPressed(const ui::KeyEvent& event) {
  const bool control = event.IsControlDown();
  const bool rtl = base::i18n::IsRTL();
  switch (event.key_code()) {
    case ui::VKEY_BACK:
      control ? text_.BackspaceToStart() : text_.Backspace();
      break;
    case ui::VKEY_DELETE:
      if (event.IsShiftDown()) {
        return true;
      }
      text_.DeleteForward();
      break;
    case ui::VKEY_LEFT:
      rtl ? text_.MoveRight() : text_.MoveLeft();
      break;
    case ui::VKEY_RIGHT:
      rtl ? text_.MoveLeft() : text_.MoveRight();
      break;
    case ui::VKEY_HOME:
      text_.MoveHome();
      break;
    case ui::VKEY_END:
      text_.MoveEnd();
      break;
    case ui::VKEY_A:
      if (!control) {
        return false;
      }
      text_.SelectAll();
      break;
    case ui::VKEY_C:
    case ui::VKEY_V:
    case ui::VKEY_X:
    case ui::VKEY_Y:
    case ui::VKEY_Z:
      return control;
    case ui::VKEY_INSERT:
      return control || event.IsShiftDown();
    default:
      return false;
  }
  Changed();
  return true;
}

bool PasswordField::OnMousePressed(const ui::MouseEvent& event) {
  if (!event.IsOnlyLeftMouseButton()) {
    return true;
  }
  RequestFocus();
  text_.MoveEnd();
  Changed();
  return true;
}

void PasswordField::OnFocus() {
  focus_reason_ = ui::TextInputClient::FOCUS_REASON_OTHER;
  if (ui::InputMethod* input = GetInputMethod()) {
    input->SetFocusedTextInputClient(this);
  }
  View::OnFocus();
  Changed();
}

void PasswordField::OnBlur() {
  if (!composition_.empty()) {
    Accept(text_.Insert(composition_.view()));
    composition_.Clear();
  }
  Detach();
  focus_reason_ = ui::TextInputClient::FOCUS_REASON_NONE;
  View::OnBlur();
  Changed();
}

void PasswordField::RemovedFromWidget() {
  DropComposition();
  Detach();
}

base::WeakPtr<ui::TextInputClient> PasswordField::AsWeakPtr() {
  return weak_factory_.GetWeakPtr();
}

void PasswordField::SetCompositionText(const ui::CompositionText& composition) {
  if (text_.all_selected()) {
    text_.Clear();
  }
  composition_.Clear();
  Accept(composition_.Insert(composition.text));
  Changed();
}

size_t PasswordField::ConfirmCompositionText(bool keep_selection) {
  const bool inserted = text_.Insert(composition_.view());
  Accept(inserted);
  const size_t confirmed = inserted ? composition_.size() : 0;
  composition_.Clear();
  Changed();
  return confirmed;
}

void PasswordField::ClearCompositionText() {
  composition_.Clear();
  Changed();
}

void PasswordField::InsertText(const std::u16string& text, InsertTextCursorBehavior cursor_behavior) {
  composition_.Clear();
  Accept(text_.Insert(text));
  Changed();
}

void PasswordField::InsertChar(const ui::KeyEvent& event) {
  if (HasCommandModifier(event) || GetTextInputType() == ui::TEXT_INPUT_TYPE_NONE) {
    return;
  }
  const char16_t unit = event.GetCharacter();
  Accept(text_.Insert(std::u16string_view(&unit, 1)));
  Changed();
}

ui::TextInputType PasswordField::GetTextInputType() const {
  return GetEnabled() ? ui::TEXT_INPUT_TYPE_PASSWORD : ui::TEXT_INPUT_TYPE_NONE;
}

ui::TextInputMode PasswordField::GetTextInputMode() const {
  return ui::TEXT_INPUT_MODE_DEFAULT;
}

base::i18n::TextDirection PasswordField::GetTextDirection() const {
  return base::i18n::IsRTL() ? base::i18n::RIGHT_TO_LEFT : base::i18n::LEFT_TO_RIGHT;
}

int PasswordField::GetTextInputFlags() const {
  return kTextInputFlags;
}

bool PasswordField::CanComposeInline() const {
  return true;
}

gfx::Rect PasswordField::GetCaretBounds() const {
  gfx::Rect caret = CaretRect();
  ConvertRectToScreen(this, &caret);
  return caret;
}

gfx::Rect PasswordField::GetSelectionBoundingBox() const {
  return gfx::Rect();
}

bool PasswordField::GetCompositionCharacterBounds(size_t index, gfx::Rect* rect) const {
  return false;
}

bool PasswordField::HasCompositionText() const {
  return !composition_.empty();
}

ui::TextInputClient::FocusReason PasswordField::GetFocusReason() const {
  return focus_reason_;
}

bool PasswordField::GetTextRange(gfx::Range* range) const {
  return false;
}

bool PasswordField::GetCompositionTextRange(gfx::Range* range) const {
  return false;
}

bool PasswordField::GetEditableSelectionRange(gfx::Range* range) const {
  return false;
}

bool PasswordField::SetEditableSelectionRange(const gfx::Range& range) {
  return false;
}

bool PasswordField::GetTextFromRange(const gfx::Range& range, std::u16string* text) const {
  return false;
}

bool PasswordField::ChangeTextDirectionAndLayoutAlignment(base::i18n::TextDirection direction) {
  return false;
}

void PasswordField::ExtendSelectionAndDelete(size_t before, size_t after) {
  composition_.Clear();
  text_.DeleteSurrounding(before, after);
  Changed();
}

bool PasswordField::IsTextEditCommandEnabled(ui::TextEditCommand command) const {
  return false;
}

ukm::SourceId PasswordField::GetClientSourceForMetrics() const {
  return ukm::kInvalidSourceId;
}

bool PasswordField::ShouldDoLearning() {
  return false;
}

bool PasswordField::SetCompositionFromExistingText(const gfx::Range& range,
                                                   const std::vector<ui::ImeTextSpan>& ui_ime_text_spans) {
  return false;
}

void PasswordField::GetActiveTextInputControlLayoutBounds(std::optional<gfx::Rect>* control_bounds,
                                                          std::optional<gfx::Rect>* selection_bounds) {
  *control_bounds = GetBoundsInScreen();
}

BEGIN_METADATA(PasswordField)
END_METADATA

}
