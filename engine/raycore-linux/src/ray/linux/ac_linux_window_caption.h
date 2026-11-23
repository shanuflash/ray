#ifndef RAY_LINUX_AC_LINUX_WINDOW_CAPTION_H_
#define RAY_LINUX_AC_LINUX_WINDOW_CAPTION_H_

namespace views { class Widget; }

namespace ray::linux_window {

bool StartCaptionMove(views::Widget* widget);
bool CaptionDoubleClick(views::Widget* widget);

}

#endif
