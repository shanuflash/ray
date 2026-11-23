import pathlib
import tempfile
import unittest

from support import VALUES, compile_and_run

ROOT = pathlib.Path(__file__).resolve().parents[1]
LINUX = ROOT / 'src/ray/linux'

STUBS = {
    'base/time/time.h': r'''
#pragma once
namespace base {
struct TimeDelta { double seconds = 0; };
inline TimeDelta Seconds(double seconds) { return TimeDelta{seconds}; }
}
''',
    'base/memory/weak_ptr.h': r'''
#pragma once
namespace base {
template <typename T>
class WeakPtr {
 public:
  WeakPtr() = default;
  explicit WeakPtr(T* value) : value_(value) {}
  T* get() const { return value_; }
  T* operator->() const { return value_; }
  explicit operator bool() const { return value_ != nullptr; }
 private:
  T* value_ = nullptr;
};
}
''',
    'content/public/browser/web_contents.h': r'''
#pragma once
namespace content { class WebContents { public: int id = 0; bool discarded = false; bool WasDiscarded() const { return discarded; } }; }
''',
    'components/performance_manager/public/graph/graph.h': r'''
#pragma once
namespace performance_manager {
namespace policies { class DiscardEligibilityPolicy; class PageDiscardingHelper; }
class Graph {
 public:
  policies::DiscardEligibilityPolicy* eligibility = nullptr;
  policies::PageDiscardingHelper* discarding = nullptr;
};
}
''',
    'components/performance_manager/public/graph/page_node.h': r'''
#pragma once
#include "components/performance_manager/public/graph/graph.h"
namespace performance_manager {
class PageNode {
 public:
  Graph* graph = nullptr;
  Graph* GetGraph() const { return graph; }
};
}
''',
    'components/performance_manager/public/performance_manager.h': r'''
#pragma once
#include "base/memory/weak_ptr.h"
#include "components/performance_manager/public/graph/page_node.h"
#include "content/public/browser/web_contents.h"
namespace performance_manager {
class PerformanceManager {
 public:
  static inline bool available = true;
  static inline content::WebContents* contents = nullptr;
  static inline PageNode* page = nullptr;
  static bool IsAvailable() { return available; }
  static base::WeakPtr<PageNode> GetPrimaryPageNodeForWebContents(content::WebContents* value) {
    return base::WeakPtr<PageNode>(value == contents ? page : nullptr);
  }
};
}
''',
    'chrome/browser/performance_manager/policies/cannot_discard_reason.h': r'''
#pragma once
namespace performance_manager::policies {
enum class CannotDiscardReason { kNotATab = 0, kAlreadyDiscarded = 1, kDiscardAttempted = 2, kVisible = 3, kActiveTab = 9, kFormInteractions = 26 };
}
''',
    'chrome/browser/performance_manager/policies/discard_eligibility_policy.h': r'''
#pragma once
#include <vector>
#include "base/time/time.h"
#include "chrome/browser/performance_manager/policies/cannot_discard_reason.h"
#include "components/performance_manager/public/graph/graph.h"
#include "components/performance_manager/public/graph/page_node.h"
namespace performance_manager::policies {
enum class CanDiscardResult { kEligible = 0, kProtected = 1, kDisallowed = 2 };
class DiscardEligibilityPolicy {
 public:
  enum class DiscardReason { EXTERNAL, URGENT, PROACTIVE, SUGGESTED, FROZEN_WITH_GROWING_MEMORY };
  static DiscardEligibilityPolicy* GetFromGraph(Graph* graph) { return graph ? graph->eligibility : nullptr; }
  CanDiscardResult result = CanDiscardResult::kEligible;
  std::vector<CannotDiscardReason> reasons;
  mutable const PageNode* asked_page = nullptr;
  mutable DiscardReason asked_reason = DiscardReason::EXTERNAL;
  mutable double asked_seconds = -1;
  CanDiscardResult CanDiscardWithCustomRecentVisibilityWindow(
      const PageNode* page_node, DiscardReason discard_reason, base::TimeDelta minimum_time_in_background,
      std::vector<CannotDiscardReason>* cannot_discard_reasons = nullptr) const {
    asked_page = page_node;
    asked_reason = discard_reason;
    asked_seconds = minimum_time_in_background.seconds;
    if (cannot_discard_reasons) *cannot_discard_reasons = reasons;
    return result;
  }
};
}
''',
    'chrome/browser/performance_manager/policies/page_discarding_helper.h': r'''
#pragma once
#include <vector>
#include "chrome/browser/performance_manager/policies/discard_eligibility_policy.h"
namespace performance_manager::policies {
class PageDiscardingHelper {
 public:
  static PageDiscardingHelper* GetFromGraph(Graph* graph) { return graph ? graph->discarding : nullptr; }
  bool succeed = true;
  std::vector<std::vector<const PageNode*>> discarded;
  std::vector<DiscardEligibilityPolicy::DiscardReason> reasons;
  bool ImmediatelyDiscardMultiplePages(const std::vector<const PageNode*>& page_nodes,
                                       DiscardEligibilityPolicy::DiscardReason discard_reason,
                                       bool ignore_recent_visibility = true) {
    (void)ignore_recent_visibility;
    discarded.push_back(page_nodes);
    reasons.push_back(discard_reason);
    return succeed;
  }
};
}
''',
}


class TabSleepTests(unittest.TestCase):
    def test_a_hidden_tab_sleeps_only_when_chrome_allows_it(self):
        with tempfile.TemporaryDirectory(prefix='ray-tab-sleep-') as directory:
            include = pathlib.Path(directory) / 'include'
            for path, text in {'base/values.h': VALUES, **STUBS}.items():
                (include / path).parent.mkdir(parents=True, exist_ok=True)
                (include / path).write_text(text)
            output = compile_and_run(self, 'tab-sleep', [
                LINUX / 'ac_linux_tab_sleep.cc', ROOT / 'tests/fixtures/tab_sleep_scenarios.cc',
            ], extra_includes=[include])
        self.assertIn('tab sleep scenarios passed', output)

    def test_the_mac_answers_an_asleep_tab_the_same_way(self):
        mac = (ROOT.parent / 'raycore/src/ray/core/raycore_tab.mm').read_text()
        body = mac[mac.index('- (NSArray<NSNumber*>*)sleepIfHiddenFor:(NSTimeInterval)seconds {'):]
        body = body[:body.index('\n}\n')]
        self.assertLess(body.index('if (_contents->WasDiscarded()) {\n    return @[];'), body.index('GetPrimaryPageNodeForWebContents'))


if __name__ == '__main__':
    unittest.main()
