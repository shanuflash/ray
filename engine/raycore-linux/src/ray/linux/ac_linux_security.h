#ifndef RAY_LINUX_AC_LINUX_SECURITY_H_
#define RAY_LINUX_AC_LINUX_SECURITY_H_

#include "ray/linux/ac_linux_page_lease.h"

namespace raycore {

class LinuxSecurity : public content::WebContentsObserver {
 public:
  explicit LinuxSecurity(base::WeakPtr<LinuxPageLease> lease);
  ~LinuxSecurity() override;
  base::DictValue Snapshot() const;
  bool Emit();
  void Reset();

 private:
  void DidChangeVisibleSecurityState() override;
  void WebContentsDestroyed() override;
  base::WeakPtr<LinuxPageLease> lease_;
};

}

#endif
