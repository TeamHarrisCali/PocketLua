#pragma once
#include <Arduino.h>

// Tags of a music file, as plain ASCII (the UI font has no accents).
struct Tags {
  String title, artist, album, albumArtist, genre, track, disc;
};

// Reads the ID3v2 (2.2-2.4) or ID3v1 tag of a file in LiveOS storage, e.g.
// "data/music/Artist/Album/01 Song.mp3". Fields that are missing stay empty.
bool readTags(const String &path, Tags &t);

// Appends code point c / UTF-8 text as plain ASCII: Latin-1 letters folded
// (e for an accented e), typographic quotes and dashes simplified, else '?'.
void putAscii(String &out, uint32_t c);
void utf8Ascii(String &out, const uint8_t *p, size_t n);
