#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <algorithm>
#include <cstring>
#include <limits>
#include <string>
#include <utility>

#include "ray/linux/ac_linux_link_gesture.h"
#include "ray/linux/ac_linux_link_tabs.h"
#include "ray/linux/ac_linux_page_commits.h"
#include "ray/linux/ac_linux_page_evaluation.h"
#include "ray/linux/ac_linux_page_messages.h"
#include "ray/linux/ac_linux_status_geometry.h"

using namespace raycore;

namespace {

void Expect(bool condition, const char* what) {
  if (!condition) {
    std::fprintf(stderr, "failed: %s\n", what);
    std::abort();
  }
}

base::Value Dict(base::DictValue dict) { return base::Value(std::move(dict)); }

void Kinds() {
  Expect(LinuxPageMessageKindOf("peek") == LinuxPageMessageKind::kPeek, "peek kind");
  Expect(LinuxPageMessageKindOf("scroll") == LinuxPageMessageKind::kScroll, "scroll kind");
  Expect(LinuxPageMessageKindOf("linkDrop") == LinuxPageMessageKind::kLinkDrop, "link drop kind");
  Expect(LinuxPageMessageKindOf("nowPlaying") == LinuxPageMessageKind::kNowPlaying, "now playing kind");
  for (const char* refused : {"notification", "notificationClose", "displayMedia", "NowPlaying", "pipTrace", "result", "LinkDrop", "evaluate", "config", "", "Peek"})
    Expect(!LinuxPageMessageKindOf(refused), refused);
  Expect(LinuxPageMessageEnvelopeFits("scroll", std::string(64 * 1024, 'x')), "64 KiB fits");
  Expect(!LinuxPageMessageEnvelopeFits("scroll", std::string(64 * 1024 + 1, 'x')), "oversized json refused");
  Expect(!LinuxPageMessageEnvelopeFits(std::string(33, 'k'), "{}"), "long kind refused");
  Expect(!LinuxPageMessageEnvelopeFits(std::string("sc\0ll", 5), "{}"), "nul kind refused");
  Expect(!LinuxPageMessageEnvelopeFits("", "{}"), "empty kind refused");
}

void Senders() {
  const LinuxPageSender main{true, true, true};
  const LinuxPageSender child{false, true, true};
  const LinuxPageSender cached{true, true, false};
  const LinuxPageSender prerender{true, false, true};
  for (auto kind : {LinuxPageMessageKind::kScroll, LinuxPageMessageKind::kSelection, LinuxPageMessageKind::kTheme, LinuxPageMessageKind::kLinkDrop}) {
    Expect(LinuxPageSenderAccepted(kind, main), "main frame owns tab-level messages");
    Expect(!LinuxPageSenderAccepted(kind, child), "an iframe cannot drive scroll, selection or tint");
  }
  Expect(LinuxPageSenderAccepted(LinuxPageMessageKind::kPeek, child), "iframes may request peek");
  Expect(LinuxPageSenderAccepted(LinuxPageMessageKind::kNowPlaying, main), "the main frame reports its video");
  Expect(LinuxPageSenderAccepted(LinuxPageMessageKind::kNowPlaying, child), "an iframe reports its own video");
  Expect(!LinuxPageSenderAccepted(LinuxPageMessageKind::kNowPlaying, cached), "a back-forward cached document reports nothing");
  Expect(!LinuxPageSenderAccepted(LinuxPageMessageKind::kNowPlaying, prerender), "a prerendered document reports nothing");
  Expect(!LinuxPageSenderAccepted(LinuxPageMessageKind::kPeek, cached), "back-forward cached documents are silent");
  Expect(!LinuxPageSenderAccepted(LinuxPageMessageKind::kScroll, prerender), "prerendered documents are silent");
}

void Normalization() {
  auto scroll = NormalizeLinuxPageMessage(LinuxPageMessageKind::kScroll, Dict(base::DictValue().Set("state", "down").Set("extra", "x")));
  Expect(scroll && *scroll->data.GetDict().FindString("state") == "down" && scroll->data.GetDict().size() == 1, "scroll keeps only state");
  Expect(!NormalizeLinuxPageMessage(LinuxPageMessageKind::kScroll, Dict(base::DictValue().Set("state", "sideways"))), "unknown scroll state");
  Expect(!NormalizeLinuxPageMessage(LinuxPageMessageKind::kScroll, base::Value()), "scroll needs a dictionary");

  auto video = NormalizeLinuxPageMessage(LinuxPageMessageKind::kNowPlaying, Dict(base::DictValue().Set("frame", "f")
      .Set("title", "Clip").Set("playbackState", "playing").Set("hasVideo", true).Set("controllable", false)
      .Set("actions", base::ListValue().Append("play"))));
  Expect(video && video->data.GetDict().FindBool("hasVideo") == true && video->data.GetDict().FindBool("playing") == true &&
         video->data.GetDict().size() == 2, "now playing keeps only whether a video is there and plays");
  auto paused_video = NormalizeLinuxPageMessage(LinuxPageMessageKind::kNowPlaying, Dict(base::DictValue()
      .Set("playbackState", "paused").Set("hasVideo", true)));
  Expect(paused_video && paused_video->data.GetDict().FindBool("playing") == false, "a paused video is not playing");
  auto audio = NormalizeLinuxPageMessage(LinuxPageMessageKind::kNowPlaying, Dict(base::DictValue()
      .Set("playbackState", "playing").Set("hasVideo", 1)));
  Expect(audio && audio->data.GetDict().FindBool("hasVideo") == false, "only a boolean true is a video");
  auto gone = NormalizeLinuxPageMessage(LinuxPageMessageKind::kNowPlaying, base::Value());
  Expect(gone && gone->data.is_none(), "null now playing clears the document's video");
  Expect(!NormalizeLinuxPageMessage(LinuxPageMessageKind::kNowPlaying, base::Value("playing")), "now playing needs a dictionary or null");

  auto clear = NormalizeLinuxPageMessage(LinuxPageMessageKind::kSelection, base::Value());
  Expect(clear && clear->data.is_none(), "null selection clears");
  auto selection = NormalizeLinuxPageMessage(LinuxPageMessageKind::kSelection, Dict(base::DictValue().Set("text", "hello")
      .Set("rect", base::DictValue().Set("x", 1.5).Set("y", 2).Set("width", 30).Set("height", 12)).Set("frame", "secret")));
  Expect(selection && *selection->data.GetDict().FindString("text") == "hello" && !selection->data.GetDict().Find("frame"), "selection copied");
  auto infinite = NormalizeLinuxPageMessage(LinuxPageMessageKind::kSelection, Dict(base::DictValue().Set("text", "x")
      .Set("rect", base::DictValue().Set("x", std::numeric_limits<double>::infinity()).Set("y", 0).Set("width", 1).Set("height", 1))));
  Expect(infinite && infinite->data.is_none(), "non-finite rectangle clears");
  auto long_text = NormalizeLinuxPageMessage(LinuxPageMessageKind::kSelection, Dict(base::DictValue().Set("text", std::string(4001, 'a'))
      .Set("rect", base::DictValue().Set("x", 0).Set("y", 0).Set("width", 1).Set("height", 1))));
  Expect(long_text && long_text->data.is_none(), "oversized selection clears");
  auto selection_of = [](std::string text) {
    return NormalizeLinuxPageMessage(LinuxPageMessageKind::kSelection, Dict(base::DictValue().Set("text", std::move(text))
        .Set("rect", base::DictValue().Set("x", 0).Set("y", 0).Set("width", 1).Set("height", 1))));
  };
  std::string cjk;
  for (int i = 0; i < 2000; ++i) cjk += "\xe6\x96\x87";
  Expect(!selection_of(cjk)->data.is_none(), "2000 CJK characters are 2000 UTF-16 units");
  std::string cjk_limit;
  for (int i = 0; i < 4000; ++i) cjk_limit += "\xe6\x96\x87";
  Expect(!selection_of(cjk_limit)->data.is_none(), "4000 CJK characters fit");
  Expect(selection_of(cjk_limit + "\xe6\x96\x87")->data.is_none(), "4001 CJK characters clear");
  std::string emoji;
  for (int i = 0; i < 2000; ++i) emoji += "\xf0\x9f\x98\x80";
  Expect(!selection_of(emoji)->data.is_none(), "2000 astral characters are 4000 UTF-16 units");
  Expect(selection_of(emoji + "a")->data.is_none(), "4001 UTF-16 units clear");

  auto theme = NormalizeLinuxPageMessage(LinuxPageMessageKind::kTheme, Dict(base::DictValue().Set("color", "#A1B2C3").Set("source", "header")));
  Expect(theme && *theme->data.GetDict().FindString("color") == "#a1b2c3", "theme lowercased");
  for (const char* color : {"red", "#abc", "#12345g", "#1234567", "url(javascript:1)", "#ABCDEF\"}"}) {
    auto refused = NormalizeLinuxPageMessage(LinuxPageMessageKind::kTheme, Dict(base::DictValue().Set("color", color).Set("source", "header")));
    Expect(refused && refused->data.is_none(), color);
  }
  auto source = NormalizeLinuxPageMessage(LinuxPageMessageKind::kTheme, Dict(base::DictValue().Set("color", "#000000").Set("source", "shell")));
  Expect(source && source->data.is_none(), "unknown theme source clears");

  auto peek = NormalizeLinuxPageMessage(LinuxPageMessageKind::kPeek, Dict(base::DictValue().Set("url", "HTTPS://Example.test/a").Set("key", "shift")
      .Set("origin", "HTTPS://Example.test").Set("x", 10).Set("y", 20).Set("moved", 1)));
  Expect(peek && *peek->data.GetDict().FindString("origin") == "https://example.test" && peek->data.GetDict().FindDouble("x"), "peek copied");
  for (const char* url : {"javascript:alert(1)", "data:text/html,x", "file:///etc/passwd", "chrome://ray/", "ray://settings", "http://", "https:/x"}) {
    Expect(!NormalizeLinuxPageMessage(LinuxPageMessageKind::kPeek, Dict(base::DictValue().Set("url", url).Set("key", "shift"))), url);
  }
  Expect(!NormalizeLinuxPageMessage(LinuxPageMessageKind::kPeek, Dict(base::DictValue().Set("url", "https://a.test/").Set("key", "ctrl"))), "unknown peek key");
  Expect(!NormalizeLinuxPageMessage(LinuxPageMessageKind::kPeek, Dict(base::DictValue().Set("url", "https://a.test/" + std::string(8192, 'a')).Set("key", "alt"))), "long url");

  base::Value deep = base::Value(base::DictValue());
  for (int i = 0; i < 6; ++i) deep = Dict(base::DictValue().Set("state", std::move(deep)));
  Expect(!NormalizeLinuxPageMessage(LinuxPageMessageKind::kScroll, deep), "deep payload refused");
  auto hello = NormalizeLinuxPageMessage(LinuxPageMessageKind::kHello, Dict(base::DictValue().Set("url", "https://evil.test/").Set("top", true)));
  Expect(hello && hello->data.GetDict().empty(), "hello carries nothing forward");
}

void Budget() {
  LinuxPageMessageBudget budget;
  int admitted = 0;
  for (int i = 0; i < 100; ++i) admitted += budget.Admit(10.0, 16);
  Expect(admitted == 64, "burst capped at 64 messages");
  Expect(!budget.muted(), "a single burst does not mute");
  Expect(budget.Admit(10.5, 16), "tokens refill over time");
  LinuxPageMessageBudget bytes;
  Expect(!bytes.Admit(0, 600 * 1024), "a message larger than the byte bucket is refused");
  Expect(bytes.Admit(0, 64 * 1024), "a full message fits");
  LinuxPageMessageBudget flood;
  for (int i = 0; i < 2000; ++i) flood.Admit(1.0, 16);
  Expect(flood.muted(), "a sustained flood mutes the document");
  Expect(!flood.Admit(100.0, 16), "muted stays muted");
  flood.Reset();
  Expect(!flood.muted() && flood.Admit(100.0, 16), "a new document starts with a fresh budget");
  LinuxPageMessageBudget backwards;
  Expect(backwards.Admit(5, 1), "first");
  for (int i = 0; i < 63; ++i) backwards.Admit(5, 1);
  Expect(!backwards.Admit(1, 1), "a clock going backwards does not refill");
}

void Options() {
  LinuxPageOptions options;
  Expect(options.peek == "shift" && options.EffectiveSplit() == "altShift", "defaults match macOS");
  Expect(options.ActionFor("shift") == std::optional<std::string>("peek"), "shift peeks");
  Expect(options.ActionFor("altShift") == std::optional<std::string>("split"), "alt-shift splits");
  Expect(!options.ActionFor("alt"), "alt does nothing by default");
  Expect(options.SetSplit("alt") && options.EffectiveSplit() == "alt" && options.ActionFor("alt") == std::optional<std::string>("split"), "alt split");
  Expect(options.SetPeek("alt") && options.EffectiveSplit() == "altShift", "alt peek takes alt back from split");
  Expect(options.SetPeek("bogus") && options.peek == "off" && !options.ActionFor("shift"), "unknown peek modifier turns peek off");
  Expect(!options.SetPeek("off"), "unchanged");
  auto main = options.PageConfig(true);
  auto child = options.PageConfig(false);
  Expect(main.FindBool("selectionPopover") && !child.Find("selectionPopover"), "selection popover only for the main frame");
  Expect(!main.Find("blockAutoplay") && !child.Find("blockAutoplay"), "autoplay allowed by default");
  Expect(options.PageConfig(true, true).FindBool("blockAutoplay") == true, "blocked autoplay reaches the main frame");
  Expect(options.PageConfig(false, true).FindBool("blockAutoplay") == true, "blocked autoplay reaches subframes");
  Expect(LinuxAutoplayDecision(true, false, false) && LinuxAutoplayDecision(true, true, true), "a site that blocks autoplay always blocks");
  Expect(!LinuxAutoplayDecision(false, true, false), "a default site plays when blocking everywhere is off");
  Expect(LinuxAutoplayDecision(false, true, true), "blocking everywhere covers a site left at the default");
  Expect(!LinuxAutoplayDecision(false, false, true), "a site allowed by hand keeps playing when blocking everywhere is on");
  Expect(LinuxAutoplayCoversScheme("http") && LinuxAutoplayCoversScheme("https"), "autoplay rules cover web pages");
  Expect(LinuxAutoplayCoversScheme("file"), "autoplay rules cover local files");
  Expect(!LinuxAutoplayCoversScheme("chrome") && !LinuxAutoplayCoversScheme("chrome-extension") &&
             !LinuxAutoplayCoversScheme("data") && !LinuxAutoplayCoversScheme(""),
         "the shell, extension pages and other schemes keep Chromium's own autoplay policy");
  Expect(std::find(std::begin(kLinuxPageMessageRoutes), std::end(kLinuxPageMessageRoutes),
                   std::string_view("webView.setBlockAutoplayEverywhere")) != std::end(kLinuxPageMessageRoutes),
         "the host routes and advertises block autoplay everywhere");
  Expect(!options.PageConfig(true, true).Find("displayMediaPicker"), "Chromium's own capture picker stays");
}

LinuxLinkRequest Request(uintptr_t surface, const char* key, double now) {
  LinuxLinkRequest request;
  request.surface = surface;
  request.key = key;
  request.http = true;
  request.visible = true;
  request.now = now;
  return request;
}

void Gestures() {
  LinuxPageOptions options;
  LinuxLinkGestureGate gate;
  Expect(gate.Decide(Request(1, "shift", 0), options).refused == "no left mouse-up yet", "a page cannot peek without real input");
  gate.NoteRelease(1, kLinuxLinkShift, 1.0, LinuxLinkPoint{40, 50});
  auto peek = gate.Decide(Request(1, "shift", 1.2), options);
  Expect(peek.outcome == LinuxLinkOutcome::kPeek && peek.point && peek.point->x == 40, "real shift mouse-up peeks");
  auto again = gate.Decide(Request(1, "shift", 1.3), options);
  Expect(again.outcome == LinuxLinkOutcome::kNone && again.refused == "that mouse-up already opened a peek", "one peek per mouse-up");

  gate.NoteRelease(2, kLinuxLinkShift, 2.0, std::nullopt);
  auto other = gate.Decide(Request(1, "shift", 2.1), options);
  Expect(other.outcome == LinuxLinkOutcome::kNone && other.refused == "the mouse-up wasn't over this page", "background tab cannot use another tab's click");
  Expect(gate.Decide(Request(2, "shift", 2.2), options).outcome == LinuxLinkOutcome::kPeek, "the clicked tab can still peek");

  gate.NoteRelease(1, kLinuxLinkAlt | kLinuxLinkShift, 3.0, std::nullopt);
  Expect(gate.Decide(Request(1, "altShift", 3.1), options).outcome == LinuxLinkOutcome::kSplit, "alt-shift splits");

  gate.NoteRelease(1, 0, 4.0, std::nullopt);
  auto forged = gate.Decide(Request(1, "shift", 4.1), options);
  Expect(forged.outcome == LinuxLinkOutcome::kNone, "a plain click cannot be upgraded to a peek by the page");

  gate.NoteRelease(1, kLinuxLinkShift, 5.0, std::nullopt);
  gate.NotePress(1);
  Expect(gate.Decide(Request(1, "shift", 5.1), options).refused == "the mouse was pressed again since that mouse-up", "pressed since");

  gate.NoteRelease(1, kLinuxLinkShift, 6.0, std::nullopt);
  auto stale = gate.Decide(Request(1, "shift", 17.0), options);
  Expect(stale.refused == "the last mouse-up is too old" && stale.outcome == LinuxLinkOutcome::kWindow, "old shift-click falls back to a new window");

  gate.NoteRelease(1, kLinuxLinkShift, 20.0, std::nullopt);
  auto hidden = Request(1, "shift", 20.1);
  hidden.visible = false;
  Expect(gate.Decide(hidden, options).outcome == LinuxLinkOutcome::kWindow, "hidden page falls back like the click would");

  options.SetPeek("off");
  options.SetSplit("alt");
  gate.NoteRelease(1, kLinuxLinkAlt, 30.0, std::nullopt);
  Expect(gate.Decide(Request(1, "alt", 30.1), options).outcome == LinuxLinkOutcome::kSplit, "alt split when peek is off");
  options.SetSplit("altShift");
  gate.NoteRelease(1, kLinuxLinkAlt, 31.0, std::nullopt);
  auto same = Request(1, "alt", 31.1);
  same.same_origin = true;
  Expect(gate.Decide(same, options).outcome == LinuxLinkOutcome::kDownload, "same-origin alt-click downloads");
  gate.NoteRelease(1, kLinuxLinkAlt, 32.0, std::nullopt);
  Expect(gate.Decide(Request(1, "alt", 32.1), options).outcome == LinuxLinkOutcome::kBackground, "cross-origin alt-click opens in background");

  gate.NoteRelease(1, kLinuxLinkShift, 40.0, std::nullopt);
  gate.Forget(1);
  Expect(gate.Decide(Request(1, "shift", 40.1), LinuxPageOptions()).refused == "the mouse-up wasn't over this page", "destroyed surface forgets its release");
  gate.NoteRelease(3, kLinuxLinkShift, 41.0, std::nullopt);
  Expect(gate.Decide(Request(0, "shift", 41.1), LinuxPageOptions()).outcome == LinuxLinkOutcome::kNone, "unknown surface never matches");
}

void LinkDrops() {
  auto drop = NormalizeLinuxPageMessage(LinuxPageMessageKind::kLinkDrop, Dict(base::DictValue().Set("url", "https://ray.test/a").Set("x", 1)));
  Expect(drop && *drop->data.GetDict().FindString("url") == "https://ray.test/a" && drop->data.GetDict().size() == 1, "link drop rebuilt from its url");
  for (const char* url : {"javascript:alert(1)", "file:///etc/passwd", "chrome://ray/", "data:text/html,x", ""})
    Expect(!NormalizeLinuxPageMessage(LinuxPageMessageKind::kLinkDrop, Dict(base::DictValue().Set("url", url))), url);
  Expect(!NormalizeLinuxPageMessage(LinuxPageMessageKind::kLinkDrop, Dict(base::DictValue().Set("url", "https://a.test/" + std::string(8192, 'a')))), "oversized link drop");
  Expect(!NormalizeLinuxPageMessage(LinuxPageMessageKind::kLinkDrop, base::Value("https://ray.test/")), "link drop needs a dict");

  LinuxLinkGestureGate gate;
  Expect(gate.AcceptLinkDrop(1, true, 1.0) == "no drag from this page ended", "a page cannot drop without a real drag");
  Expect(gate.DragSource() == 0, "no press, no drag source");
  gate.NotePress(1);
  Expect(gate.DragSource() == 1, "the pressed page is the drag source");
  gate.NoteDrop(1);
  gate.NoteDragEnded(1, 2.0);
  Expect(gate.DragSource() == 0, "a drag end consumes the press");
  Expect(gate.AcceptLinkDrop(2, true, 2.1) == "the drag ended on another page", "another page cannot use the drop");
  Expect(gate.AcceptLinkDrop(1, false, 2.1) == "page not shown", "hidden pages cannot open a drop");
  Expect(gate.AcceptLinkDrop(1, true, 2.2).empty(), "a real drag that ended over the page opens");
  Expect(gate.AcceptLinkDrop(1, true, 2.3) == "that drag already opened a link", "one link per drag");

  gate.NotePress(1);
  gate.NoteDragEnded(1, 3.0);
  Expect(gate.AcceptLinkDrop(1, true, 3.1) == "the drag ended outside the page", "a drag with no drop on an Ray page opens nothing");

  gate.NotePress(1);
  gate.NoteDrop(2);
  gate.NoteDragEnded(1, 3.5);
  Expect(gate.AcceptLinkDrop(1, true, 3.6) == "the drag ended outside the page", "a drop on another window's page opens nothing");

  gate.NotePress(1);
  gate.NoteDrop(1);
  gate.NoteDrop(0);
  gate.NoteDragEnded(1, 3.7);
  Expect(gate.AcceptLinkDrop(1, true, 3.8) == "the drag ended outside the page", "the last drop of the drag decides, and the shell is no page");

  gate.NoteDrop(1);
  gate.NotePress(1);
  gate.NoteDragEnded(1, 3.9);
  Expect(gate.AcceptLinkDrop(1, true, 3.95) == "the drag ended outside the page", "a drop before the drag's press does not count");

  gate.NotePress(1);
  gate.NoteDrop(1);
  gate.NoteDragEnded(1, 4.0);
  Expect(gate.AcceptLinkDrop(1, true, 4.0 + LinuxLinkGestureGate::kDropLifetime + 0.1) == "the drag ended too long ago", "stale drop");

  gate.NotePress(1);
  gate.NoteDrop(1);
  gate.NoteDragEnded(1, 10.0);
  gate.NotePress(1);
  Expect(gate.AcceptLinkDrop(1, true, 10.1) == "the mouse was pressed again since the drag ended", "pressed since the drop");

  gate.NotePress(1);
  gate.NoteRelease(1, 0, 20.0, std::nullopt);
  Expect(gate.DragSource() == 0, "a release that reached the page is a click, not a drag");
  gate.NoteDrop(1);
  gate.NoteDragEnded(1, 20.1);
  Expect(gate.AcceptLinkDrop(1, true, 20.2) == "the mouse was pressed again since the drag ended", "a drag end without a pending press is ignored");
  gate.NotePress(1);
  gate.NoteDrop(1);
  gate.NoteDragEnded(0, 21.0);
  Expect(!gate.AcceptLinkDrop(1, true, 21.1).empty() && gate.DragSource() == 1, "an unknown source never matches");

  gate.NotePress(1);
  gate.NoteRelease(1, kLinuxLinkShift, 50.0, LinuxLinkPoint{4, 4}, true);
  Expect(gate.DragSource() == 1, "the release that ends a drag keeps the drag source");
  gate.NoteDrop(1);
  gate.NoteDragEnded(1, 50.1);
  Expect(gate.AcceptLinkDrop(1, true, 50.2).empty(), "a drag the platform ended with a release still opens its link");
  Expect(gate.Decide(Request(1, "shift", 50.3), LinuxPageOptions()).outcome == LinuxLinkOutcome::kNone,
         "the release that ends a drag is no click");

  gate.NotePress(5);
  gate.NoteDrop(5);
  gate.NoteDragEnded(5, 30.0);
  gate.Forget(5);
  Expect(gate.AcceptLinkDrop(5, true, 30.1) == "no drag from this page ended", "destroyed surface forgets its drop");
}

void DragOver() {
  LinuxDragOver own_page;
  Expect(!own_page.Over(), "no drag yet");
  own_page.Entered();
  own_page.Entered();
  const uint64_t release = own_page.Exited();
  Expect(own_page.Over(), "a refused drop on its own page: the leave and the drag end come in one batch, before the exit settles");
  own_page.Settle(release);
  Expect(!own_page.Over(), "once the exit settles the pointer has left");

  LinuxDragOver outside;
  outside.Entered();
  outside.Settle(outside.Exited());
  Expect(!outside.Over(), "a drag that left the page before it ended was not over it");

  LinuxDragOver returned;
  returned.Entered();
  const uint64_t left = returned.Exited();
  returned.Entered();
  returned.Settle(left);
  Expect(returned.Over(), "a stale exit doesn't undo coming back");

  LinuxDragOver never;
  never.Settle(never.Exited());
  Expect(!never.Over(), "an exit without an entry is never over");

  LinuxDragOver performed;
  performed.Entered();
  performed.Reset();
  Expect(!performed.Over(), "a new press forgets an earlier drag whose drop was performed without an exit");
  const uint64_t stale = performed.Exited();
  performed.Reset();
  performed.Entered();
  performed.Settle(stale);
  Expect(performed.Over(), "an exit from before the press doesn't undo the new drag");
}

void Activity() {
  LinuxInputActivity activity;
  Expect(activity.Note(10.0), "first input is announced");
  Expect(!activity.Note(10.2), "inputs inside the interval are folded");
  Expect(!activity.Note(10.0 + LinuxInputActivity::kInterval - 0.01), "still folded");
  Expect(activity.Note(10.0 + LinuxInputActivity::kInterval), "announced again after the interval");
  Expect(activity.Note(5.0), "a clock that went backwards announces");
  Expect(!activity.Note(5.1), "and folds again");
}

std::string FakeDigest(std::string_view text) { return "d" + std::to_string(text.size()) + ":" + std::string(text.substr(0, 4)); }

constexpr LinuxPageOperation kOperations[] = {
    {"exact", 12, "d12:post", LinuxPageOperationArgs::kNone, ""},
    {"replace", 7, "d7:(fn)", LinuxPageOperationArgs::kReplace, ")"},
    {"toggle", 12, "d12:r.to", LinuxPageOperationArgs::kLook, ")));"},
    {"setLook", 14, "d14:r.se", LinuxPageOperationArgs::kLook, "])));"},
};

base::Value Look(base::Value dark, base::Value size, base::Value font) {
  return base::Value(base::DictValue().Set("dark", std::move(dark)).Set("size", std::move(size)).Set("font", std::move(font)));
}

std::optional<base::Value> ParseLook(std::string_view json) {
  auto one = [](base::Value look) { return std::optional<base::Value>(base::Value(base::ListValue().Append(std::move(look)))); };
  if (json == "[{\"dark\":true,\"size\":4,\"font\":\"sans\"}]") return one(Look(base::Value(true), base::Value(4), base::Value("sans")));
  if (json == "[{ \"font\": \"serif\", \"size\": 0, \"dark\": false }]") return one(Look(base::Value(false), base::Value(0), base::Value("serif")));
  if (json == "[{\"dark\":true,\"size\":1,\"font\":\"sans\",\"x\":1}]") {
    auto look = Look(base::Value(true), base::Value(1), base::Value("sans"));
    look.GetDict().Set("x", 1);
    return one(std::move(look));
  }
  if (json == "[{\"dark\":1,\"size\":1,\"font\":\"sans\"}]") return one(Look(base::Value(1), base::Value(1), base::Value("sans")));
  if (json == "[{\"dark\":true,\"size\":1.5,\"font\":\"sans\"}]") return one(Look(base::Value(true), base::Value(1.5), base::Value("sans")));
  if (json == "[{\"dark\":true,\"size\":5,\"font\":\"sans\"}]") return one(Look(base::Value(true), base::Value(5), base::Value("sans")));
  if (json == "[{\"dark\":true,\"size\":-1,\"font\":\"sans\"}]") return one(Look(base::Value(true), base::Value(-1), base::Value("sans")));
  if (json == "[{\"dark\":true,\"size\":1,\"font\":\"mono\"}]") return one(Look(base::Value(true), base::Value(1), base::Value("mono")));
  if (json == "[{\"dark\":true,\"size\":1,\"font\":\"sans\"},1]") {
    return base::Value(base::ListValue().Append(Look(base::Value(true), base::Value(1), base::Value("sans"))).Append(1));
  }
  if (json == "[\"look\"]") return base::Value(base::ListValue().Append("look"));
  return std::nullopt;
}

void ReaderLooks() {
  const std::string canonical = "{\"dark\":true,\"size\":4,\"font\":\"sans\"}";
  auto toggle = LinuxPageEvaluationScript("r.toggle(R, " + canonical + ")));", FakeDigest, ParseLook, kOperations);
  Expect(toggle && toggle->find("r.toggle(R, " + canonical + ")));") != std::string::npos, "a valid look is accepted");
  auto set_look = LinuxPageEvaluationScript("r.setLook(...[" + canonical + "])));", FakeDigest, ParseLook, kOperations);
  Expect(set_look && set_look->find("r.setLook(...[" + canonical + "])));") != std::string::npos, "setLook keeps its own suffix");
  auto spaced = LinuxPageEvaluationScript("r.toggle(R, { \"font\": \"serif\", \"size\": 0, \"dark\": false })));", FakeDigest, ParseLook, kOperations);
  Expect(spaced && spaced->find("r.toggle(R, {\"dark\":false,\"size\":0,\"font\":\"serif\"})));") != std::string::npos &&
         spaced->find("\"font\": ") == std::string::npos, "the host re-emits a canonical look, not the page's text");
  for (const char* refused : {"{\"dark\":true,\"size\":1,\"font\":\"sans\",\"x\":1}", "{\"dark\":1,\"size\":1,\"font\":\"sans\"}",
                              "{\"dark\":true,\"size\":1.5,\"font\":\"sans\"}", "{\"dark\":true,\"size\":5,\"font\":\"sans\"}",
                              "{\"dark\":true,\"size\":-1,\"font\":\"sans\"}", "{\"dark\":true,\"size\":1,\"font\":\"mono\"}",
                              "{\"dark\":true,\"size\":1,\"font\":\"sans\"},1", "\"look\"", "{\"dark\":true}), alert(1), ({"}) {
    Expect(!LinuxPageEvaluationScript("r.toggle(R, " + std::string(refused) + ")));", FakeDigest, ParseLook, kOperations), refused);
  }
  Expect(!LinuxPageEvaluationScript("r.toggle(R, " + canonical + "));", FakeDigest, ParseLook, kOperations), "short suffix refused");
  Expect(!LinuxPageEvaluationScript("r.toggle(R, " + canonical + ")));x", FakeDigest, ParseLook, kOperations), "trailing code refused");
  Expect(!LinuxPageEvaluationScript("r.setLook(...[" + canonical + ")));", FakeDigest, ParseLook, kOperations), "setLook needs its bracket");
  Expect(!LinuxPageEvaluationScript("x.toggle(R, " + canonical + ")));", FakeDigest, ParseLook, kOperations), "tampered prefix refused");
  Expect(!LinuxPageEvaluationScript("r.toggle(R, )));", FakeDigest, ParseLook, kOperations), "a missing look is refused");
  Expect(!LinuxPageEvaluationScript("r.toggle(R, " + canonical + ")));", FakeDigest, LinuxPageJsonList(), kOperations), "no parser, no look");
}

std::optional<base::Value> ParseThree(std::string_view json) {
  if (json == "[\"a\", \"b\", true]") return base::Value(base::ListValue().Append("a").Append("b").Append(true));
  if (json == "[\"</script>\\u2028\", \"\\\"\", false]")
    return base::Value(base::ListValue().Append("</script>\xe2\x80\xa8").Append("\"").Append(false));
  if (json == "[\"a\", 1, true]") return base::Value(base::ListValue().Append("a").Append(1).Append(true));
  return std::nullopt;
}

constexpr LinuxPageOperation kPickerOperations[] = {
    {"start", 9, "d9:p.st", LinuxPageOperationArgs::kPoint, "]))"},
    {"apply", 9, "d9:p.ap", LinuxPageOperationArgs::kSelectors, "]))"},
};

std::optional<base::Value> ParsePicker(std::string_view json) {
  auto one = [](base::Value value) { return std::optional<base::Value>(base::Value(base::ListValue().Append(std::move(value)))); };
  if (json == "[[10.5, 20]]") return one(base::Value(base::ListValue().Append(10.5).Append(20)));
  if (json == "[null]") return one(base::Value());
  if (json == "[[1, 2, 3]]") return one(base::Value(base::ListValue().Append(1).Append(2).Append(3)));
  if (json == "[[1, \"2\"]]") return one(base::Value(base::ListValue().Append(1).Append("2")));
  if (json == "[[1, 2000000]]") return one(base::Value(base::ListValue().Append(1).Append(2000000)));
  if (json == "[[\"#a\", \"</script>\"]]") return one(base::Value(base::ListValue().Append("#a").Append("</script>")));
  if (json == "[[]]") return one(base::Value(base::ListValue()));
  if (json == "[[\"#a\", 3]]") return one(base::Value(base::ListValue().Append("#a").Append(3)));
  if (json == "[[\"\"]]") return one(base::Value(base::ListValue().Append("")));
  if (json == "[\"#a\"]") return one(base::Value("#a"));
  if (json == "[[\"#a\"], 1]") return base::Value(base::ListValue().Append(base::Value(base::ListValue().Append("#a"))).Append(1));
  return std::nullopt;
}

void PickerArguments() {
  auto start = LinuxPageEvaluationScript("p.start([[10.5, 20]]))", FakeDigest, ParsePicker, kPickerOperations);
  Expect(start && start->find("p.start([[10.5,20]]))") != std::string::npos, "a point is re-emitted canonically");
  auto anywhere = LinuxPageEvaluationScript("p.start([null]))", FakeDigest, ParsePicker, kPickerOperations);
  Expect(anywhere && anywhere->find("p.start([null]))") != std::string::npos, "a pick without a point is accepted");
  for (const char* refused : {"[1, 2, 3]", "[1, \"2\"]", "[1, 2000000]", "\"#a\""}) {
    Expect(!LinuxPageEvaluationScript("p.start([" + std::string(refused) + "]))", FakeDigest, ParsePicker, kPickerOperations), refused);
  }
  auto apply = LinuxPageEvaluationScript("p.apply([[\"#a\", \"</script>\"]]))", FakeDigest, ParsePicker, kPickerOperations);
  Expect(apply && apply->find("p.apply([[\"#a\",\"\\u003c/script\\u003e\"]]))") != std::string::npos, "selectors are re-escaped by the host");
  Expect(LinuxPageEvaluationScript("p.apply([[]]))", FakeDigest, ParsePicker, kPickerOperations).has_value(), "no selectors is fine");
  for (const char* refused : {"[\"#a\", 3]", "[\"\"]", "\"#a\"", "[\"#a\"], 1"}) {
    Expect(!LinuxPageEvaluationScript("p.apply([" + std::string(refused) + "]))", FakeDigest, ParsePicker, kPickerOperations), refused);
  }
  Expect(!LinuxPageEvaluationScript("p.apply([[]]))", FakeDigest, LinuxPageJsonList(), kPickerOperations), "no parser, no selectors");
  base::ListValue many;
  for (size_t i = 0; i <= kLinuxPickerSelectorsMax; ++i) many.Append("#a");
  Expect(!LinuxPickerSelectorsArgument(base::Value(base::ListValue().Append(base::Value(std::move(many))))), "too many selectors");
  Expect(!LinuxPickerSelectorsArgument(base::Value(base::ListValue().Append(base::Value(base::ListValue().Append(std::string(kLinuxPickerSelectorMax + 1, 'a')))))),
         "an oversized selector");
  Expect(!LinuxPickerSelectorsArgument(base::Value(base::ListValue().Append(base::Value(base::ListValue().Append(std::string("#a\0b", 4)))))),
         "a selector with a NUL");
  Expect(!LinuxPickerPointArgument(base::Value(base::ListValue().Append(base::Value(base::ListValue().Append(1.0 / 0.0).Append(1))))),
         "an infinite coordinate");
}

void Evaluation() {
  PickerArguments();
  Expect(MatchLinuxPageOperation("post('x', 1)", FakeDigest, kOperations)->operation->name == "exact", "exact match");
  Expect(!MatchLinuxPageOperation("post('x', 2) ", FakeDigest, kOperations), "length mismatch");
  Expect(!MatchLinuxPageOperation("alert(document.cookie)", FakeDigest, kOperations), "arbitrary code refused");
  Expect(!MatchLinuxPageOperation("", FakeDigest, kOperations), "empty refused");
  Expect(!MatchLinuxPageOperation(std::string(65 * 1024, 'p'), FakeDigest, kOperations), "oversized refused");

  auto script = LinuxPageEvaluationScript("(fn)()(\"a\", \"b\", true)", FakeDigest, ParseThree, kOperations);
  Expect(script && script->find("(fn)()(\"a\", \"b\", true)") != std::string::npos, "replace arguments rebuilt");
  auto escaped = LinuxPageEvaluationScript("(fn)()(\"</script>\\u2028\", \"\\\"\", false)", FakeDigest, ParseThree, kOperations);
  Expect(escaped && escaped->find("\\u003c/script\\u003e\\u2028") != std::string::npos && escaped->find("\"\\\"\"") != std::string::npos,
         "arguments re-escaped by the host");
  Expect(!LinuxPageEvaluationScript("(fn)()(\"a\", 1, true)", FakeDigest, ParseThree, kOperations), "argument types enforced");
  Expect(!LinuxPageEvaluationScript("(fn)()(\"a\"), alert(1), (\"b\", true)", FakeDigest, ParseThree, kOperations), "injected arguments refused");
  Expect(!LinuxPageEvaluationScript("(fn)()(\"a\", \"b\", true)x", FakeDigest, ParseThree, kOperations), "suffix enforced");

  auto wrapped = LinuxPageEvaluationScript("post('x', 1)", FakeDigest, ParseThree, kOperations);
  Expect(wrapped && wrapped->starts_with("(() => {") && wrapped->find("const post =") != std::string::npos &&
         wrapped->ends_with("})()"), "wrapper supplies post");
  Expect(LinuxPageEvaluationResult(base::Value("{\"a\":1}")) == std::optional<std::string>("{\"a\":1}"), "string result");
  Expect(!LinuxPageEvaluationResult(base::Value(1)), "non-string result");
  Expect(!LinuxPageEvaluationResult(base::Value(std::string(4 * 1024 * 1024 + 1, 'x'))), "oversized result");
  Expect(LinuxJavaScriptString("a\nb\\") == "\"a\\u000ab\\\\\"", "control characters escaped");
  ReaderLooks();
}

}

