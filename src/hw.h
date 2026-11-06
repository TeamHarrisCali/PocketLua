#pragma once
#include <lua.hpp>
#include <stddef.h>
#include <stdint.h>

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

// Stops audio and the radios and powers the codec and IMU down (deep sleep).
void hwSleepPrepare();

// Long blocking calls (HTTP, LoRa send, ...) reset the script time budget so
// they are not mistaken for a hung script. Provided by main.cpp.
void luaBudgetReset();

// ---------------------------------------------------------------- LoRa radio
// The core owns the Cap LoRa-1262: an app borrows it with lora.begin and gives
// it back when it closes; in between the Mesh background listener
// (meshsvc.cpp) may use it. An app always wins.
struct LoraParams {
  float freq = 915.0, bw = 125.0, tcxo = 1.8;  // 1.8 V: the cap's TCXO
  int sf = 9, cr = 5, sync = 0x12, preamble = 12, power = 14;
};
bool hwLoraCap();                     // the cap answers on I2C
bool hwLoraAppOwns();
bool hwLoraBegin(const LoraParams &p);  // for the listener; false if an app has it or no radio
void hwLoraStop();                    // the listener lets go (not an app's radio)
bool hwLoraBusy();
bool hwLoraSend(const uint8_t *buf, size_t len);
size_t hwLoraRecv(uint8_t buf[256], float &rssi, float &snr);  // 0: nothing waiting

void meshsvcBegin();   // boot: the listener's on/off default
void meshsvcTick();    // main loop
void meshsvcPause();   // an app is taking the radio
