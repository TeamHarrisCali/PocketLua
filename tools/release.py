#!/usr/bin/env python3
"""Build the App Store release folder that the Cardputer downloads from GitHub.

  tools/release.py            (after `pio run`; uses .pio/build/.../firmware.bin)

Writes release/ in the repository, laid out like /pocketlua on the device:
  catalog.txt          what the store lists (see below)
  apps/<name>/main.lua and main.luac
                       every app (userland/apps and store/apps), as source (for
                       the header and the editor) and bytecode (what runs:
                       compiling on the device needs about twice the RAM)
  lib/<path>.lua/.luac the libraries apps use (userland/lib)
  PocketLua.bin        the firmware

catalog.txt, one entry per line, fields separated by tabs:
  pocketlua-catalog 1
  firmware  <build>  <size>  <sha256>  <commit time>
  app   <name>  core|app  <src size> <src sha256> <code size> <code sha256>  <title>  <category>  <icon>  <libs>  <description>
  lib   <path>  <src size> <src sha256> <code size> <code sha256>
<libs> lists the libraries the app requires ("-" for none, else comma
separated module names). Core apps (Settings, App Store, editor) are also
built into the firmware: they can be updated but not uninstalled.

Commit release/ and push the branch the device reads (beta by default). The
bytecode is made by .pio/luac32 (built by tools/gen_embed.py from lib/lua),
so it matches the firmware's Lua.
"""
import hashlib, os, re, shutil, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "release")
LUAC = os.path.join(ROOT, ".pio", "luac32")
FIRMWARE = os.path.join(ROOT, ".pio", "build", "cardputer-adv", "firmware.bin")
CORE = {"settings", "store", "edit"}  # same as CORE_APPS in tools/gen_embed.py


def sha(data):
    return hashlib.sha256(data).hexdigest()


def header(src):
    """title, category, icon from the one-line header; description from the first comment."""
    m = re.search(r"local app = \{([^\n]*)\}", src)
    h = m.group(1) if m else ""
    field = lambda k, d: (re.search(k + r'\s*=\s*"([^"]*)"', h) or [None, d])[1]
    desc = []
    for line in src.splitlines():
        if not line.startswith("--"):
            break
        desc.append(line[2:].strip())
    text = " ".join(desc)
    text = re.sub(r"^[^:]{1,30}:\s*", "", text)  # "Music: an MP3 player..." -> "an MP3 player..."
    clean = lambda s: s.replace("\t", " ")
    return clean(field("title", "")), clean(field("category", "tools")), clean(field("icon", "app")), clean(text[:140])


def compile_lua(src_path, out_path):
    r = subprocess.run([LUAC, src_path, out_path], capture_output=True, text=True)
    if r.returncode:
        sys.exit("bytecode failed for %s: %s" % (src_path, r.stderr))


def main():
    if not os.path.exists(LUAC) or not os.path.exists(FIRMWARE):
        sys.exit("build first: pio run (makes .pio/luac32 and the firmware)")
    fw = open(FIRMWARE, "rb").read()
    m = re.search(rb"PLBUILD:([0-9a-f]+\+?|unknown)", fw)
    build = m.group(1).decode() if m else "unknown"
    if build.endswith("+") or build == "unknown":
        print("warning: firmware build is %s (uncommitted changes); commit, rebuild, then release" % build)
    if os.path.exists(OUT):
        shutil.rmtree(OUT)
    os.makedirs(os.path.join(OUT, "apps"))
    shutil.copyfile(FIRMWARE, os.path.join(OUT, "PocketLua.bin"))
    # the commit time lets the device offer only a newer firmware
    t = subprocess.run(["git", "show", "-s", "--format=%ct", build.rstrip("+")], cwd=ROOT,
                       capture_output=True, text=True).stdout.strip() or "0"
    lines = ["pocketlua-catalog 1", "\t".join(["firmware", build, str(len(fw)), sha(fw), t])]

    def add(src_path, rel):
        """Copies the source, compiles the bytecode; returns the size/hash fields."""
        dst = os.path.join(OUT, rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copyfile(src_path, dst)
        compile_lua(src_path, dst + "c")
        src, code = open(dst, "rb").read(), open(dst + "c", "rb").read()
        return [str(len(src)), sha(src), str(len(code)), sha(code)]

    for folder in ("userland/apps", "store/apps"):
        d = os.path.join(ROOT, folder)
        for f in sorted(os.listdir(d)) if os.path.isdir(d) else []:
            if not f.endswith(".lua"):
                continue
            name = f[:-4]
            path = os.path.join(d, f)
            src = open(path, encoding="utf-8").read()
            title, cat, icon, desc = header(src)
            libs = sorted(set(re.findall(r'require\s*\(?\s*"([\w/]+)"', src)))
            kind = "core" if name in CORE else "app"
            lines.append("\t".join(["app", name, kind] + add(path, "apps/%s/main.lua" % name) +
                                    [title or name, cat, icon, ",".join(libs) or "-", desc]))
    libroot = os.path.join(ROOT, "userland", "lib")
    for dp, _, names in sorted(os.walk(libroot)):
        for f in sorted(names):
            if f.endswith(".lua"):
                rel = os.path.relpath(os.path.join(dp, f), os.path.join(ROOT, "userland")).replace(os.sep, "/")
                lines.append("\t".join(["lib", rel] + add(os.path.join(dp, f), rel)))
    open(os.path.join(OUT, "catalog.txt"), "w").write("\n".join(lines) + "\n")
    apps = sum(1 for l in lines if l.startswith("app\t"))
    libs = sum(1 for l in lines if l.startswith("lib\t"))
    print("release/: firmware %s (%d KB), %d apps, %d libraries" % (build, len(fw) // 1024, apps, libs))


if __name__ == "__main__":
    main()
