#include <cassert>
#include <cmath>
#include <cstdio>
#include <limits>
#include <string>
#include <vector>

#include "ray/linux/ac_linux_crash_dumps_core.h"

namespace crash = ray::linux_crash;

namespace {

std::string Id(int n) {
  char text[37];
  std::snprintf(text, sizeof(text), "%08x-0000-4000-8000-%012x", n, n);
  return text;
}

void ReportIdsAreCanonicalLowercaseUuids() {
  assert(crash::IsReportId("15caed9f-26ef-4058-adbd-763c7b3603ef"));
  assert(!crash::IsReportId("15CAED9F-26EF-4058-ADBD-763C7B3603EF"));
  assert(!crash::IsReportId("15caed9f26ef4058adbd763c7b3603ef"));
  assert(!crash::IsReportId("15caed9f-26ef-4058-adbd-763c7b3603e"));
  assert(!crash::IsReportId("15caed9f-26ef-4058-adbd-763c7b3603eff"));
  assert(!crash::IsReportId("../../../etc/passwd-0000-0000-000000"));
  assert(!crash::IsReportId("15caed9f-26ef-4058-adbd/763c7b3603ef"));
  assert(!crash::IsReportId(""));
}

void ListTakesOneFiniteNonNegativeTime() {
  assert(crash::ListSince(1, 0.0) == 0.0);
  assert(crash::ListSince(1, 1794770653000.0) == 1794770653000.0);
  assert(!crash::ListSince(0, std::nullopt));
  assert(!crash::ListSince(1, std::nullopt));
  assert(!crash::ListSince(2, 1.0));
  assert(!crash::ListSince(1, -1.0));
  assert(!crash::ListSince(1, std::numeric_limits<double>::infinity()));
  assert(!crash::ListSince(1, std::nan("")));
}

void NewestKeepsTheLatestAfterTheCursorInOrderWithoutDuplicates() {
  std::vector<crash::Dump> dumps;
  for (int i = 0; i < 40; ++i) dumps.push_back({Id(i), 1000.0 + (39 - i) * 10});
  dumps.push_back({Id(3), 5000});
  dumps.push_back({"not-a-report", 9000});
  dumps.push_back({Id(99), std::numeric_limits<double>::infinity()});
  const auto kept = crash::Newest(dumps, 1000.0);
  assert(kept.size() == crash::kListMost);
  for (size_t i = 1; i < kept.size(); ++i) assert(kept[i - 1].time <= kept[i].time);
  for (const auto& dump : kept) assert(dump.time > 1000.0 && crash::IsReportId(dump.id));
  assert(kept.back().id == Id(0));
  assert(kept.back().time == 1390.0);
  assert(crash::Newest(dumps, 2000.0).empty());
  const auto two = crash::Newest({{Id(1), 10}, {Id(2), 20}, {Id(3), 30}}, 10);
  assert(two.size() == 2 && two[0].id == Id(2) && two[1].id == Id(3));
}

void OnlyAShortVersionBecomesTheAnnotation() {
  assert(crash::AnnotatedVersion("0.2.47-nightly.3") == "0.2.47-nightly.3");
  assert(crash::AnnotatedVersion("157.0.8103.50") == "157.0.8103.50");
  assert(!crash::AnnotatedVersion(""));
  assert(!crash::AnnotatedVersion("0.2.47 nightly"));
  assert(!crash::AnnotatedVersion("<html>"));
  assert(!crash::AnnotatedVersion(std::string(crash::kVersionMaxBytes + 1, '1')));
}

}

int main() {
  ReportIdsAreCanonicalLowercaseUuids();
  ListTakesOneFiniteNonNegativeTime();
  NewestKeepsTheLatestAfterTheCursorInOrderWithoutDuplicates();
  OnlyAShortVersionBecomesTheAnnotation();
  std::puts("ok");
  return 0;
}
