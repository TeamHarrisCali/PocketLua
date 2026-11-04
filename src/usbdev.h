#pragma once
#include <Arduino.h>

// USB device: any mix of HID keyboard, CDC serial and mass storage (the SD
// card). The mix is fixed at boot because USB descriptors cannot change later.
namespace usbdev {

void begin(bool keyboard, bool drive, bool serial, bool console, bool mouse = false);
bool mouseOn();
void mouseMove(int dx, int dy, int wheel);
void mouseClick(const char *button);
void mouseButton(const char *button, bool down);
bool keyboardOn();
bool driveOn();
bool serialOn();
bool serialConnected();

void typeText(const String &s);
void key(const String &spec);  // e.g. "enter", "ctrl+c", "f5"

void serialWrite(const String &s);
String serialRead();
int serialGet();  // one received byte, or -1

// Device log: kept in memory (last few KB) and written live to the USB serial
// port as "# ..." lines unless the Lua console owns the port.
void log(const String &line);
String logDump();
void tick();  // call every frame

void share(bool on);
bool sharing();

}  // namespace usbdev
