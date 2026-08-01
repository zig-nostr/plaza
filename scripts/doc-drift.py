#!/usr/bin/env python3
"""Finds doc comments that have drifted off the declaration they describe.

In Zig a contiguous run of `///` binds to the NEXT declaration. Move a function
and leave its doc behind, or delete one, and the orphaned block silently joins
the doc of whatever follows: the reader then meets a function whose
documentation opens with a sentence about something else entirely. It has
happened ten times in `src/main.zig`, and nothing about it fails to compile.

The shape it leaves is a doc block with TWO opening summaries and no paragraph
break between them, because a real paragraph break in this file is a bare `///`
line. That is what this looks for.

It is a REPORTER, not a gate. Roughly half of what it prints is a legitimate
two-sentence doc, and every attempt to sharpen the rule enough for CI needed an
exception list that would go stale faster than the bug it was catching. Read the
output; the tell is a first sentence that describes a function you can find
elsewhere in the file, usually one that now has no doc of its own.

    python3 scripts/doc-drift.py [file...]
"""

import re
import sys

OPENERS = (
    "The ", "A ", "An ", "One ", "Wraps", "Builds", "Returns", "What ",
    "How ", "Where ", "Whether ", "Which ", "Why ", "Two ", "Three ", "Every ",
)


def blocks(lines):
    """Every `///` run in the file, with the declaration it binds to."""
    i = 0
    while i < len(lines):
        if not lines[i].lstrip().startswith("///"):
            i += 1
            continue
        start = i
        body = []
        while i < len(lines) and lines[i].lstrip().startswith("///"):
            body.append(lines[i].lstrip()[3:].rstrip())
            i += 1
        j = i
        while j < len(lines) and lines[j].strip() == "":
            j += 1
        decl = lines[j].strip() if j < len(lines) else ""
        name = re.search(r"\b(?:fn|const|var)\s+([A-Za-z_][A-Za-z0-9_]*)", decl)
        yield start + 1, (name.group(1) if name else decl[:40]), body


def suspect(body):
    """A second opening summary before the first paragraph break, or None."""
    for k in range(1, len(body)):
        previous, current = body[k - 1].strip(), body[k].strip()
        # A bare `///` is a deliberate paragraph break, so everything past one
        # is a continuation rather than a competing summary.
        if not previous or not current:
            return None
        if previous.endswith(".") and current.startswith(OPENERS):
            return current
    return None


def main(paths):
    found = 0
    for path in paths:
        with open(path, encoding="utf-8") as handle:
            lines = handle.read().split("\n")
        for line_no, name, body in blocks(lines):
            second = suspect(body)
            if second is None:
                continue
            found += 1
            first = next((b for b in body if b.strip()), "")
            print(f"{path}:{line_no}  {name}")
            print(f"    opens:  {first.strip()}")
            print(f"    and:    {second}")
    print(f"\n{found} block(s) with two opening summaries. Read each one: a doc")
    print("that names a DIFFERENT declaration has drifted; the rest are prose.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:] or ["src/main.zig"]))
