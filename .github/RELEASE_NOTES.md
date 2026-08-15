**Plaza** is a fast, local-first Nostr client, built natively in Zig. macOS (Apple Silicon), **ad-hoc signed (not notarized)**.

### What's new in v0.7.0

**A note with several pictures draws them all.** Somebody posts three photos, which is what a phone's share sheet produces, and Plaza drew the first and left the other two underneath as raw URLs. It draws up to four now, as a row of cells, and no image link is left sitting in the text.

The pictures fill in as slots free up. There are sixteen image slots in the whole app and a gallery wants several at once, so the later cells of a busy screen borrow the note's own blurhash, which is drawn as flat colour rather than a registered image and so costs nothing. The row reads as photographs the whole time.

**Pictures that would not load, now load.** Some hosts came back as an empty frame saying so. The host was fine; the image proxy in front of it was refusing them by policy, and blossom servers were the common casualty. When the proxy refuses a host, Plaza now asks the host directly and the picture appears.

The proxy is still on by default, and still there for the reason it always was: without it, every image host in your feed learns your address as you scroll. The fallback fires only on a refusal, never on a host that is simply down, so a dead link does not turn into a second pointless request. Both are switches in Settings, with the privacy note beside them.

**Reactions, replies and zap totals appear with the feed.** They were arriving only for whichever relay happened to answer the note first, so a note usually showed nothing until you opened it and came back, and then the numbers were there. They are counted on every relay that carries the note now, so they are there the first time you look.

**Under it:** the check that decides whether your old key file may be deleted after moving into the Keychain is now tested against every way it can go wrong, rather than only read.

### Install

```sh
curl -fsSL https://raw.githubusercontent.com/zig-nostr/plaza/main/scripts/install-macos.sh | bash
```

The installer downloads this release, verifies its SHA-256, installs `Plaza.app` to `/Applications`, clears the download-quarantine flag, and opens it.

It touches the app bundle and nothing else. Your key, your session and your local store live in `~/.plaza` and are left alone, so upgrading never costs you your identity.

### Why it is not notarized

Plaza signs notes with your key. The trust anchor for that is a build you can reproduce from source, not an Apple signature you cannot inspect. Read the [installer](https://github.com/zig-nostr/plaza/blob/main/scripts/install-macos.sh), or skip it and [build from source](https://github.com/zig-nostr/plaza#build): the same `scripts/package-macos.sh` that produced this artifact runs on your machine.

If you would rather not connect a key at all, Plaza reads without one, and every gated verb asks at the moment you reach for it.
