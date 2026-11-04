#pragma once
#include <Arduino.h>
#include <lua.hpp>

// The native OS: desktop, app drawer, app lifecycle (one Lua VM per open
// app), dialogs, toasts, overlays, notifications, timers, alarms, sounds,
// display sleep and lock, Wi-Fi service and the USB console. Apps reach it
// through the Lua `shell` table.
namespace shell {

struct Key {
  const char *key;
  const char *text;  // nullptr when the key types nothing
  bool ctrl, shift, fn, alt;
};

void begin(bool safeMode);
void update(float dt);
void drawBand();  // draws the current band (g_bandY) into the frame buffer
void key(const Key &k);
void screenshotDone(const String &path, bool ok);
void setHold(bool on);  // sys.display_hold from apps
void requestHome();     // sys.reload
void registerLua(lua_State *L);
void runPending();  // navigation requested by Lua, done between frames

}  // namespace shell
