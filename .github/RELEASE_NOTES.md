**Plaza** is a fast, local-first Nostr client, built natively in Zig. macOS (Apple Silicon), **ad-hoc signed (not notarized)**.

### What's new in v0.13.0

**Your key is no longer in Plaza.** Not hidden, not encrypted, not held carefully: absent. There is no longer anywhere in this app that a secret key can be put.

Plaza used to make one and keep it at `~/.plaza/identity.key`, readable only by you. That sounds protective and is not: file permissions separate *users*, not *apps*, and every app you run is you. Any of them could read that file. A Nostr identity is the one thing that cannot be replaced once it leaks.

So Plaza ships **Notary**, starts it as its own process, and asks it to sign. The two talk over a channel with no name, no path and no port — nothing else on your Mac can reach it, and nothing has to guess who is asking, because only the app that opened the channel is holding it.

**Bringing a key opens Notary.** Pasting one into Plaza is refused, and the field says where it goes instead. That is the point rather than a limitation: an app that accepts your key is an app holding the one thing you cannot replace.

**Signing out leaves your key in Notary.** It used to delete it. Leaving a client and taking your identity off your Mac are different things, and one press in one app should not do the second. To remove a key from this machine, open Notary.

**A signer that is locked now says so.** Plaza read a locked Notary as an empty one and offered to create a key over the top of the one you already had. Nothing was lost, because Notary refuses that, but you got an error instead of the passphrase box that would have worked.

**Plaza no longer signs for other apps.** Notary does, in its own window, with its own approval list and its own way to revoke. Nothing is lost; it moved to the app that holds the key.

**Fixed along the way.** Pictures on `.pub` hosts never loaded. The time-and-via line on each post stopped sitting against the right edge. A note could be reported as failed and then published anyway, seconds later, when a signature arrived after Plaza had given up on it.

### Install

```sh
curl -fsSL https://raw.githubusercontent.com/zig-nostr/plaza/main/scripts/install-macos.sh | bash
```

The installer downloads this release, verifies its SHA-256, installs `Plaza.app` to `/Applications`, clears the download-quarantine flag, and opens it.

It touches the app bundle and nothing else. Your session and your local store live in `~/.plaza`, your key stays in Notary, and both are left alone, so upgrading never costs you your identity.

### Why it is not notarized

Plaza signs notes with your key. The trust anchor for that is a build you can reproduce from source, not an Apple signature you cannot inspect. Read the [installer](https://github.com/zig-nostr/plaza/blob/main/scripts/install-macos.sh), or skip it and [build from source](https://github.com/zig-nostr/plaza#build): the same `scripts/package-macos.sh` that produced this artifact runs on your machine.

If you would rather not connect a key at all, Plaza reads without one, and every gated verb asks at the moment you reach for it.
