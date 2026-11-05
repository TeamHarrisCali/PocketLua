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
size_t wifiStartCost();
int volumeStep(int d);    // one volume level up/down (20 levels, 2.5 dB apart); returns the level
int volumeLevel(int raw); // the level of a 0-255 "vol" setting
bool headphones();        // headphone mode: own volume, capped at headphoneMax()
int headphoneMax();       // that cap, as a level (1-20)
void setHeadphones(bool on);  // bytes the next Wi-Fi start is expected to take
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
