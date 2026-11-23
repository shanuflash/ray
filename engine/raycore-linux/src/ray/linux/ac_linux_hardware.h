#ifndef RAY_LINUX_AC_LINUX_HARDWARE_H_
#define RAY_LINUX_AC_LINUX_HARDWARE_H_

#include <stddef.h>
#include <stdint.h>

#include <algorithm>
#include <cmath>
#include <string>
#include <string_view>
#include <utility>

#include "base/values.h"

namespace ray::linux_hardware {

inline constexpr char kHardwareInfoCall[] = "RayApp.hardwareInfo";
inline constexpr char kThinScrollBarsCall[] = "RaySystem.setThinScrollBars";
inline constexpr const char* kHardwareCapabilities[] = {"RayApp.hardwareInfo", "RaySystem.setThinScrollBars",
                                                         "RayShell.setAppearance"};
inline constexpr size_t kNameMax = 256;
inline constexpr double kScaleMax = 16;

inline constexpr int kH264First = 0;
inline constexpr int kH264Last = 10;
inline constexpr int kVp9First = 12;
inline constexpr int kVp9Last = 15;
inline constexpr int kHevcFirst = 16;
inline constexpr int kHevcLast = 18;
inline constexpr int kAv1First = 24;
inline constexpr int kAv1Last = 26;
inline constexpr int kHevcExtendedFirst = 29;
inline constexpr int kHevcExtendedLast = 36;

struct Decode {
  bool av1 = false;
  bool vp9 = false;
  bool hevc = false;
  bool h264 = false;
};

inline void NoteDecodeProfile(Decode& decode, int profile) {
  if (profile >= kH264First && profile <= kH264Last) decode.h264 = true;
  else if (profile >= kVp9First && profile <= kVp9Last) decode.vp9 = true;
  else if ((profile >= kHevcFirst && profile <= kHevcLast) ||
           (profile >= kHevcExtendedFirst && profile <= kHevcExtendedLast)) decode.hevc = true;
  else if (profile >= kAv1First && profile <= kAv1Last) decode.av1 = true;
}

inline std::string Name(std::string_view raw) {
  std::string name;
  bool gap = false;
  for (const char c : raw) {
    const unsigned char byte = static_cast<unsigned char>(c);
    if (byte <= 0x20 || byte == 0x7f) {
      gap = !name.empty();
      continue;
    }
    if (gap) name.push_back(' ');
    gap = false;
    name.push_back(c);
    if (name.size() >= kNameMax) break;
  }
  while (!name.empty() && (static_cast<unsigned char>(name.back()) & 0xc0) == 0x80) name.pop_back();
  if (!name.empty() && static_cast<unsigned char>(name.back()) >= 0xc0) name.pop_back();
  return name;
}

inline std::string GpuName(std::string_view device, std::string_view renderer) {
  std::string name = Name(device);
  return name.empty() ? Name(renderer) : name;
}

inline int MemoryGB(uint64_t bytes) {
  const double gigabytes = std::round(static_cast<double>(bytes) / 1073741824.0);
  return gigabytes > 1e6 ? 1000000 : static_cast<int>(gigabytes);
}

struct Hardware {
  std::string chip;
  std::string gpu;
  uint64_t memory_bytes = 0;
  int displays = 0;
  double max_scale = 0;
  Decode decode;
};

inline base::DictValue Reply(const Hardware& hardware) {
  base::DictValue reply;
  reply.Set("chip", Name(hardware.chip));
  if (std::string gpu = Name(hardware.gpu); !gpu.empty()) reply.Set("gpu", std::move(gpu));
  reply.Set("memoryGB", MemoryGB(hardware.memory_bytes));
  reply.Set("displays", std::max(hardware.displays, 0));
  reply.Set("maxScale", std::isfinite(hardware.max_scale) ? std::clamp(hardware.max_scale, 0.0, kScaleMax) : 0.0);
  reply.Set("hardwareDecode", base::DictValue()
      .Set("av1", hardware.decode.av1).Set("vp9", hardware.decode.vp9)
      .Set("hevc", hardware.decode.hevc).Set("h264", hardware.decode.h264));
  return reply;
}

}

#endif