void NowPlayingReports() {
  Expect(kLinuxNowPlayingBytesMax == 1280 * 1024, "a page's now playing report may be as large as on macOS");
  Expect(LinuxNowPlayingReport(false, true, "playing") == "null", "no state is null");
  Expect(LinuxNowPlayingReport(true, true, "playing") == R"({"hasVideo":true,"playbackState":"playing"})", "a playing video");
  Expect(LinuxNowPlayingReport(true, false, "paused") == R"({"hasVideo":false,"playbackState":"paused"})", "paused audio");
  Expect(LinuxNowPlayingReport(true, true, "none") == R"({"hasVideo":true,"playbackState":"none"})", "no session state");
  Expect(LinuxNowPlayingReport(true, true, "\"},\"x\":\"") == R"({"hasVideo":true,"playbackState":"none"})", "unknown states are none");
  Expect(LinuxNowPlayingReport(true, true, "playing").size() < 64, "the reduced report is tiny");
}

LinuxLinkRequest SiteRequest(uintptr_t surface, double now, bool other_sites = true, bool main = true) {
  LinuxLinkRequest request = Request(surface, "site", now);
  request.main = main;
  request.other_sites = other_sites;
  return request;
}

void OtherSites() {
  Expect(LinuxPageMessageKindOf("newTabLink") == LinuxPageMessageKind::kNewTabLink, "new tab link kind");
  auto site = NormalizeLinuxPageMessage(LinuxPageMessageKind::kPeek, Dict(base::DictValue()
      .Set("url", "https://other.test/story").Set("key", "site").Set("origin", "https://page.test").Set("x", 4).Set("y", 5)
      .Set("moved", 0)));
  Expect(site && *site->data.GetDict().FindString("key") == "site" &&
         *site->data.GetDict().FindString("url") == "https://other.test/story", "the other-site key is accepted");
  for (const char* key : {"Site", "sites", "site ", "current"})
    Expect(!NormalizeLinuxPageMessage(LinuxPageMessageKind::kPeek, Dict(base::DictValue().Set("url", "https://a.test/").Set("key", key))), key);
  Expect(!NormalizeLinuxPageMessage(LinuxPageMessageKind::kPeek, Dict(base::DictValue().Set("url", "javascript:1").Set("key", "site"))),
         "a site peek is http(s) only");

  LinuxPageOptions options;
  Expect(options.PeekConfig().FindBool("otherSites") == false, "other sites are off unless the tab is eligible");
  Expect(options.PeekConfig(true).FindBool("otherSites") == true, "an eligible tab's page hears it");
  Expect(!options.PageConfig(true).Find("peekOtherSites") && !options.PageConfig(false, false, true).Find("peekOtherSites"),
         "the page config says nothing for an ineligible tab or a subframe");
  Expect(options.PageConfig(true, false, true).FindBool("peekOtherSites") == true, "the page config keeps an eligible main frame eligible");
  Expect(!options.ActionFor("site"), "the other-site key is never a modifier action");
  Expect(LinuxLinkKeyFlags("site") == 0, "a site click carries no modifier");

  LinuxLinkGestureGate gate;
  auto early = gate.Decide(SiteRequest(1, 0.5), options);
  Expect(early.outcome == LinuxLinkOutcome::kFollow && early.refused == "no left mouse-up yet" && early.site,
         "without a real mouse-up the page follows the link itself");
  gate.NotePress(1);
  gate.NoteRelease(1, 0, 1.0, LinuxLinkPoint{12, 34});
  auto off = gate.Decide(SiteRequest(1, 1.1, false), options);
  Expect(off.outcome == LinuxLinkOutcome::kFollow && off.refused == "that key opens nothing now", "an ineligible tab follows");
  auto frame = gate.Decide(SiteRequest(1, 1.1, true, false), options);
  Expect(frame.outcome == LinuxLinkOutcome::kFollow && frame.refused == "only the page itself peeks links to other sites",
         "a subframe follows");
  auto hidden = SiteRequest(1, 1.1);
  hidden.visible = false;
  Expect(gate.Decide(hidden, options).outcome == LinuxLinkOutcome::kFollow, "a hidden page follows");
  auto peek = gate.Decide(SiteRequest(1, 1.2), options);
  Expect(peek.outcome == LinuxLinkOutcome::kPeek && peek.site && peek.refused.empty() && peek.point && peek.point->x == 12,
         "a plain click on an eligible tab peeks at the click point, and the refusals before it used nothing up");
  auto again = gate.Decide(SiteRequest(1, 1.3), options);
  Expect(again.outcome == LinuxLinkOutcome::kFollow && again.refused == "that mouse-up already opened a peek", "one peek per click");
  gate.NotePress(1);
  gate.NoteRelease(1, kLinuxLinkShift, 2.0, std::nullopt);
  auto shifted = gate.Decide(SiteRequest(1, 2.1), options);
  Expect(shifted.outcome == LinuxLinkOutcome::kFollow && shifted.refused == "the mouse-up's keys aren't the page's key alone",
         "a modified click is never a site peek");
  Expect(gate.Decide(Request(1, "shift", 2.2), options).outcome == LinuxLinkOutcome::kPeek,
         "a refused site peek leaves the click for the modifier peek");
  gate.NotePress(2);
  gate.NoteRelease(2, 0, 3.0, std::nullopt);
  Expect(gate.Decide(SiteRequest(1, 3.1), options).refused == "the mouse-up wasn't over this page", "another tab's click");
  gate.NotePress(1);
  gate.NoteRelease(1, 0, 4.0, std::nullopt);
  Expect(gate.Decide(SiteRequest(1, 4.0 + LinuxLinkGestureGate::kGestureLifetime + 1), options).outcome == LinuxLinkOutcome::kFollow,
         "a stale click follows");
  gate.NotePress(1);
  gate.NoteRelease(1, 0, 20.0, std::nullopt);
  gate.NotePress(1);
  Expect(gate.Decide(SiteRequest(1, 20.1), options).refused == "the mouse was pressed again since that mouse-up", "pressed since");
  LinuxPageOptions no_peek;
  no_peek.SetPeek("off");
  gate.NoteRelease(1, 0, 21.0, std::nullopt);
  Expect(gate.Decide(SiteRequest(1, 21.1), no_peek).outcome == LinuxLinkOutcome::kPeek, "site peeks don't depend on the peek modifier");
  auto plain = gate.Decide(Request(1, "shift", 21.2), LinuxPageOptions());
  Expect(plain.outcome == LinuxLinkOutcome::kNone && !plain.site, "modifier requests never follow");
}

