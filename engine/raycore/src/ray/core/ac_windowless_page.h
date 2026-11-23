// Copyright 2026 Ray. Apache-2.0.

#ifndef RAY_CORE_AC_WINDOWLESS_PAGE_H_
#define RAY_CORE_AC_WINDOWLESS_PAGE_H_

namespace raycore {

void InstallWindowlessPageGeometry();

struct WindowlessPageTotals {
  int given = 0;
  int missed = 0;
};

WindowlessPageTotals WindowlessPagesSoFar();

}

#endif
