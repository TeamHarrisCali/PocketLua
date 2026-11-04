#!/usr/bin/env python3
"""Build the Music app's library index for a LiveOS music folder (needs ffprobe).

  music_library.py /run/media/$USER/CARD/pocketlua/data/music

Reads the tags of every MP3/WAV under the folder and writes the index to
<folder>/.library/. The Cardputer has too little RAM to sort a library, so the
lists are built here, already sorted, as fixed-size text records: the device
reads only the rows on screen by seeking to row * size.

  info.txt     "liveos-library 1" and counts
  tracks.dat   512 B: path \t title \t artist \t album \t genre \t track \t album artist \t disc
               sorted by album artist, album, disc, track, title
  artists.dat  128 B: name \t first track \t count       (tracks are contiguous)
  albums.dat   128 B: album \t artist \t first track \t count   (sorted by album)
  genres.dat   128 B: genre \t first \t count            (rows of gtracks.dat)
  gtracks.dat    8 B: track number, the tracks of each genre in order

Text shown on the device is folded to ASCII (its font has no accents); paths
are kept exactly. Only the .library folder is written; music files are only
read. Run it again after adding music.
"""
import concurrent.futures, json, os, subprocess, sys, unicodedata

TRACK, ROW, GROW = 512, 128, 8
QUOTES = {"‘": "'", "’": "'", "“": '"', "”": '"', "–": "-", "—": "-", "…": "...", "÷": "/", "×": "x"}


def ascii(s, limit):
    s = "".join(QUOTES.get(c, c) for c in (s or ""))
    s = unicodedata.normalize("NFKD", s).encode("ascii", "ignore").decode()
    s = " ".join(s.replace("\t", " ").split())
    return s[:limit] or "(untitled)"


def num(s):
    try:
        return int(str(s).split("/")[0])
    except ValueError:
        return 0


def probe(path):
    r = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format_tags", "-of", "json", path],
                       capture_output=True, text=True)
    try:
        tags = json.loads(r.stdout).get("format", {}).get("tags", {})
    except json.JSONDecodeError:
        tags = {}
    return {k.lower(): v for k, v in tags.items()}


def record(fields, size):
    line = "\t".join(fields).encode()
    if len(line) > size - 1:
        raise ValueError("record too long")
    return line + b" " * (size - 1 - len(line)) + b"\n"


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    root = os.path.realpath(sys.argv[1])
    files = []
    for d, dirs, names in os.walk(root):
        dirs[:] = sorted(x for x in dirs if not x.startswith("."))
        for n in sorted(names):
            if not n.startswith(".") and n.lower().endswith((".mp3", ".wav")):
                files.append(os.path.join(d, n))
    print(f"reading tags of {len(files)} tracks ...")
    with concurrent.futures.ThreadPoolExecutor(8) as pool:
        tags = list(pool.map(probe, files))

    tracks, skipped = [], []
    for path, t in zip(files, tags):
        rel = os.path.relpath(path, root)
        parts = rel.split(os.sep)
        # Fall back to the Artist/Album/track.mp3 folders and the file name.
        title = t.get("title") or os.path.splitext(parts[-1])[0]
        artist = t.get("artist") or (parts[-3] if len(parts) >= 3 else "Unknown artist")
        group = t.get("album_artist") or artist
        album = t.get("album") or (parts[-2] if len(parts) >= 2 else "Unknown album")
        genre = t.get("genre") or "Unknown genre"
        tr = {"rel": rel, "title": ascii(title, 80), "artist": ascii(artist, 60), "group": ascii(group, 60),
              "album": ascii(album, 60), "genre": ascii(genre, 30), "disc": num(t.get("disc")), "track": num(t.get("track"))}
        if len(rel.encode()) > 300:
            skipped.append(rel)
            continue
        tracks.append(tr)
    key = lambda x: (x["group"].lower(), x["album"].lower(), x["disc"], x["track"], x["title"].lower())
    tracks.sort(key=key)

    out = os.path.join(root, ".library")
    os.makedirs(out, exist_ok=True)

    def write(name, rows):
        tmp = os.path.join(out, name + ".part")
        with open(tmp, "wb") as f:
            f.write(b"".join(rows))
        os.replace(tmp, os.path.join(out, name))

    def track_rec(t):
        # the text gets whatever room the path leaves (as on the device)
        room = (480 - len(t["rel"].encode())) // 5
        f = [t["title"], t["artist"], t["album"], t["genre"], t["group"]]
        f = [x[:room].strip() or "(untitled)" for x in f]
        return record([t["rel"], f[0], f[1], f[2], f[3], str(t["track"] or ""), f[4], str(t["disc"])], TRACK)

    write("tracks.dat", [track_rec(t) for t in tracks])

    artists, albums = [], []
    for i, t in enumerate(tracks):
        if not artists or artists[-1][0].lower() != t["group"].lower():
            artists.append([t["group"], i, 0])
        artists[-1][2] += 1
        if not albums or (albums[-1][1].lower(), albums[-1][0].lower()) != (t["group"].lower(), t["album"].lower()):
            albums.append([t["album"], t["group"], i, 0])
        albums[-1][3] += 1
    albums.sort(key=lambda a: (a[0].lower(), a[1].lower()))
    write("artists.dat", [record([a, str(i), str(n)], ROW) for a, i, n in artists])
    write("albums.dat", [record([a, ar, str(i), str(n)], ROW) for a, ar, i, n in albums])

    by_genre = {}
    for i, t in enumerate(tracks):
        by_genre.setdefault(t["genre"].lower(), [t["genre"], []])[1].append(i)
    genres, gtracks = [], []
    for _, (name, idx) in sorted(by_genre.items()):
        genres.append(record([name, str(len(gtracks)), str(len(idx))], ROW))
        gtracks += [f"{i:07d}\n".encode() for i in idx]
    write("genres.dat", genres)
    write("gtracks.dat", gtracks)
    write("info.txt", [f"liveos-library 1\ntracks {len(tracks)}\nartists {len(artists)}\nalbums {len(albums)}\n"
                       f"genres {len(genres)}\n".encode()])

    print(f"{len(tracks)} tracks, {len(artists)} artists, {len(albums)} albums, {len(genres)} genres -> {out}")
    for rel in skipped:
        print("skipped (path too long):", rel)


if __name__ == "__main__":
    main()
