#!/usr/bin/env python3
"""Builds the face Plaza draws with where there is no system text layer.

Off macOS the toolkit inks every glyph itself, from ONE face, with no fallback
to a second one and no codepoint above U+FFFF (it returns glyph 0 before it
looks at the font). A glyph it cannot find is painted as a solid filled
rectangle, so a note with an emoji in it comes out with bars through it.

So the emoji have to be inside the same face as the text, and they have to live
below U+FFFF. This merges monochrome Noto Emoji into Geist and parks every
emoji in the Private Use Area, which is BMP and therefore reachable.

Run it from the repo root:

    python3 scripts/build-emoji-font.py

Needs `fonttools` (pip install fonttools). It writes two files, both committed:

    src/fonts/Geist-Emoji.ttf   the merged face
    src/emoji_pua.zig           the codepoint table Plaza substitutes with

Deterministic: emoji are assigned PUA slots in sorted codepoint order, so the
same inputs always produce the same outputs and the diff is empty when nothing
changed.
"""

import hashlib
import os
import subprocess
import sys
import tempfile

# Pinned. A font that changed under us would silently renumber every PUA slot
# and leave the generated table pointing at the wrong pictures.
NOTO_URL = "https://github.com/google/fonts/raw/main/ofl/notoemoji/NotoEmoji%5Bwght%5D.ttf"
NOTO_SHA256 = "de6c18832938afc99caf132b39d6a30a19bac7f2e812e28db2535b4608d27551"

PUA_FIRST = 0xE000
PUA_LAST = 0xF8FF

# The tables the toolkit's parser reads, and nothing else. Merging is far more
# likely to fail on a table neither font needs (`STAT`, `vhea`, `DSIG`) than on
# one it does.
KEEP = {"cmap", "glyf", "head", "hhea", "hmtx", "loca", "maxp", "name", "post", "OS/2", "GlyphOrder"}


# Codepoints that must keep drawing as TEXT, whatever the emoji font thinks.
#
# Noto Emoji maps far more than pictures. It carries the keycap bases (the
# digits, `#`, `*`), the zero-width joiner, the variation selectors and the skin
# tone modifiers, and it maps NUL and carriage return. Substituting any of those
# would replace a newline, a digit or an invisible joiner with a picture, so the
# filter is deliberately conservative: below U+2000 is the text face's, and
# anything Geist already draws stays Geist's.
JOINERS = {0x200D, 0xFE0E, 0xFE0F, 0x20E3}
SKIN_TONES = range(0x1F3FB, 0x1F400)

# The toolkit's outline budgets (canvas.font_ttf). Registration reads `maxp`,
# which declares the MAXIMUM over the whole face, so a single glyph past the
# budget refuses the entire font rather than degrading that one picture. Three
# of Noto Emoji's most detailed glyphs are over it, and keeping them costs every
# other emoji in the file.
MAX_POINTS = 1024
MAX_CONTOURS = 128


def within_budget(glyf, name):
    """Points and contours after composites are flattened, as the toolkit counts them."""
    try:
        coords, end_points, _ = glyf[name].getCoordinates(glyf)
    except Exception:
        return False
    return len(coords) <= MAX_POINTS and len(end_points) <= MAX_CONTOURS


def substitutable(cp, geist_cmap):
    if cp < 0x2000:
        return False
    if cp in JOINERS or cp in SKIN_TONES:
        return False
    # The text face wins wherever it has an opinion, so a merged build never
    # turns a letter or a piece of punctuation into a pictograph.
    return cp not in geist_cmap


def die(msg):
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(1)


