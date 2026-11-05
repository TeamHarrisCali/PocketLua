#pragma once
#include <Arduino.h>
#include <lua.hpp>

// Registers the sys, cfg, gfx, snd, imu, wifi, clock, usb and net tables.
void registerApi(lua_State *L);
bool openApiLib(lua_State *L, const char *name);  // gfx, snd, imu, wifi, usb, net, clock: made on first use

// Helpers shared with the native system (system.cpp).
String cfgGet(const char *key, const char *def = "");
void cfgSet(const char *key, const String &value);
// Compiles path (from flash or SD) and pushes the chunk; on failure sets err.
bool loadChunk(lua_State *L, const String &path, bool builtinOnly, bool strip, String &err);
void playTone(uint16_t freq, uint32_t ms);
void batteryInfo(int &pct, bool &charging);
bool wifiEnable(bool on);
size_t wifiStartCost();  // bytes the next Wi-Fi start is expected to take
void wifiConnect(const char *ssid, const char *pass);
void settingsTick();   // writes data/settings.txt after changes
void settingsFlush();  // writes now (before a reboot)

// Provided by main.cpp
extern int g_bandY;
extern int g_bandH;
extern bool g_displayAsleep;
extern bool g_displayHold;
extern String g_screenshotPath;
static const int SCREEN_W = 240, SCREEN_H = 135;
size_t luaMemUsed();
void luaBudgetReset();
