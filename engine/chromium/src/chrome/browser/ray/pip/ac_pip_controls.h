// Copyright 2026 Ray. Apache-2.0.

#ifndef CHROME_BROWSER_RAY_PIP_AC_PIP_CONTROLS_H_
#define CHROME_BROWSER_RAY_PIP_AC_PIP_CONTROLS_H_

#include <optional>
#include <vector>

#include "base/functional/callback.h"
#include "base/memory/raw_ptr.h"
#include "base/timer/timer.h"
#include "chrome/browser/ui/views/overlay/back_to_tab_button.h"
#include "chrome/browser/ui/views/overlay/close_image_button.h"
#include "chrome/browser/ui/views/overlay/overlay_controls_fade_animation.h"
#include "chrome/browser/ui/views/overlay/playback_image_button.h"
#include "services/media_session/public/cpp/media_position.h"
#include "ui/base/metadata/metadata_header_macros.h"
#include "ui/views/view.h"

namespace gfx {
class Canvas;
}

inline constexpr int kRayPipButtonMargin = 12;
inline constexpr int kRayPipButtonSize = 28;

class RayBackToTabButton : public OverlayWindowBackToTabButton {
  METADATA_HEADER(RayBackToTabButton, OverlayWindowBackToTabButton)

 public:
  explicit RayBackToTabButton(PressedCallback callback);
  RayBackToTabButton(const RayBackToTabButton&) = delete;
  RayBackToTabButton& operator=(const RayBackToTabButton&) = delete;
  ~RayBackToTabButton() override;

  void Place(const gfx::Size& window_size);

 protected:
  void OnPaintBackground(gfx::Canvas* canvas) override;
  void PaintButtonContents(gfx::Canvas* canvas) override;
};

class RayCloseButton : public CloseImageButton {
  METADATA_HEADER(RayCloseButton, CloseImageButton)

 public:
  static constexpr int kWidth = 29;

  explicit RayCloseButton(PressedCallback callback);
  RayCloseButton(const RayCloseButton&) = delete;
  RayCloseButton& operator=(const RayCloseButton&) = delete;
  ~RayCloseButton() override;

  void Place(const gfx::Size& window_size);

 protected:
  void OnPaintBackground(gfx::Canvas* canvas) override;
  void PaintButtonContents(gfx::Canvas* canvas) override;
};

class RayPlaybackButton : public PlaybackImageButton {
  METADATA_HEADER(RayPlaybackButton, PlaybackImageButton)

 public:
  explicit RayPlaybackButton(PressedCallback callback);
  RayPlaybackButton(const RayPlaybackButton&) = delete;
  RayPlaybackButton& operator=(const RayPlaybackButton&) = delete;
  ~RayPlaybackButton() override;

 protected:
  void OnPaintBackground(gfx::Canvas* canvas) override;
  void PaintButtonContents(gfx::Canvas* canvas) override;
};

class RayProgressBar : public views::View {
  METADATA_HEADER(RayProgressBar, views::View)

 public:
  static constexpr int kSlopX = 4;
  static constexpr int kSlopY = 6;
  static constexpr float kBarHeight = 5;

  explicit RayProgressBar(base::RepeatingCallback<void(double)> seek);
  RayProgressBar(const RayProgressBar&) = delete;
  RayProgressBar& operator=(const RayProgressBar&) = delete;
  ~RayProgressBar() override;

  void SetMediaPosition(const media_session::MediaPosition& position);

  void Place(const gfx::Size& window_size);

  void OnPaint(gfx::Canvas* canvas) override;
  bool OnMousePressed(const ui::MouseEvent& event) override;
  bool OnMouseDragged(const ui::MouseEvent& event) override;
  void OnMouseReleased(const ui::MouseEvent& event) override;
  void OnMouseCaptureLost() override;
  ui::Cursor GetCursor(const ui::MouseEvent& event) override;

 private:
  double FractionAt(int x) const;
  void RepaintIfDrawn();

  base::RepeatingCallback<void(double)> seek_;
  media_session::MediaPosition position_;
  std::optional<double> drag_fraction_;
  bool dragging_ = false;
  base::RepeatingTimer timer_;
};

class RayControlsFadeAnimation : public OverlayControlsFadeAnimation {
 public:
  RayControlsFadeAnimation(
      const std::vector<raw_ptr<views::View>>& controls,
      Type type);
  RayControlsFadeAnimation(const RayControlsFadeAnimation&) =
      delete;
  RayControlsFadeAnimation& operator=(
      const RayControlsFadeAnimation&) = delete;
  ~RayControlsFadeAnimation() override;

  void AnimateToState(double state) override;
};

#endif
