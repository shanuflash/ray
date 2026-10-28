#ifndef RAY_CORE_AC_EXTERNAL_APPS_H_
#define RAY_CORE_AC_EXTERNAL_APPS_H_

#import <Foundation/Foundation.h>

#include <string>

namespace raycore {

void InstallExternalAppPrompts();
void ResolveExternalApp(const std::string& request_id, bool open, bool remember);
NSArray<NSDictionary*>* TestExternalLaunches();
bool TestNoLaunch();
void RecordTestLaunch(NSDictionary* launch);

}

#endif
