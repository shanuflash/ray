#ifndef RAY_LINUX_AC_LINUX_PASSWORD_FIELD_H_
#define RAY_LINUX_AC_LINUX_PASSWORD_FIELD_H_

#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "ray/linux/ac_linux_secret_text.h"
#include "base/memory/weak_ptr.h"
#include "ui/base/ime/text_input_client.h"
#include "ui/base/metadata/metadata_header_macros.h"
#include "ui/views/view.h"

namespace ray::linux_password {

class PasswordField : public views::View, public ui::TextInputClient {
  METADATA_HEADER(PasswordField, views::View)

 public:
  explicit PasswordField(std::u16string accessible_name);
  PasswordField(const PasswordField&) = delete;
  PasswordField& operator=(const PasswordField&) = delete;
  ~PasswordField() override;

  bool usable() const { return text_.ok() && composition_.ok(); }
  std::unique_ptr<SecretBytes> TakeUtf8();
  void Clear();

  gfx::Size CalculatePreferredSize(const views::SizeBounds& available_size) const override;
  void OnPaint(gfx::Canvas* canvas) override;
  bool OnKeyPressed(const ui::KeyEvent& event) override;
  bool OnMousePressed(const ui::MouseEvent& event) override;
  void OnFocus() override;
  void OnBlur() override;
  void RemovedFromWidget() override;

  base::WeakPtr<ui::TextInputClient> AsWeakPtr() override;
  void SetCompositionText(const ui::CompositionText& composition) override;
  size_t ConfirmCompositionText(bool keep_selection) override;
  void ClearCompositionText() override;
  void InsertText(const std::u16string& text, InsertTextCursorBehavior cursor_behavior) override;
  void InsertChar(const ui::KeyEvent& event) override;
  ui::TextInputType GetTextInputType() const override;
  ui::TextInputMode GetTextInputMode() const override;
  base::i18n::TextDirection GetTextDirection() const override;
  int GetTextInputFlags() const override;
  bool CanComposeInline() const override;
  gfx::Rect GetCaretBounds() const override;
  gfx::Rect GetSelectionBoundingBox() const override;
  bool GetCompositionCharacterBounds(size_t index, gfx::Rect* rect) const override;
  bool HasCompositionText() const override;
  ui::TextInputClient::FocusReason GetFocusReason() const override;
  bool GetTextRange(gfx::Range* range) const override;
  bool GetCompositionTextRange(gfx::Range* range) const override;
  bool GetEditableSelectionRange(gfx::Range* range) const override;
  bool SetEditableSelectionRange(const gfx::Range& range) override;
  bool GetTextFromRange(const gfx::Range& range, std::u16string* text) const override;
  void OnInputMethodChanged() override {}
  bool ChangeTextDirectionAndLayoutAlignment(base::i18n::TextDirection direction) override;
  void ExtendSelectionAndDelete(size_t before, size_t after) override;
  void EnsureCaretNotInRect(const gfx::Rect& rect) override {}
  bool IsTextEditCommandEnabled(ui::TextEditCommand command) const override;
  void SetTextEditCommandForNextKeyEvent(ui::TextEditCommand command) override {}
  ukm::SourceId GetClientSourceForMetrics() const override;
  bool ShouldDoLearning() override;
  bool SetCompositionFromExistingText(const gfx::Range& range,
                                      const std::vector<ui::ImeTextSpan>& ui_ime_text_spans) override;
  void GetActiveTextInputControlLayoutBounds(std::optional<gfx::Rect>* control_bounds,
                                             std::optional<gfx::Rect>* selection_bounds) override;

 private:
  void Changed();
  void Accept(bool inserted);
  void DropComposition();
  void Detach();
  int BulletWidth(size_t count) const;
  int CaretX() const;
  gfx::Rect CaretRect() const;

  SecretText text_;
  SecretText composition_;
  bool overflowed_ = false;
  ui::TextInputClient::FocusReason focus_reason_ = ui::TextInputClient::FOCUS_REASON_NONE;
  base::WeakPtrFactory<PasswordField> weak_factory_{this};
};

}

#endif
