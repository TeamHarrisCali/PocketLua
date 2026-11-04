#pragma once
#include <Arduino.h>
#include <lua.hpp>

// Registers the sys, cfg, gfx, snd, imu, wifi and clock tables.
void registerApi(lua_State *L);

// Provided by main.cpp
extern bool g_reloadRequested;
// The frame buffer covers one horizontal band of the screen at a time; this is
// the screen row it starts at. Drawing calls subtract it from y.
extern int g_bandY;
extern bool g_displayAsleep;
extern bool g_displayHold;
extern String g_screenshotPath;
static const int SCREEN_W = 240, SCREEN_H = 135;
extern String g_recoveredMsg;
size_t luaMemUsed();
void luaBudgetReset();
