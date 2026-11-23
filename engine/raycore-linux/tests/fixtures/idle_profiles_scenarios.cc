#include <cassert>
#include <cstdio>
#include <string>
#include <vector>

#include "ray/linux/ac_linux_idle_profiles.h"

using namespace raycore;

namespace {

struct FakeTab {
  std::string key = "t1";
  std::string kept_by;
  bool history = true;
  bool sleepable = true;
  bool discarded = false;
  bool keeps = true;
  bool unloads = true;
  int unloaded = 0;
  LinuxIdleProfileTab Tab() {
    return LinuxIdleProfileTab{
        .key = key,
        .kept_by = kept_by,
        .can_keep_history = [this] { return history; },
        .discarded = [this] { return discarded; },
        .sleeps = [this](bool sleep) {
          if (!sleepable) return false;
          if (sleep) discarded = true;
          return true;
        },
        .keep_history = [this] { return keeps; },
        .unload = [this] { ++unloaded; return unloads; },
    };
  }
};

struct World {
  LinuxIdleProfileState state{.loaded = true, .loading = false, .regular = true, .held_open_by = std::nullopt};
  std::vector<FakeTab*> tabs;
  bool shows = false;
  int closed = 0;
  int releases = 0;
  std::string released = "released";
  base::DictValue Run() {
    std::vector<LinuxIdleProfileWindow> windows(1);
    windows[0].shows_profile = shows;
    for (FakeTab* tab : tabs) windows[0].tabs.push_back(tab->Tab());
    windows[0].close_member = [this] { ++closed; };
    return UnloadLinuxIdleProfile(state, windows, [this] { ++releases; return released; });
  }
};

std::string Status(const base::DictValue& reply) { return *reply.FindString("status"); }
std::string HeldBy(const base::DictValue& reply) {
  const std::string* held = reply.FindString("heldBy");
  return held ? *held : "";
}
size_t TabCount(const base::DictValue& reply) { return reply.Find("tabs")->GetList().size(); }

void NotLoaded() {
  World w;
  w.state.loaded = false;
  auto reply = w.Run();
  assert(Status(reply) == "released" && TabCount(reply) == 0 && HeldBy(reply).empty() && w.releases == 0);
  w.state.loading = true;
  reply = w.Run();
  assert(Status(reply) == "busy" && HeldBy(reply) == "profile");
}

void HeldOpen() {
  World w;
  w.state.regular = false;
  assert(HeldBy(w.Run()) == "profile");
  w.state.regular = true;
  w.state.held_open_by = "download";
  assert(HeldBy(w.Run()) == "download" && w.releases == 0);
}

void Shown() {
  World w;
  FakeTab tab;
  w.tabs = {&tab};
  w.shows = true;
  auto reply = w.Run();
  assert(Status(reply) == "busy" && HeldBy(reply) == "window" && !tab.discarded && w.closed == 0);
}

void TabsKeepIt() {
  FakeTab unbound;
  unbound.key = "";
  World a;
  a.tabs = {&unbound};
  assert(HeldBy(a.Run()) == "tab");
  FakeTab playing;
  playing.kept_by = "pictureInPicture";
  World b;
  b.tabs = {&playing};
  assert(HeldBy(b.Run()) == "pictureInPicture" && !playing.discarded);
  FakeTab no_history;
  no_history.history = false;
  World c;
  c.tabs = {&no_history};
  assert(HeldBy(c.Run()) == "history" && !no_history.discarded);
  FakeTab protected_page;
  protected_page.sleepable = false;
  FakeTab other;
  other.key = "t2";
  World d;
  d.tabs = {&other, &protected_page};
  assert(HeldBy(d.Run()) == "page" && !other.discarded && d.closed == 0);
}

void SettlesFirst() {
  FakeTab tab;
  World w;
  w.tabs = {&tab};
  auto reply = w.Run();
  assert(Status(reply) == "busy" && HeldBy(reply) == "sleeping" && tab.discarded && tab.unloaded == 0);
  reply = w.Run();
  assert(Status(reply) == "released" && TabCount(reply) == 1 && reply.Find("tabs")->GetList()[0].GetString() == "t1");
  assert(tab.unloaded == 1 && w.closed == 1 && w.releases == 1);
}

void HistoryNotKept() {
  FakeTab tab;
  tab.discarded = true;
  tab.keeps = false;
  World w;
  w.tabs = {&tab};
  assert(HeldBy(w.Run()) == "sleeping" && tab.unloaded == 0);
}

void UnloadFails() {
  FakeTab first;
  first.discarded = true;
  FakeTab second;
  second.key = "t2";
  second.discarded = true;
  second.unloads = false;
  World w;
  w.tabs = {&first, &second};
  auto reply = w.Run();
  assert(Status(reply) == "busy" && HeldBy(reply) == "history" && TabCount(reply) == 1 && w.closed == 0 && w.releases == 0);
}

void Pending() {
  World w;
  w.released = "pending";
  auto reply = w.Run();
  assert(Status(reply) == "pending" && TabCount(reply) == 0 && w.closed == 1);
}

}

int main() {
  NotLoaded();
  HeldOpen();
  Shown();
  TabsKeepIt();
  SettlesFirst();
  HistoryNotKept();
  UnloadFails();
  Pending();
  std::puts("idle profile scenarios passed");
}
