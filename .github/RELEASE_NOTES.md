**Plaza** is a fast, local-first Nostr client, built natively in Zig. macOS (Apple Silicon), **ad-hoc signed (not notarized)**.

### What's new in v0.10.0

**The signer stays on.** Turning Plaza into a signer for your other apps did not survive quitting it, and the toggle switching itself off was the smaller half of that. Plaza also handed out a new connect secret each launch, which meant the link you had already pasted into another app quietly stopped working. From that app's side it does not look like Plaza forgot anything, it looks like the connection broke.

Now it stays as you left it: on if it was on, with the same link. The link survives being switched off and on again, so you never have to go and re-paste it. Removing your key removes the link with it, because the next key set up on this Mac must not inherit one that other apps are already holding.

**Faces and profile banners show up now too.** The last release fixed photos in the feed that were too large to arrive in one piece. Profile pictures and banners had the same problem and were still landing on the old path, so somebody whose picture was a full-size photo showed up as initials, and their banner as a flat colour band. All three now arrive the same way.

### Install

```sh
curl -fsSL https://raw.githubusercontent.com/zig-nostr/plaza/main/scripts/install-macos.sh | bash
```

The installer downloads this release, verifies its SHA-256, installs `Plaza.app` to `/Applications`, clears the download-quarantine flag, and opens it.

It touches the app bundle and nothing else. Your key, your session and your local store live in `~/.plaza` and are left alone, so upgrading never costs you your identity.

### Why it is not notarized

Plaza signs notes with your key. The trust anchor for that is a build you can reproduce from source, not an Apple signature you cannot inspect. Read the [installer](https://github.com/zig-nostr/plaza/blob/main/scripts/install-macos.sh), or skip it and [build from source](https://github.com/zig-nostr/plaza#build): the same `scripts/package-macos.sh` that produced this artifact runs on your machine.

If you would rather not connect a key at all, Plaza reads without one, and every gated verb asks at the moment you reach for it.
