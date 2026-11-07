# Python mirror of the logic of v229-jimaku-safe (the Swift code cannot run outside Xcode): run it with
#   python3 ci/patches/v229-jimaku-safe-test.py
# It is not part of the workflow. Keep it in step with v229-jimaku-safe.swift and the pickFiles / isTrusted in the .py.
import re
from urllib.parse import urlparse

MAX_BYTES = 32 * 1024 * 1024


# ---- JimakuAss.filtered / isJapanese ----
def is_japanese(style):
    return re.search(r"(?:^|[^a-zA-Z])(?:jp|jpn|japanese)(?:$|[^a-zA-Z])|日本語", style, re.I) is not None


def filtered(lines):
    in_events, fields, events = False, [], []
    for index, line in enumerate(lines):
        trimmed = line.strip()
        if trimmed.startswith("["):
            in_events = trimmed.lower() == "[events]"
        if not in_events:
            continue
        lower = line.lower()
        if lower.startswith("format:"):
            fields = [f.strip().lower() for f in line[len("format:"):].split(",")]
        elif lower.startswith("dialogue:") and "style" in fields:
            values = line[len("dialogue:"):].split(",", len(fields) - 1)
            if len(values) != len(fields):
                continue
            events.append((index, values[fields.index("style")].strip()))
    japanese = {style for _, style in events if is_japanese(style)}
    if not japanese:
        return None
    remove = {index for index, style in events if style not in japanese}
    if not remove:
        return None
    return [line for index, line in enumerate(lines) if index not in remove]


def keep_japanese_styles(text):
    bom = text.startswith("﻿")
    if bom:
        text = text[1:]
    kept = filtered(text.split("\n"))
    if kept is None:
        return None
    return ("﻿" if bom else "") + "\n".join(kept)


# ---- JimakuService.isTrusted / pickFiles ----
def is_trusted(file):
    url = urlparse(file["url"])
    return url.scheme == "https" and (url.hostname or "").lower() == "jimaku.cc" and file["size"] <= MAX_BYTES


def ext(name):
    return name.rsplit(".", 1)[-1].lower() if "." in name else ""


def pick_files(files, release=None):
    subs = [f for f in files if ext(f["name"]) in ("srt", "ass", "ssa", "vtt") and is_trusted(f)]

    def score(f):
        s = 0
        if ext(f["name"]) in ("ass", "ssa"):
            s += 3
        if release and release in f["name"].upper():
            s += 2
        if re.search(r"\b(ENG|CHS|CHT|CHI)\b", f["name"], re.I):
            s -= 5
        return s

    return sorted(subs, key=lambda f: (-score(f), f["name"].casefold()))[:5]


def file(name, size=1000, url=None):
    return {"name": name, "size": size, "url": url or "https://jimaku.cc/entry/1/" + name}


ASS = "[Script Info]\nTitle: x\n\n[V4+ Styles]\nFormat: Name, Fontname\nStyle: JP,Arial\nStyle: EN,Arial\n\n[Events]\n" \
      "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n" \
      "Dialogue: 0,0:00:01.00,0:00:02.00,JP,,0,0,0,,こんにちは、世界\n" \
      "Dialogue: 0,0:00:01.00,0:00:02.00,EN,,0,0,0,,Hello, world\n" \
      "Dialogue: 0,0:00:03.00,0:00:04.00,Default-jpn,,0,0,0,,二行目\n"

# bilingual: the English line goes, both Japanese styles stay, the commas of the text are kept
out = keep_japanese_styles(ASS)
assert out is not None and "Hello, world" not in out and "こんにちは、世界" in out and "二行目" in out
assert out.count("Dialogue:") == 2 and "Style: EN,Arial" in out  # the style definitions are not touched
# CRLF files and a BOM
crlf = keep_japanese_styles("﻿" + ASS.replace("\n", "\r\n"))
assert crlf is not None and crlf.startswith("﻿") and "Hello, world" not in crlf and "\r\n" in crlf
# no explicitly Japanese style: untouched, even when the text is kanji
assert keep_japanese_styles(ASS.replace(",JP,", ",Main,").replace("Default-jpn", "Sub")) is None
# only Japanese styles: nothing to remove
assert keep_japanese_styles(ASS.replace(",EN,", ",JP,")) is None
# names that merely contain the letters are not Japanese
for style in ("Jpnx", "Japanesee", "enjp3"[:0] + "xjp", "Spanish"):
    assert not is_japanese(style), style
for style in ("JP", "jpn", "Default-jpn", "Japanese Main", "ja jp 2", "日本語", "Sign_JP_top"):
    assert is_japanese(style), style
# a file without the Style field in its Format is left alone
assert keep_japanese_styles("[Events]\nFormat: Start, End, Text\nDialogue: 0:00:01.00,0:00:02.00,JP,hi\n") is None

# ---- the choice of the files ----
files = [file("ep03 WEB.srt"), file("ep03 BD.ass"), file("ep03 ENG.ass"), file("ep03 WEB.ass"), file("ep03.zip"),
         file("ep03 BD.srt"), file("ep03 sup.sup"), file("evil.ass", url="https://evil.example/ep03.ass"),
         file("http.ass", url="http://jimaku.cc/ep03.ass"), file("host.ass", url="https://jimaku.cc.evil.example/x.ass"),
         file("big.ass", size=MAX_BYTES + 1)]
picked = [f["name"] for f in pick_files(files, "BD")]
assert picked == ["ep03 BD.ass", "ep03 WEB.ass", "ep03 BD.srt", "ep03 WEB.srt", "ep03 ENG.ass"], picked
# the same result whatever the order of the list
assert [f["name"] for f in pick_files(list(reversed(files)), "BD")] == picked
# the host check: userinfo tricks and the wrong scheme
assert not is_trusted(file("a.ass", url="https://jimaku.cc@evil.example/a.ass"))
assert not is_trusted(file("a.ass", url="ftp://jimaku.cc/a.ass"))
assert is_trusted(file("a.ass", url="https://jimaku.cc/entry/1/a.ass"))
assert is_trusted(file("a.ass", size=MAX_BYTES)) and not is_trusted(file("a.ass", size=MAX_BYTES + 1))
print("ok")
