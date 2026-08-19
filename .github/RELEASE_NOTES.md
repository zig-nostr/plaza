**Plaza** is a fast, local-first Nostr client, built natively in Zig. macOS (Apple Silicon), **ad-hoc signed (not notarized)**.

### What's new in v0.12.0

**Places.** A place is somebody's corner of nostr: their relays, their people. Open one with a link and you are reading that place, not your own feed with a banner on top. Walk in, look around, and leave, and nothing has changed about your account.

Following a `plaza://place/...` link opens the place it names, from anywhere, including from a browser and from a cold start. You arrive as a visitor, which means you can already read and post, and closing the app forgets you were ever there. If you want to keep it, Enter puts it on a rail down the side of the window, and from then on it is one press away. Leaving takes it off again, and the link still works if you change your mind.

Entering gates nothing at all, posting included. Whether a post lands is between you and that place's relays: if they turn it away, that is theirs to say, not a wall this app invents. And the list of places you have entered is a file on your own disk, not something published anywhere, because which communities somebody belongs to is nobody else's business.

Switching between them is the point, so there are keys for it: `Cmd+Option+S` shows the rail, `Cmd+Option+Up` and `Down` walk your places, and `Cmd+Option+Right` steps out of a place and back into it.

The format is fiatjaf's, exactly. Anyone who has deployed a site with Hallway has already written one of these, and the same document means the same thing in both.

**Text sits where it should now.** Every mention, every bold name, every timestamp in the app was drawing two points below the line it belonged to. It is the sort of thing you feel before you can point at it, and it turned out to be the four bundled fonts disagreeing about where their own baselines are.

### Install

```sh
curl -fsSL https://raw.githubusercontent.com/zig-nostr/plaza/main/scripts/install-macos.sh | bash
```

The installer downloads this release, verifies its SHA-256, installs `Plaza.app` to `/Applications`, clears the download-quarantine flag, and opens it.

It touches the app bundle and nothing else. Your key, your session and your local store live in `~/.plaza` and are left alone, so upgrading never costs you your identity.

### Why it is not notarized

Plaza signs notes with your key. The trust anchor for that is a build you can reproduce from source, not an Apple signature you cannot inspect. Read the [installer](https://github.com/zig-nostr/plaza/blob/main/scripts/install-macos.sh), or skip it and [build from source](https://github.com/zig-nostr/plaza#build): the same `scripts/package-macos.sh` that produced this artifact runs on your machine.

If you would rather not connect a key at all, Plaza reads without one, and every gated verb asks at the moment you reach for it.
