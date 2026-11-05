#pragma once
#include <lua.hpp>

// Hardware drivers exposed to Lua: audio, ir, i2c, http, lora, gps, disp.
// Everything is started on first use and released again, because RAM is the
// scarcest resource on this board (no PSRAM).
void registerHw(lua_State *L);

// Called every frame by the main loop: stops the speaker when idle and
// finishes background audio work.
void hwTick();

// Installs the speaker's pop-free on/off step (main.cpp, after M5Cardputer.begin).
void hwAudioBegin();

// The volume setting (0-255 "vol") applied: in the codec on the ADV.
void hwSetVolume(int raw);

// Long blocking calls (HTTP, LoRa send, ...) reset the script time budget so
// they are not mistaken for a hung script. Provided by main.cpp.
void luaBudgetReset();
