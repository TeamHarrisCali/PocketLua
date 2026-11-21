#!/usr/bin/env python3
"""Builds the five-letter word lists for the Wordy game, offline.

  python3 tools/make_words.py <en_US.dic> <en_US.aff>

Reads a Hunspell en_US dictionary (derived from SCOWL), expands its affix
rules, keeps every lower-case five-letter word, and writes
userland/lib/words5/<letter>.lua (the words a guess is checked against) and
userland/lib/words5/answers.lua (the hidden words: the common words listed in
tools/words5_answers.txt that the dictionary also has).
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "userland", "lib", "words5")
NOTICE = """-- Word list derived from SCOWL (http://wordlist.aspell.net) via the Hunspell
-- en_US dictionary. Copyright 2000-2018 by Kevin Atkinson.
-- Permission to use, copy, modify, distribute and sell these word lists, the
-- associated scripts, the output created from the scripts, and its
-- documentation for any purpose is hereby granted without fee, provided that
-- the above copyright notice appears in all copies and that both that
-- copyright notice and this permission notice appear in supporting
-- documentation. Kevin Atkinson makes no representations about the
-- suitability of this array for any purpose. It is provided "as is"
-- without express or implied warranty.
"""


def parse_aff(path):
    rules = {}  # flag -> (kind, cross, [(strip, add, cond_regex)])
    lines = open(path, encoding="utf-8", errors="ignore").read().split("\n")
    i = 0
    while i < len(lines):
        f = lines[i].split()
        if len(f) == 4 and f[0] in ("SFX", "PFX") and f[2] in ("Y", "N"):
            kind, flag, cross, n = f[0], f[1], f[2] == "Y", int(f[3])
            items = []
            for j in range(1, n + 1):
                g = lines[i + j].split()
                strip = "" if g[2] == "0" else g[2]
                add = "" if g[3] == "0" else g[3].split("/")[0]
                cond = g[4] if len(g) > 4 else "."
                rx = re.compile((cond + "$") if kind == "SFX" else ("^" + cond))
                items.append((strip, add, rx))
            rules[flag] = (kind, cross, items)
            i += n
        i += 1
    return rules


def forms(word, flags, rules):
    out = {word}
    sfx = []
    for fl in flags:
        r = rules.get(fl)
        if not r or r[0] != "SFX":
            continue
        for strip, add, rx in r[2]:
            if rx.search(word) and word.endswith(strip):
                w = word[: len(word) - len(strip)] + add
                out.add(w)
                if r[1]:
                    sfx.append(w)
    for fl in flags:
        r = rules.get(fl)
        if not r or r[0] != "PFX":
            continue
        for strip, add, rx in r[2]:
            for base in [word] + (sfx if r[1] else []):
                if rx.search(base) and base.startswith(strip):
                    out.add(add + base[len(strip):])
    return out


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    rules = parse_aff(sys.argv[2])
    valid = set()
    for line in open(sys.argv[1], encoding="utf-8", errors="ignore").read().split("\n")[1:]:
        word, _, flags = line.strip().partition("/")
        if not word or not word[0].islower():
            continue
        for w in forms(word, flags, rules):
            if re.fullmatch(r"[a-z]{5}", w):
                valid.add(w)
    wanted = open(os.path.join(ROOT, "tools", "words5_answers.txt")).read().split()
    answers = sorted({w for w in wanted if w in valid})
    missing = sorted({w for w in wanted if w not in valid})
    os.makedirs(OUT, exist_ok=True)
    for c in "abcdefghijklmnopqrstuvwxyz":
        ws = sorted(w for w in valid if w[0] == c)
        with open(os.path.join(OUT, c + ".lua"), "w") as f:
            f.write("-- Five-letter words starting with %s, five letters each, no spaces.\n" % c)
            f.write("-- Copyright 2000-2018 by Kevin Atkinson (SCOWL); see words5/answers.lua.\n")
            f.write('return "%s"\n' % "".join(ws))
    with open(os.path.join(OUT, "answers.lua"), "w") as f:
        f.write("-- Hidden words for Wordy: common five-letter words, five letters each.\n")
        f.write(NOTICE)
        f.write('return "%s"\n' % "".join(answers))
    print("%d valid words, %d answers" % (len(valid), len(answers)))
    if missing:
        print("not in the dictionary (left out):", " ".join(missing))


if __name__ == "__main__":
    main()