void StatusGeometry() {
  const LinuxStatusPane pane{200, 50, 800, 600};
  Expect(LinuxPointerFromPageBottom(300, 640, pane, 1) == std::optional<double>(10), "ten points above the page's bottom edge");
  Expect(LinuxPointerFromPageBottom(300, 50, pane, 1) == std::optional<double>(600), "the top edge is the whole height away");
  Expect(LinuxPointerFromPageBottom(300, 640, pane, 2) == std::optional<double>(5), "the distance is in the shell's own points");
  Expect(LinuxPointerFromPageBottom(300, 640, pane, 0.5) == std::optional<double>(20), "a zoomed-out shell");
  for (auto [x, y] : {std::pair<double, double>{199, 300}, {1000, 300}, {300, 49}, {300, 650}})
    Expect(!LinuxPointerFromPageBottom(x, y, pane, 1), "a pointer outside the page has no distance");
  Expect(!LinuxPointerFromPageBottom(300, 640, LinuxStatusPane{200, 50, 0, 600}, 1), "an empty page");
  Expect(!LinuxPointerFromPageBottom(300, 640, pane, 0) && !LinuxPointerFromPageBottom(300, 640, pane, std::numeric_limits<double>::quiet_NaN()),
         "an unusable shell scale");
  Expect(!LinuxPointerFromPageBottom(std::numeric_limits<double>::infinity(), 640, pane, 1), "a pointer that isn't finite");
}

