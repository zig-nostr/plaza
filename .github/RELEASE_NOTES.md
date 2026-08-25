**Plaza** is a fast, local-first Nostr client, built natively in Zig. macOS (Apple Silicon), **ad-hoc signed (not notarized)**.

### What's new in v0.12.3

**The sign-in sheet had a hole in it.** The sheet is a card centred in a dimmed window, and the box holding that card was 48 points wider than the card itself. The card takes presses so it does not close the sheet from under you, and the dim behind it closes the sheet, but that 48 point band did neither, and it sits in front of the dim. Clicking there did nothing at all except reach the feed underneath, so a click beside the sheet opened whatever picture happened to be behind it.

There is one width now, the wider of the two, so the sheet is a little roomier as well as solid. Clicking anywhere outside the card closes it and does nothing else.

**The sheet spaces itself properly.** Every gap in it used to be placed by hand, nine separate numbers that nobody could see next to each other, and the sheet ended up with 44 points of margin down its sides, 50 above the heading and 26 below the way out. It now uses one scale throughout and sits evenly inside its own edges, so the heading, the three ways in, and the way out are all where they should be.

### Install

```sh
curl -fsSL https://raw.githubusercontent.com/zig-nostr/plaza/main/scripts/install-macos.sh | bash
```

The installer downloads this release, verifies its SHA-256, installs `Plaza.app` to `/Applications`, clears the download-quarantine flag, and opens it.

It touches the app bundle and nothing else. Your session and your local store live in `~/.plaza`, your key in the login Keychain, and both are left alone, so upgrading never costs you your identity.

### Why it is not notarized

Plaza signs notes with your key. The trust anchor for that is a build you can reproduce from source, not an Apple signature you cannot inspect. Read the [installer](https://github.com/zig-nostr/plaza/blob/main/scripts/install-macos.sh), or skip it and [build from source](https://github.com/zig-nostr/plaza#build): the same `scripts/package-macos.sh` that produced this artifact runs on your machine.

If you would rather not connect a key at all, Plaza reads without one, and every gated verb asks at the moment you reach for it.
