#include <cassert>
#include <cstdio>

#include "ray/linux/ac_linux_app_activation.h"
#include "ray/linux/ac_linux_window_lifecycle.h"

using ray::linux_window::AppActivation;
using ray::linux_window::FocusLedger;

namespace {

void LosingTheLastActiveWindowResignsAfterTheSettle() {
  AppActivation app;
  assert(!app.WindowsChanged(true));
  assert(app.active());
  const auto settle = app.WindowsChanged(false);
  assert(settle && app.settling() && app.active());
  assert(app.Settled(*settle, false, true));
  assert(!app.active() && !app.settling());
  assert(!app.Settled(*settle, false, true));
}

void ASwitchBetweenRayWindowsNeverResigns() {
  AppActivation app;
  app.WindowsChanged(true);
  const auto leaving = app.WindowsChanged(false);
  assert(leaving);
  assert(!app.WindowsChanged(true));
  assert(!app.settling());
  assert(!app.Settled(*leaving, true, true));
  assert(app.active());
  const auto again = app.WindowsChanged(false);
  assert(again && *again != *leaving);
  assert(!app.Settled(*again, true, true));
  assert(app.active());
}

void OnlyTheNewestSettleCounts() {
  AppActivation app;
  app.WindowsChanged(true);
  const auto first = app.WindowsChanged(false);
  const auto second = app.WindowsChanged(false);
  assert(first && second && *first != *second);
  assert(!app.Settled(*first, false, true));
  assert(app.active() && app.settling());
  assert(app.Settled(*second, false, true));
}

void AnAppThatWasNeverActiveHasNothingToResign() {
  AppActivation app;
  assert(!app.WindowsChanged(false));
  assert(!app.settling() && !app.active());
}

void AnOpenDialogKeepsTheShellQuietButTheAppStillCountsAsInactive() {
  AppActivation app;
  app.WindowsChanged(true);
  const auto settle = app.WindowsChanged(false);
  assert(!app.Settled(*settle, false, false));
  assert(!app.active());
  assert(!app.WindowsChanged(false));
  assert(!app.WindowsChanged(true));
  assert(app.active());
}

void TheLedgerSaysWhetherAnyWindowIsActive() {
  FocusLedger ledger(true);
  AppActivation app;
  ledger.Observe(1, true);
  assert(!app.WindowsChanged(ledger.active() != 0));
  ledger.Observe(1, false);
  const auto leaving = app.WindowsChanged(ledger.active() != 0);
  assert(leaving);
  ledger.Observe(2, true);
  assert(!app.WindowsChanged(ledger.active() != 0));
  ledger.Forget(2);
  const auto closed = app.WindowsChanged(ledger.active() != 0);
  assert(closed);
  assert(app.Settled(*closed, ledger.active() != 0, true));
  assert(ledger.Observe(1, true));
  assert(!app.WindowsChanged(ledger.active() != 0));
  assert(app.active());
}

}

int main() {
  LosingTheLastActiveWindowResignsAfterTheSettle();
  ASwitchBetweenRayWindowsNeverResigns();
  OnlyTheNewestSettleCounts();
  AnAppThatWasNeverActiveHasNothingToResign();
  AnOpenDialogKeepsTheShellQuietButTheAppStillCountsAsInactive();
  TheLedgerSaysWhetherAnyWindowIsActive();
  std::puts("ok");
  return 0;
}