void Commits() {
  Expect(LinuxReportCommits(base::DictValue().Set("on", true)) == true && LinuxReportCommits(base::DictValue().Set("on", false)) == false, "on and off");
  Expect(!LinuxReportCommits(base::DictValue()) && !LinuxReportCommits(base::DictValue().Set("on", 1)), "a boolean is required");
  LinuxPageCommits commits;
  base::DictValue fresh;
  commits.Report(fresh);
  Expect(fresh.FindDouble("committedAt") == 0.0 && !fresh.Find("httpStatus") && fresh.size() == 1, "no document has committed yet");
  commits.Note(1763112345678.0, 404);
  base::DictValue missing;
  commits.Report(missing);
  Expect(missing.FindDouble("committedAt") == 1763112345678.0 && missing.FindInt("httpStatus") == 404, "a commit carries its time and status");
  commits.Note(1763112345999.0, 0);
  base::DictValue local;
  commits.Report(local);
  Expect(local.FindDouble("committedAt") == 1763112345999.0 && !local.Find("httpStatus"), "a document without a response has no status");
  commits.Reset();
  base::DictValue replaced;
  commits.Report(replaced);
  Expect(replaced.FindDouble("committedAt") == 0.0 && !replaced.Find("httpStatus"), "new contents start over");
}

