**Plaza** is a fast, local-first Nostr client, built natively in Zig. macOS (Apple Silicon), **ad-hoc signed (not notarized)**.

### What's new in v0.9.0

**Photos show up now.** A whole class of pictures never appeared in the feed: a blank cell, or a blurred placeholder that never resolved. It was not the picture, and it was not the host. Plaza could only take a picture that arrived in one piece under 240 KB, and an ordinary phone photo is several times that. Every photo in the notes I was staring at was between 313 KB and 612 KB.

It had been hidden by the image proxy, which hands back a shrunken copy. The proxy refuses some hosts outright, and the ones it refuses are exactly where a lot of Nostr photos live, so those notes fell through to a direct download and hit the limit. Plaza now asks for a big picture in pieces and puts it back together, so the size of the file stopped being the thing that decides whether you see it.

**More pictures on screen at once.** There are sixteen slots for every image in the app, and they were carved up in advance: nine for faces, one for a profile banner, six for photos. A feed with two four-picture notes in it needs seven, so the seventh cell could never hold anything no matter how much of the rest sat idle.

There is no carve-up now. Faces, photos and banners draw from the same sixteen, and what gets a slot is whatever has been on your screen most recently. A page of photos can use nearly all of them; a profile page full of faces can too. Whichever you are looking at is the one that gets the room.

### Install

```sh
curl -fsSL https://raw.githubusercontent.com/zig-nostr/plaza/main/scripts/install-macos.sh | bash
```

The installer downloads this release, verifies its SHA-256, installs `Plaza.app` to `/Applications`, clears the download-quarantine flag, and opens it.

It touches the app bundle and nothing else. Your key, your session and your local store live in `~/.plaza` and are left alone, so upgrading never costs you your identity.

### Why it is not notarized

Plaza signs notes with your key. The trust anchor for that is a build you can reproduce from source, not an Apple signature you cannot inspect. Read the [installer](https://github.com/zig-nostr/plaza/blob/main/scripts/install-macos.sh), or skip it and [build from source](https://github.com/zig-nostr/plaza#build): the same `scripts/package-macos.sh` that produced this artifact runs on your machine.

If you would rather not connect a key at all, Plaza reads without one, and every gated verb asks at the moment you reach for it.
