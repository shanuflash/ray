#ifndef RAY_CORE_AC_FAKE_MEDIA_H_
#define RAY_CORE_AC_FAKE_MEDIA_H_

namespace content {
struct MediaStreamRequest;
}

namespace raycore {

bool UsingFakeMediaDevices();

void InstallFakeMediaDevices();

void KeepAudioCaptureFake(content::MediaStreamRequest& request);

}

#endif
