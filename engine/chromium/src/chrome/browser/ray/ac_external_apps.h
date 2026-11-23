// Copyright 2026 Ray. Apache-2.0.

#ifndef CHROME_BROWSER_RAY_AC_EXTERNAL_APPS_H_
#define CHROME_BROWSER_RAY_AC_EXTERNAL_APPS_H_

#import <Foundation/Foundation.h>

namespace ray {

struct ExternalApp {
  NSString* name;
  NSString* icon;
};

ExternalApp DescribeExternalApp(NSURL* app);

}

#endif
