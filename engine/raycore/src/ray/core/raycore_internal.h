#ifndef RAY_CORE_RAYCORE_INTERNAL_H_
#define RAY_CORE_RAYCORE_INTERNAL_H_

#import "ray/core/public/RayCore.h"

class Profile;

namespace content {
class WebContents;
}

namespace raycore {
class WindowHost;

void NoteProfileDying(Profile* profile);
bool IsProfileDying(const Profile* profile);
void NoteProfileDeleting(Profile* profile);
bool IsProfileDeleting(const Profile* profile);
}

@interface RayCoreProfile ()
+ (RayCoreProfile*)wrapperFor:(Profile*)profile;
@property(readonly) Profile* chromeProfile;
@end

@interface RayCoreTab ()
- (instancetype)initWithContents:(content::WebContents*)contents;
@property(readonly) content::WebContents* contents;
- (void)contentsDestroyed;
- (void)notify:(SEL)selector;
@end

@interface RayCoreWindow ()
@property(readonly) raycore::WindowHost* host;
@end

#endif
