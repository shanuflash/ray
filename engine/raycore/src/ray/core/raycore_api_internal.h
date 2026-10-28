#ifndef RAY_CORE_RAYCORE_API_INTERNAL_H_
#define RAY_CORE_RAYCORE_API_INTERNAL_H_

#import "ray/core/public/RayCore.h"

#include <string>

#include "base/functional/callback_forward.h"

class Profile;

namespace raycore {

extern id<RayCoreEngineDelegate> __strong g_delegate;
extern RayCoreEngine* __strong g_engine;

NSString* NS(const std::string& s);
NSString* NS(const std::u16string& s);

void WhenProfileGone(Profile* profile, base::OnceClosure done);

}

#endif
