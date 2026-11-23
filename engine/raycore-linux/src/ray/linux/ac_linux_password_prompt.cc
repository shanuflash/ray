#include "ray/linux/ac_linux_password_prompt.h"

#include <map>
#include <memory>
#include <optional>
#include <string>
#include <utility>

#include "ray/linux/ac_linux_password_check.h"
#include "ray/linux/ac_linux_password_field.h"
#include "ray/linux/ac_linux_secret_text.h"
#include "base/functional/bind.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/no_destructor.h"
#include "base/scoped_observation.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/utf_string_conversions.h"
#include "base/task/sequenced_task_runner.h"
#include "base/task/thread_pool.h"
#include "base/time/time.h"
#include "chrome/browser/ray/ac_reauth_linux.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface_iterator.h"
#include "ui/base/base_window.h"
#include "content/public/browser/browser_thread.h"
#include "ui/base/mojom/dialog_button.mojom.h"
#include "ui/base/mojom/ui_base_types.mojom.h"
#include "ui/views/controls/message_box_view.h"
#include "ui/views/border.h"
#include "ui/views/layout/layout_provider.h"
#include "ui/views/view_class_properties.h"
#include "ui/views/widget/widget.h"
#include "ui/views/widget/widget_observer.h"
#include "ui/views/window/dialog_delegate.h"

namespace ray::linux_password {
namespace {

struct Checker {
  bool probed = false;
  std::optional<std::string> helper;
  std::optional<std::string> user;
};

Checker& TheChecker() {
  static base::NoDestructor<Checker> checker;
  return *checker;
}

Throttle& TheThrottle() {
  static Throttle throttle;
  return throttle;
}

int64_t NowMs() {
  return (base::TimeTicks::Now() - base::TimeTicks()).InMilliseconds();
}

std::string WaitText(int64_t wait_ms) {
  if (wait_ms <= 0) {
    return std::string();
  }
  return " Wait " + base::NumberToString((wait_ms + 999) / 1000) + " seconds, then try again.";
}

class Confirmation;

std::map<Profile*, std::unique_ptr<Confirmation>>& Pending() {
  static base::NoDestructor<std::map<Profile*, std::unique_ptr<Confirmation>>> pending;
  return *pending;
}

void Finish(Profile* profile, bool granted, bool cancelled);

views::Widget* ParentFor(Profile* profile) {
  views::Widget* parent = nullptr;
  ForEachCurrentBrowserWindowInterfaceOrderedByActivation([&](BrowserWindowInterface* browser) {
    if (browser->GetProfile() != profile || !browser->GetWindow()) {
      return true;
    }
    parent = views::Widget::GetWidgetForNativeWindow(browser->GetWindow()->GetNativeWindow());
    return !parent;
  });
  return parent;
}

class Confirmation : public views::WidgetObserver {
 public:
  Confirmation(Profile* profile,
               std::u16string purpose,
               base::OnceCallback<void(bool, bool)> done)
      : profile_(profile), purpose_(std::move(purpose)), done_(std::move(done)) {}

  ~Confirmation() override {
    weak_factory_.InvalidateWeakPtrs();
    Close();
  }

  base::OnceCallback<void(bool, bool)> TakeDone() { return std::move(done_); }

  void Show(const std::string& problem) {
    DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
    views::Widget* parent = ParentFor(profile_);
    if (!parent || parent->IsClosed() || parent->is_destroying()) {
      return Finish(profile_, false, false);
    }
    delegate_ = std::make_unique<views::DialogDelegate>();
    delegate_->SetOwnershipOfNewWidget(views::Widget::InitParams::CLIENT_OWNS_WIDGET);
    delegate_->SetTitle(u"Confirm It's You");
    delegate_->SetModalType(ui::mojom::ModalType::kWindow);
    delegate_->SetButtonLabel(ui::mojom::DialogButton::kOk, u"Confirm");
    delegate_->SetButtonLabel(ui::mojom::DialogButton::kCancel, u"Cancel");
    std::u16string text = u"Ray is trying to ";
    text += purpose_;
    text += u".\n\n";
    text += base::UTF8ToUTF16(problem.empty() ? "Enter the password you use to log in to this computer." : problem);
    auto field = std::make_unique<PasswordField>(u"Login password");
    if (!field->usable()) {
      return Finish(profile_, false, false);
    }
    const views::LayoutProvider* layout = views::LayoutProvider::Get();
    gfx::Insets sides = layout->GetInsetsMetric(views::INSETS_DIALOG);
    sides.set_top_bottom(0, 0);
    gfx::Insets edges =
        layout->GetDialogInsetsForContentType(views::DialogContentType::kText, views::DialogContentType::kControl);
    edges.set_left_right(0, 0);
    field->SetProperty(views::kMarginsKey, sides);
    auto message = std::make_unique<views::MessageBoxView>(text);
    message->SetBorder(views::CreateEmptyBorder(edges));
    field_ = message->AddChildView(std::move(field));
    delegate_->SetInitiallyFocusedView(field_);
    delegate_->SetContentsView(std::move(message));
    widget_.reset(views::DialogDelegate::CreateDialogWidget(
        delegate_.get(), parent->GetNativeWindow(), parent->GetNativeView()));
    observation_.Observe(widget_.get());
    widget_->MakeCloseSynchronous(
        base::BindOnce(&Confirmation::OnClose, weak_factory_.GetWeakPtr()));
    widget_->Show();
  }

