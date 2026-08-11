**Plaza** is a fast, local-first Nostr client, built natively in Zig. macOS (Apple Silicon), **ad-hoc signed (not notarized)**.

### What's new in v0.3.0

**Your feed reaches people your relays do not carry.** Plaza reads where the people you follow actually write. It works out which relays your follows publish to, ranks them by how many of them use each one, and connects to the busiest few you are not already on, asking each only about the people who write there. Before this, a follow who posts only to relays you are not on was invisible: no error, no empty state, they simply were not in your feed.

**The feed stops re-reading itself.** It used to ask the database for the whole timeline once a second, whether or not anything had changed. Now the connections say what arrived and the feed merges it. Measured at two thousand follows, in the build that ships: **3493 microseconds every second, down to 85**.

**A relay that stops answering is noticed.** A connection that dies without closing used to sit behind a green dot forever, delivering nothing. Plaza now sends a keepalive after thirty seconds of silence and drops the connection after ninety, and relays have a third state, `quiet`, for a socket that is open but has not spoken lately. Honest beats green.

**Nothing waits forever.** Every background fetch has a deadline, and the ones that run while you scroll (names, avatars, quoted notes) now ride the connections Plaza already has open instead of dialling their own.

Also: relay suggestions are ranked by how many of your follows use each one, rather than by whichever relay list happened to arrive first.

### Under it

The `nostr` library went from v0.3.8 to v0.8.0 with this release: faster store queries, websocket keepalive, and a stricter signer. Plaza's sibling [Notary](https://github.com/zig-nostr/notary) picked up the same keepalive.

### Install

```sh
curl -fsSL https://raw.githubusercontent.com/zig-nostr/plaza/main/scripts/install-macos.sh | bash
```

The installer downloads this release, verifies its SHA-256, installs `Plaza.app` to `/Applications`, clears the download-quarantine flag, and opens it.

It touches the app bundle and nothing else. Your key, your session and your local store live in `~/.plaza` and are left alone, so upgrading never costs you your identity.

### Why it is not notarized

Plaza signs notes with your key. The trust anchor for that is a build you can reproduce from source, not an Apple signature you cannot inspect. Read the [installer](https://github.com/zig-nostr/plaza/blob/main/scripts/install-macos.sh), or skip it and [build from source](https://github.com/zig-nostr/plaza#build): the same `scripts/package-macos.sh` that produced this artifact runs on your machine.

If you would rather not connect a key at all, Plaza reads without one, and every gated verb asks at the moment you reach for it.