def fetch(url, dest):
    subprocess.run(["curl", "-sSL", "-o", dest, url], check=True)
    return hashlib.sha256(open(dest, "rb").read()).hexdigest()


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    geist = os.path.join(root, "src", "fonts", "Geist-Regular.ttf")
    if not os.path.exists(geist):
        die(f"{geist} is missing")

    try:
        from fontTools.ttLib import TTFont
        from fontTools.varLib import instancer
        from fontTools.ttLib.scaleUpem import scale_upem
        from fontTools.ttLib.tables._c_m_a_p import CmapSubtable
        from fontTools.merge import Merger
    except ImportError:
        die("fonttools is not installed: pip install fonttools")

    work = tempfile.mkdtemp(prefix="plaza-font-")
    noto = os.path.join(work, "NotoEmoji.ttf")
    got = fetch(NOTO_URL, noto)
    if NOTO_SHA256 and got != NOTO_SHA256:
        die(f"Noto Emoji changed upstream: expected {NOTO_SHA256}, got {got}")
    print(f"noto emoji sha256 {got}")

    # A variable font has no static outlines to copy, so pin the weight first,
    # then scale: Noto draws on a 2048 em and Geist on 1000, and merging without
    # scaling would ink every emoji at twice its size.
    f = TTFont(noto)
    instancer.instantiateVariableFont(f, {"wght": 400}, inplace=True, updateFontNames=False)
    scale_upem(f, TTFont(geist)["head"].unitsPerEm)

    geist_cmap = set(TTFont(geist).getBestCmap().keys())
    glyf = f["glyf"]
    emoji = sorted(
        (cp, g)
        for cp, g in f.getBestCmap().items()
        if substitutable(cp, geist_cmap) and within_budget(glyf, g)
    )
    dropped = sum(
        1
        for cp, g in f.getBestCmap().items()
        if substitutable(cp, geist_cmap) and not within_budget(glyf, g)
    )
    if dropped:
        print(f"dropped {dropped} emoji whose outlines are past the toolkit's budget")
    if not emoji:
        die("the emoji font has no cmap")
    if PUA_FIRST + len(emoji) - 1 > PUA_LAST:
        die(f"{len(emoji)} emoji do not fit in the private use area")

    # Subset BEFORE remapping. Dropping a codepoint from the cmap leaves its
    # outline in `glyf`, and `maxp` declares the maximum over every glyph in the
    # file, so the face would still be refused for a picture nothing can reach.
    # Subsetting removes the glyphs outright and recomputes `maxp`.
    from fontTools import subset

    keep = [cp for cp, _ in emoji]
    subsetter = subset.Subsetter(options=subset.Options(notdef_outline=True, glyph_names=True))
    subsetter.populate(unicodes=keep)
    subsetter.subset(f)

    # The glyph names may have moved, so the mapping is rebuilt from the subset
    # rather than carried over from before it.
    after = f.getBestCmap()
    emoji = sorted((cp, after[cp]) for cp in keep if cp in after)

    pua = {}
    remapped = {}
    for i, (cp, gname) in enumerate(emoji):
        slot = PUA_FIRST + i
        remapped[slot] = gname
        pua[cp] = slot

    subs = []
    for platform, encoding in ((3, 1), (0, 3)):
        sub = CmapSubtable.newSubtable(4)
        sub.platformID, sub.platEncID, sub.language = platform, encoding, 0
        sub.cmap = remapped
        subs.append(sub)
    f["cmap"].tables = subs

    trimmed = []
    for src in (geist, os.path.join(work, "emoji-pua.ttf")):
        if src.endswith("emoji-pua.ttf"):
            f.save(src)
        t = TTFont(src)
        for tag in [tag for tag in t.keys() if tag not in KEEP]:
            del t[tag]
        out = os.path.join(work, os.path.basename(src) + ".min.ttf")
        t.save(out)
        trimmed.append(out)

    merged = Merger().merge(trimmed)
    out_ttf = os.path.join(root, "src", "fonts", "Geist-Emoji.ttf")
    merged.save(out_ttf)
    size = os.path.getsize(out_ttf)
    print(f"wrote {out_ttf} ({size} bytes, {len(pua)} emoji)")

    # The table Plaza substitutes with. Sorted, so the lookup is a binary search
    # and the PUA slot is the INDEX plus the base: no pairs to store, and no way
    # for the two halves to disagree.
    lines = [
        "//! Generated by `scripts/build-emoji-font.py`. Do not edit by hand.",
        "//!",
        "//! Every emoji `Geist-Emoji.ttf` carries, in the order its private-use",
        "//! slots were assigned. A codepoint at index `i` draws with the glyph at",
        "//! `pua_first + i`, which is how a picture above U+FFFF reaches a",
        "//! renderer that refuses to look past it.",
        "",
        f"pub const pua_first: u21 = 0x{PUA_FIRST:04X};",
        "",
        "pub const sources = [_]u21{",
    ]
    for cp, _ in emoji:
        lines.append(f"    0x{cp:04X},")
    lines.append("};")
    lines.append("")
    out_zig = os.path.join(root, "src", "emoji_pua.zig")
    with open(out_zig, "w") as fh:
        fh.write("\n".join(lines))
    print(f"wrote {out_zig} ({len(emoji)} entries)")


if __name__ == "__main__":
    main()
