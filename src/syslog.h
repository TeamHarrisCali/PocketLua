#pragma once

// Captures ESP-IDF and Arduino-core error messages (normally printed to a
// UART pin nobody can read) so they appear in the USB device log.
namespace syslog {
void begin();
void drain();  // call from the main loop: forwards captured lines to the log
}
