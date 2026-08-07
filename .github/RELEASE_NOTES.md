**Plaza** is a fast, local-first Nostr client, built natively in Zig. macOS (Apple Silicon), **ad-hoc signed (not notarized)**.

### What's new in v0.2.2

- **The composer stops cutting notes in half.** It held 512 characters and said "no length limit", so a longer note came back cut mid-sentence with nothing admitting it. It holds 4096 now, and tells you how much room is left once a quarter of it is gone.
- **Sheets scroll properly.** Settings, the composer, notifications and the join screen were rebuilding the whole feed behind them on every frame of scrolling. Settings went from 6806us to 1179us of layout per frame on a full store.
- **Plaza has its own icon.** An open square with four quadrants around it, which is what a plaza is. It shipped with a placeholder until v0.2.1.

### Install

```sh
curl -fsSL https://raw.githubusercontent.com/zig-nostr/plaza/main/scripts/install-macos.sh | bash
```

The installer downloads this release, verifies its SHA-256, installs `Plaza.app` to `/Applications`, clears the download-quarantine flag, and opens it.

It touches the app bundle and nothing else. Your key, your session and your local store live in `~/.plaza` and are left alone, so upgrading never costs you your identity.

### Why it is not notarized

Plaza signs notes with your key. The trust anchor for that is a build you can reproduce from source, not an Apple signature you cannot inspect. Read the [installer](https://github.com/zig-nostr/plaza/blob/main/scripts/install-macos.sh), or skip it and [build from source](https://github.com/zig-nostr/plaza#build): the same `scripts/package-macos.sh` that produced this artifact runs on your machine.

If you would rather not connect a key at all, Plaza reads without one, and every gated verb asks at the moment you reach for it.
