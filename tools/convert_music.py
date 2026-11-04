#!/usr/bin/env python3
"""Make a PocketLua-playable copy of a music library (needs ffmpeg).

  convert_music.py ~/Music /run/media/$USER/CARD/pocketlua/data/music [--bitrate 128k] [--jobs 4]

The device plays MP3 and WAV. Every other audio file in SOURCE (M4A, FLAC,
AIFF, OGG, ...) becomes an MP3 at the same place under DEST, with its tags
(artist, album, title, track) and without cover art. MP3 and WAV files are
copied as they are. Artist/Album folders are kept.

SOURCE is only ever read. Nothing that already exists is replaced: a track
whose output is already in DEST is skipped, so the script can be stopped and
run again. Output is written as .part and renamed when complete. DEST may not
be inside SOURCE (or the other way round). Copy-protected .m4p files can't be
converted and are listed at the end.
"""
import argparse, concurrent.futures, os, shutil, subprocess, sys

CONVERT = {".m4a", ".flac", ".aif", ".aiff", ".ogg", ".opus", ".wma", ".aac", ".alac", ".ape", ".wv"}
COPY = {".mp3", ".wav"}
PROTECTED = {".m4p"}


def inside(a, b):
    """True if path a is b or inside b."""
    return os.path.commonpath([a, b]) == b


def plan(src, dst):
    jobs, protected = [], []
    for root, dirs, files in os.walk(src):
        dirs.sort()
        for name in sorted(files):
            if name.startswith("."):
                continue
            stem, ext = os.path.splitext(name)
            ext = ext.lower()
            path = os.path.join(root, name)
            rel = os.path.relpath(root, src)
            if ext in PROTECTED:
                protected.append(path)
            elif ext in CONVERT:
                jobs.append(("convert", path, os.path.join(dst, rel, stem + ".mp3")))
            elif ext in COPY:
                jobs.append(("copy", path, os.path.join(dst, rel, name)))
    return jobs, protected


def run(job, bitrate, src):
    kind, path, out = job
    assert not inside(os.path.realpath(out), src), out  # never write into the source
    if os.path.exists(out):
        return "skipped", path, ""
    os.makedirs(os.path.dirname(out), exist_ok=True)
    part = out + ".part"
    if os.path.exists(part):
        os.remove(part)  # our own leftover from an interrupted run
    if kind == "copy":
        shutil.copyfile(path, part)
    else:
        cmd = ["ffmpeg", "-nostdin", "-v", "error", "-n", "-i", path, "-map", "0:a:0", "-vn",
               "-map_metadata", "0", "-id3v2_version", "3", "-c:a", "libmp3lame", "-b:a", bitrate,
               "-ar", "44100", "-f", "mp3", part]
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode != 0:
            if os.path.exists(part):
                os.remove(part)
            return "failed", path, r.stderr.strip().splitlines()[-1] if r.stderr.strip() else "ffmpeg failed"
    if os.path.exists(out):  # appeared meanwhile: keep it, drop ours
        os.remove(part)
        return "skipped", path, ""
    os.rename(part, out)
    return kind + "ed" if kind == "convert" else "copied", path, ""


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("source")
    ap.add_argument("dest")
    ap.add_argument("--bitrate", default="128k")
    ap.add_argument("--jobs", type=int, default=4)
    ap.add_argument("--dry-run", action="store_true", help="only show what would be done")
    a = ap.parse_args()
    src, dst = os.path.realpath(a.source), os.path.realpath(a.dest)
    if not os.path.isdir(src):
        sys.exit(f"not a folder: {src}")
    if inside(dst, src) or inside(src, dst):
        sys.exit("DEST and SOURCE must not be inside each other")
    if not shutil.which("ffmpeg"):
        sys.exit("ffmpeg is not installed")

    jobs, protected = plan(src, dst)
    todo = [j for j in jobs if not os.path.exists(j[2])]
    print(f"{len(jobs)} tracks, {len(jobs) - len(todo)} already in DEST, {len(todo)} to do "
          f"({sum(1 for j in todo if j[0] == 'convert')} to convert)")
    if a.dry_run:
        for kind, path, out in todo[:20]:
            print(f"  {kind}: {os.path.relpath(path, src)} -> {os.path.relpath(out, dst)}")
        return

    counts, failures = {}, []
    with concurrent.futures.ThreadPoolExecutor(a.jobs) as pool:
        futures = [pool.submit(run, j, a.bitrate, src) for j in todo]
        for i, f in enumerate(concurrent.futures.as_completed(futures), 1):
            result, path, err = f.result()
            counts[result] = counts.get(result, 0) + 1
            if result == "failed":
                failures.append((path, err))
            print(f"\r{i}/{len(todo)}", end="", flush=True)
    print()
    print(", ".join(f"{n} {k}" for k, n in sorted(counts.items())) or "nothing to do")
    for path, err in failures:
        print(f"FAILED {os.path.relpath(path, src)}: {err}")
    if protected:
        print(f"{len(protected)} copy-protected .m4p file(s) can't be converted:")
        for p in protected:
            print("  " + os.path.relpath(p, src))


if __name__ == "__main__":
    main()