  void OnWidgetDestroying(views::Widget* widget) override {
    if (field_) {
      field_->Clear();
    }
    Forced();
  }
  void OnWidgetDestroyed(views::Widget* widget) override { Forced(); }

 private:
  void Close() {
    observation_.Reset();
    if (field_) {
      field_->Clear();
    }
    field_ = nullptr;
    widget_.reset();
    delegate_.reset();
  }

  void Forced() {
    observation_.Reset();
    field_ = nullptr;
    if (!checking_) {
      base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
          FROM_HERE, base::BindOnce(&Finish, profile_.get(), false, true));
    }
  }

  void OnClose(views::Widget::ClosedReason reason) {
    DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
    const bool accepted = reason == views::Widget::ClosedReason::kAcceptButtonClicked;
    std::unique_ptr<SecretBytes> password;
    if (accepted && field_) {
      password = field_->TakeUtf8();
    }
    observation_.Reset();
    Close();
    if (!accepted) {
      return Finish(profile_, false, true);
    }
    if (!password) {
      return Show("That password is too long to check.");
    }
    if (std::optional<std::string> problem = UnusablePassword(password->view())) {
      return Show(*problem);
    }
    if (const int64_t wait = TheThrottle().WaitMs(NowMs()); wait > 0) {
      return Show("Too many wrong passwords." + WaitText(wait));
    }
    const Checker& checker = TheChecker();
    if (!checker.helper || !checker.user) {
      return Finish(profile_, false, false);
    }
    checking_ = true;
    base::ThreadPool::PostTaskAndReplyWithResult(
        FROM_HERE,
        {base::MayBlock(), base::TaskPriority::USER_BLOCKING,
         base::TaskShutdownBehavior::CONTINUE_ON_SHUTDOWN},
        base::BindOnce(
            [](std::string helper, std::string user, std::unique_ptr<SecretBytes> password) {
              return RunHelper(helper, user, password->view());
            },
            *checker.helper, *checker.user, std::move(password)),
        base::BindOnce(&Confirmation::Checked, weak_factory_.GetWeakPtr()));
  }

  void Checked(Verdict verdict) {
    checking_ = false;
    if (verdict == Verdict::kMatch) {
      TheThrottle().NoteRight();
      return Finish(profile_, true, false);
    }
    if (verdict == Verdict::kMismatch) {
      TheThrottle().NoteWrong(NowMs());
      return Show("That isn't your login password." + WaitText(TheThrottle().WaitMs(NowMs())));
    }
    Finish(profile_, false, false);
  }

  raw_ptr<Profile> profile_;
  std::u16string purpose_;
  base::OnceCallback<void(bool, bool)> done_;
  std::unique_ptr<views::DialogDelegate> delegate_;
  std::unique_ptr<views::Widget> widget_;
  raw_ptr<PasswordField> field_ = nullptr;
  bool checking_ = false;
  base::ScopedObservation<views::Widget, views::WidgetObserver> observation_{this};
  base::WeakPtrFactory<Confirmation> weak_factory_{this};
};

void Finish(Profile* profile, bool granted, bool cancelled) {
  auto& pending = Pending();
  const auto found = pending.find(profile);
  if (found == pending.end()) {
    return;
  }
  std::unique_ptr<Confirmation> confirmation = std::move(found->second);
  pending.erase(found);
  base::OnceCallback<void(bool, bool)> done = confirmation->TakeDone();
  base::SequencedTaskRunner::GetCurrentDefault()->DeleteSoon(FROM_HERE, std::move(confirmation));
  if (done) {
    std::move(done).Run(granted, cancelled);
  }
}

void Confirm(Profile* profile,
             const std::u16string& purpose,
             base::OnceCallback<void(bool, bool)> done) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  Finish(profile, false, true);
  auto confirmation = std::make_unique<Confirmation>(profile, purpose, std::move(done));
  Confirmation* shown = confirmation.get();
  Pending()[profile] = std::move(confirmation);
  shown->Show(std::string());
}

bool Available() {
  const Checker& checker = TheChecker();
  return checker.probed && checker.helper && checker.user;
}

}

void InstallReauthFallback() {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  base::ThreadPool::PostTaskAndReplyWithResult(
      FROM_HERE, {base::MayBlock(), base::TaskPriority::USER_VISIBLE},
      base::BindOnce([] {
        Checker found;
        found.probed = true;
        found.helper = FindHelper();
        found.user = CurrentUser();
        return found;
      }),
      base::BindOnce([](Checker found) { TheChecker() = std::move(found); }));
  ray::SetReauthFallback({base::BindRepeating(&Available), base::BindRepeating(&Confirm)});
}

}
