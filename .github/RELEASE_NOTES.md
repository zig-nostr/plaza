**Plaza** is a fast, local-first Nostr client, built natively in Zig. macOS (Apple Silicon), **ad-hoc signed (not notarized)**.

### What's new in v0.2.3

- **Settings and the composer are full screens, not sheets.** A sheet is a translucent layer over the whole window, so every frame of scrolling or typing in one repainted the entire window and it got worse the wider the window was. On a 1600x1000 window a frame cost 183ms as a sheet and 8ms as a page. The composer was worst when nobody was touching it: a blinking caret was repainting the window twice a second.
- **The composer has a proper top bar**, the same band settings wears: Cancel, the title, and Post.
- Escape no longer closes these two. Both keep Cancel and Close, and the keystroke comes back once there is a global handler for it.

### Install

```sh
curl -fsSL https://raw.githubusercontent.com/zig-nostr/plaza/main/scripts/install-macos.sh | bash
```

The installer downloads this release, verifies its SHA-256, installs `Plaza.app` to `/Applications`, clears the download-quarantine flag, and opens it.

It touches the app bundle and nothing else. Your key, your session and your local store live in `~/.plaza` and are left alone, so upgrading never costs you your identity.

### Why it is not notarized

Plaza signs notes with your key. The trust anchor for that is a build you can reproduce from source, not an Apple signature you cannot inspect. Read the [installer](https://github.com/zig-nostr/plaza/blob/main/scripts/install-macos.sh), or skip it and [build from source](https://github.com/zig-nostr/plaza#build): the same `scripts/package-macos.sh` that produced this artifact runs on your machine.

If you would rather not connect a key at all, Plaza reads without one, and every gated verb asks at the moment you reach for it.
