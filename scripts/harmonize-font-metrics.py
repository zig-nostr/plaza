#!/usr/bin/env python3
"""Give every bundled Geist face the same vertical metrics.

Why this exists, in one paragraph. The macOS host draws a text run with
`[NSString drawAtPoint:NSMakePoint(x, baseline - size)]` into a flipped
context, and AppKit then places the baseline `round(font.ascender)` below
that point. Subtracting the point SIZE therefore asserts "ascent == size",
which is a per-FACE quantity. Our four faces did not agree: Geist-Regular
ships 920/-220/100 and Geist-Medium, Geist-Bold and GeistMono-Regular ship
1005/-295/0, so at a 14.5pt body every medium, bold and mono run landed
exactly 2pt BELOW the regular text on its own line. Mentions, the reply
context label, bold names beside regular meta: all of them sat low.

The engine cannot see it. The host exports width measurement and nothing
else, so there is no ascent to consult on the Zig side, and the display
list is provably correct: same origin.y, same size, one baseline.

So the faces are made to agree instead, and they agree on REGULAR's
numbers rather than the other way round. Moving the majority would push
every line 2pt down inside a box the engine already sized, which is a
descender against the floor of every tight row; moving the three outliers
up changes only the runs that are currently wrong.

Reproducible on purpose: run it again after any font update. It reports
"already agrees" for a face that needs nothing, and `zig build test` fails
if the four faces ever drift apart again.
"""

import struct
import sys
from pathlib import Path

FONTS = Path(__file__).resolve().parent.parent / "src" / "fonts"
SOURCE = "Geist-Regular.ttf"
TARGETS = ["Geist-Medium.ttf", "Geist-Bold.ttf", "GeistMono-Regular.ttf"]


def tables(data):
    (num,) = struct.unpack_from(">H", data, 4)
    out = {}
    for i in range(num):
        off = 12 + i * 16
        tag, checksum, start, length = struct.unpack_from(">4sIII", data, off)
        out[tag.decode("latin1")] = (off, start, length)
    return out


def vertical_metrics(data):
    t = tables(data)
    _, hhea, _ = t["hhea"]
    asc, desc, gap = struct.unpack_from(">hhh", data, hhea + 4)
    _, os2, _ = t["OS/2"]
    tasc, tdesc, tgap, wasc, wdesc = struct.unpack_from(">hhhHH", data, os2 + 68)
    return {
        "hhea": (asc, desc, gap),
        "typo": (tasc, tdesc, tgap),
        "win": (wasc, wdesc),
    }


def table_checksum(data, start, length):
    total = 0
    padded = data[start : start + length] + b"\0" * (-length % 4)
    for (word,) in struct.iter_unpack(">I", padded):
        total = (total + word) & 0xFFFFFFFF
    return total


def rewrite(data, want):
    buf = bytearray(data)
    t = tables(buf)

    _, hhea, _ = t["hhea"]
    struct.pack_into(">hhh", buf, hhea + 4, *want["hhea"])
    _, os2, _ = t["OS/2"]
    struct.pack_into(">hhh", buf, os2 + 68, *want["typo"])
    struct.pack_into(">HH", buf, os2 + 74, *want["win"])

    # Every table's checksum, then the file's, or a strict consumer refuses
    # the font outright. `head.checkSumAdjustment` is computed over the whole
    # file with its own field zeroed, which is why it is done last.
    _, head, _ = t["head"]
    struct.pack_into(">I", buf, head + 8, 0)
    for tag, (entry, start, length) in t.items():
        struct.pack_into(">I", buf, entry + 4, table_checksum(buf, start, length))
    whole = 0
    padded = bytes(buf) + b"\0" * (-len(buf) % 4)
    for (word,) in struct.iter_unpack(">I", padded):
        whole = (whole + word) & 0xFFFFFFFF
    struct.pack_into(">I", buf, head + 8, (0xB1B0AFBA - whole) & 0xFFFFFFFF)
    return bytes(buf)


def main():
    source = (FONTS / SOURCE).read_bytes()
    want = vertical_metrics(source)
    print(f"{SOURCE:<24} hhea={want['hhea']} typo={want['typo']} win={want['win']}  (the target)")

    changed = 0
    for name in TARGETS:
        path = FONTS / name
        data = path.read_bytes()
        had = vertical_metrics(data)
        if had == want:
            print(f"{name:<24} already agrees")
            continue
        out = rewrite(data, want)
        got = vertical_metrics(out)
        if got != want:
            print(f"{name:<24} REWRITE FAILED: {got}", file=sys.stderr)
            return 1
        if len(out) != len(data):
            print(f"{name:<24} SIZE CHANGED, refusing", file=sys.stderr)
            return 1
        path.write_bytes(out)
        print(f"{name:<24} hhea={had['hhea']} -> {want['hhea']}, typo={had['typo']} -> {want['typo']}, win={had['win']} -> {want['win']}")
        changed += 1

    print(f"\n{changed} face(s) changed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
