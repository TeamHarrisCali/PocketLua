#pragma once
#include <Arduino.h>
#include <FS.h>
#include <vector>

// Script storage. Files live under /liveos on the SD card (or internal flash
// when no card is present). Scripts shipped in the firmware are the fallback,
// so a stored file always overrides the built-in one. Paths starting with
// "sd:" address the raw card instead and never fall back to built-ins.
namespace store {

struct Entry {
  String name;
  bool dir;
  bool stored;
  bool emb;
  size_t size;
};

bool begin();
const char *kind();  // "SD" or "flash"
bool hasSd();
extern bool safeMode;  // ignore stored lib/ and boot.lua

bool readText(const String &rel, String &out, bool builtinOnly = false);

// Like readText, but built-in scripts are returned straight from flash with no
// heap copy. `buf` only holds data when the file came from storage.
// maxBytes > 0 reads only the start of the file.
bool view(const String &rel, String &buf, const char *&ptr, size_t &len, bool builtinOnly = false,
          size_t maxBytes = 0);
bool write(const String &rel, const String &data);
bool append(const String &rel, const char *data, size_t len);
bool rename(const String &from, const String &to);
bool remove(const String &rel);
bool exists(const String &rel);
bool inStorage(const String &rel);
bool embedded(const String &rel);
bool mkdirs(const String &rel);
std::vector<Entry> list(const String &dir);
uint64_t totalBytes();
uint64_t usedBytes();

// While the SD card is shared with a computer over USB the firmware must not
// touch it, so scripts fall back to the built-in copies until it is released.
void lock(bool on);
bool remount();

// The SD card is mounted only while used: idleTick() (every frame) unmounts it
// after a few idle seconds; pin(true/false) keeps it mounted for streaming.
void idleTick();
void pin(bool on);

// For drivers that stream files (audio, screenshots, images): the filesystem
// and real path behind a script path. Returns nullptr when the path is invalid
// or storage is locked. Parent folders are created when `forWrite` is set.
fs::FS *resolve(const String &rel, String &real, bool forWrite = false);

}  // namespace store
