**Plaza** is a fast, local-first Nostr client, built natively in Zig. macOS (Apple Silicon), **ad-hoc signed (not notarized)**.

### What's new in v0.11.0

**Some of the people you follow were invisible, and now they are not.** Plaza works out where each person you follow publishes, and connects there, so you see them even when they are nowhere near your own relays. That has been true since v0.4.0 with one gap nobody could see: to find out where somebody publishes, Plaza has to read a small note they signed saying so, and it only ever looked for that note on relays it was already connected to.

If yours were not among them, that person stayed missing. Not with an error, not with an empty space, just absent, exactly the thing the whole feature exists to prevent.

Plaza now asks four well-known relays that one question, and only about the people it has no answer for. They are asked and nothing more: never joined, never published as yours, and never counted among your relays.

Whether you notice depends on who you follow. On an account whose relays already cover its follows there is nothing to fix and you will see no difference. On a fresh install it found relay lists for every single account it could not previously place.

### Install

```sh
curl -fsSL https://raw.githubusercontent.com/zig-nostr/plaza/main/scripts/install-macos.sh | bash
```

The installer downloads this release, verifies its SHA-256, installs `Plaza.app` to `/Applications`, clears the download-quarantine flag, and opens it.

It touches the app bundle and nothing else. Your key, your session and your local store live in `~/.plaza` and are left alone, so upgrading never costs you your identity.

### Why it is not notarized

Plaza signs notes with your key. The trust anchor for that is a build you can reproduce from source, not an Apple signature you cannot inspect. Read the [installer](https://github.com/zig-nostr/plaza/blob/main/scripts/install-macos.sh), or skip it and [build from source](https://github.com/zig-nostr/plaza#build): the same `scripts/package-macos.sh` that produced this artifact runs on your machine.

If you would rather not connect a key at all, Plaza reads without one, and every gated verb asks at the moment you reach for it.