void LinkTabs() {
  auto ids = [](base::ListValue list) { return LinuxPeekSiteTabIds(base::DictValue().Set("tabIds", std::move(list))); };
  Expect(ids(base::ListValue()) && ids(base::ListValue())->empty(), "an empty list turns it off");
  auto two = ids(base::ListValue().Append("tab-a").Append("tab-b").Append("tab-a"));
  Expect(two && two->size() == 2, "ids are a set");
  Expect(!LinuxPeekSiteTabIds(base::DictValue()), "the list is required");
  Expect(!LinuxPeekSiteTabIds(base::DictValue().Set("tabIds", "tab-a")), "a string is not a list");
  Expect(!ids(base::ListValue().Append("tab-a").Append(7)), "every id is a string");
  Expect(!ids(base::ListValue().Append("")), "no empty id");
  Expect(!ids(base::ListValue().Append(std::string(kLinuxTabKeyMax + 1, 'k'))), "no oversized id");
  Expect(!ids(base::ListValue().Append(std::string("a\0b", 3))), "no nul in an id");
  base::ListValue many;
  for (size_t i = 0; i <= kLinuxPeekSiteTabsMax; ++i) many.Append("tab-" + std::to_string(i));
  Expect(!ids(std::move(many)), "the list is bounded");

  LinuxPeekSiteTabs tabs;
  Expect(!tabs.Has("tab-a") && !tabs.Has(""), "nothing peeks by default");
  auto first = tabs.Set({"tab-a", "tab-b"});
  Expect(first == std::vector<std::string>({"tab-a", "tab-b"}) && tabs.Has("tab-a"), "new tabs are the change");
  auto second = tabs.Set({"tab-b", "tab-c"});
  Expect(second == std::vector<std::string>({"tab-a", "tab-c"}) && !tabs.Has("tab-a") && tabs.Has("tab-b") && tabs.Has("tab-c"),
         "only added and removed tabs hear about it");
  Expect(tabs.Set({"tab-b", "tab-c"}).empty(), "the same list changes nothing");
  Expect(tabs.Clear() == std::vector<std::string>({"tab-b", "tab-c"}) && !tabs.Has("tab-b"), "a new renderer starts empty");

  Expect(LinuxNewTabLinksInPlace(base::DictValue().Set("enabled", true)) == true, "enabled");
  Expect(!LinuxNewTabLinksInPlace(base::DictValue().Set("enabled", "yes")) && !LinuxNewTabLinksInPlace(base::DictValue()), "a boolean is required");
  Expect(LinuxTabUrlBlank("") && LinuxTabUrlBlank("about:blank") && !LinuxTabUrlBlank("https://a.test/"), "blank urls");

  auto link = NormalizeLinuxPageMessage(LinuxPageMessageKind::kNewTabLink, Dict(base::DictValue().Set("url", "https://a.test/x").Set("extra", 1)));
  Expect(link && *link->data.GetDict().FindString("url") == "https://a.test/x" && link->data.GetDict().size() == 1, "new tab link keeps only its url");
  Expect(!NormalizeLinuxPageMessage(LinuxPageMessageKind::kNewTabLink, Dict(base::DictValue().Set("url", "javascript:1"))), "http(s) only");
  Expect(!NormalizeLinuxPageMessage(LinuxPageMessageKind::kNewTabLink, base::Value()), "a dictionary is required");
  Expect(LinuxPageSenderAccepted(LinuxPageMessageKind::kNewTabLink, LinuxPageSender{false, true, true}), "a subframe's link opens a tab too");

  LinuxNewTabLinks links;
  links.Note("", 0);
  Expect(links.size() == 0, "nothing to note");
  links.Note("https://a.test/1", 10.0);
  Expect(!links.TakeFor("https://a.test/other", "", 10.1), "another url doesn't match");
  Expect(links.TakeFor("https://a.test/other", "https://a.test/1", 10.2) == std::optional<std::string>("https://a.test/1"), "the tab's current url matches");
  Expect(!links.TakeFor("https://a.test/1", "", 10.3), "a link is taken once");
  links.Note("https://a.test/2", 20.0);
  Expect(!links.TakeFor("https://a.test/2", "", 20.0 + LinuxNewTabLinks::kLifetime), "a link is kept for two seconds");
  for (int i = 0; i < 6; ++i) links.Note("https://a.test/" + std::to_string(i), 30.0 + i * 0.1);
  Expect(links.size() == LinuxNewTabLinks::kKept, "four links are kept");
  Expect(!links.TakeFor("https://a.test/1", "", 30.6) && links.TakeFor("https://a.test/2", "", 30.6), "the oldest are dropped");
  Expect(links.TakeNoted(1, 30.7) == std::optional<std::string>("https://a.test/5"), "the newest note stands in for a hidden url");
  Expect(!links.TakeNoted(0.05, 30.7), "only a note that recent");
  Expect(!links.TakeFor("https://a.test/3", "", 29.0) && links.size() == 0, "a clock going backwards drops the notes");

  LinuxNewTabLinks ledger;
  auto attempt = [](std::string_view first, std::string_view current, bool hidden, int tries, bool activated, bool in_place, double now) {
    LinuxLinkTabAttempt a;
    a.first_url = first;
    a.current_url = current;
    a.hidden = hidden;
    a.tries = tries;
    a.activated = activated;
    a.in_place = in_place;
    a.now = now;
    return a;
  };
  ledger.Note("https://a.test/clicked", 1.0);
  auto in_place = MatchLinuxLinkTab(ledger, attempt("https://a.test/clicked", "", false, 0, false, true, 1.1));
  Expect(in_place.step == LinuxLinkTabStep::kInPlace && in_place.clicked == "https://a.test/clicked" && in_place.link_wait == "matched",
         "a clicked link stays in a Little Ray window");
  ledger.Note("https://a.test/clicked", 2.0);
  auto as_tab = MatchLinuxLinkTab(ledger, attempt("https://a.test/clicked", "", false, 0, false, false, 2.1));
  Expect(as_tab.step == LinuxLinkTabStep::kReport && as_tab.link_wait == "matched", "elsewhere the tab is reported as matched");
  auto skipped = MatchLinuxLinkTab(ledger, attempt("https://a.test/script", "", false, 0, false, true, 3.0));
  Expect(skipped.step == LinuxLinkTabStep::kReport && skipped.link_wait == "skipped" && skipped.clicked.empty(),
         "a tab no input could have opened is reported at once");
  auto waiting = MatchLinuxLinkTab(ledger, attempt("https://a.test/late", "", false, 0, true, true, 3.0));
  Expect(waiting.step == LinuxLinkTabStep::kRetry, "after recent input the note may still be on its way");
  Expect(MatchLinuxLinkTab(ledger, attempt("https://a.test/late", "", false, kLinuxLinkTabTries - 1, false, true, 3.2)).step == LinuxLinkTabStep::kRetry,
         "a retry keeps waiting");
  auto timed_out = MatchLinuxLinkTab(ledger, attempt("https://a.test/late", "", false, kLinuxLinkTabTries, true, true, 3.3));
  Expect(timed_out.step == LinuxLinkTabStep::kReport && timed_out.link_wait == "timedOut", "eight tries, then the tab opens as a tab");
  ledger.Note("https://a.test/late", 3.25);
  auto late = MatchLinuxLinkTab(ledger, attempt("https://a.test/late", "", false, 3, true, true, 3.3));
  Expect(late.step == LinuxLinkTabStep::kInPlace && late.clicked == "https://a.test/late", "a note that arrives during the wait matches");
  ledger.Note("https://a.test/redirector", 5.0);
  auto hidden = MatchLinuxLinkTab(ledger, attempt("https://b.test/landing", "https://b.test/landing", true, 0, true, true, 5.5));
  Expect(hidden.step == LinuxLinkTabStep::kInPlace && hidden.clicked == "https://a.test/redirector",
         "a tab that started blank takes the newest link noted in the last second");
  ledger.Note("https://a.test/redirector", 6.0);
  Expect(MatchLinuxLinkTab(ledger, attempt("https://b.test/landing", "", false, kLinuxLinkTabTries, true, true, 6.5)).link_wait == "timedOut",
         "a tab that never was blank needs its own url noted");
  Expect(kLinuxLinkTabTries == 8 && kLinuxBlankTabTries == 20 && kLinuxLinkTabRetryMs == 25 && kLinuxActivationLifespan == 5 &&
         LinuxNewTabLinks::kLifetime == 2 && LinuxNewTabLinks::kHiddenLifetime == 1 && LinuxNewTabLinks::kKept == 4,
         "the waits are the Mac's");
}

int main(int argc, char** argv) {
  if (argc != 2) return 2;
  const std::string name = argv[1];
  if (name == "kinds") Kinds();
  else if (name == "senders") Senders();
  else if (name == "normalization") Normalization();
  else if (name == "budget") Budget();
  else if (name == "options") Options();
  else if (name == "gestures") Gestures();
  else if (name == "evaluation") Evaluation();
  else if (name == "link-drops") LinkDrops();
  else if (name == "drag-over") DragOver();
  else if (name == "activity") Activity();
  else if (name == "now-playing-reports") NowPlayingReports();
  else if (name == "other-sites") OtherSites();
  else if (name == "link-tabs") LinkTabs();
  else if (name == "status-geometry") StatusGeometry();
  else if (name == "commits") Commits();
  else return 2;
  return 0;
}
