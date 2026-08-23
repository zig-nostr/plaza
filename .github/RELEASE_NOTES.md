**Plaza** is a fast, local-first Nostr client, built natively in Zig. macOS (Apple Silicon), **ad-hoc signed (not notarized)**.

### What's new in v0.12.1

**Logging out takes your places with you.** The list of places you have entered is a file on your own disk, which is what keeps it private, and it is also why it outlived the account: a list kept on a relay goes when your key does, and a file sits there until something deletes it. So logging out left the rail exactly as it was, and the next person to sign in on that Mac opened straight into whichever place the last one had been reading. Logout already cleared the follows, the mutes, the drafts and everything else that belongs to an account rather than to a machine. Places are newer than that and were never added to it.

**Nothing you paste disappears without being told.** Paste a note longer than the composer holds and the overflow was simply gone, cut mid-word, with the counter reading "0 left" as though you had filled it exactly. On a six thousand character paste that is nearly two thousand characters of your own writing, thrown away in silence. It now says how much did not fit.

**The starter pack names the right people.** Three of the nine accounts a new install follows were labelled with somebody else's name. The keys were always right, so nobody has been following anyone they should not have been, but the app was telling newcomers the wrong thing about who they were reading, and saying it about real people. Every one of the nine is now checked against its owner's own domain.

**The feed stops giving up on history.** Scrolling to the bottom asks the relays for older notes, and if that attempt came back empty the feed decided there was nothing older and never asked again. It could not tell "every relay says that is all of it" from "nothing answered", so one attempt made offline ended your feed until you restarted the app. It now waits to be told.

### Install

```sh
curl -fsSL https://raw.githubusercontent.com/zig-nostr/plaza/main/scripts/install-macos.sh | bash
```

The installer downloads this release, verifies its SHA-256, installs `Plaza.app` to `/Applications`, clears the download-quarantine flag, and opens it.

It touches the app bundle and nothing else. Your key, your session and your local store live in `~/.plaza` and are left alone, so upgrading never costs you your identity.

### Why it is not notarized

Plaza signs notes with your key. The trust anchor for that is a build you can reproduce from source, not an Apple signature you cannot inspect. Read the [installer](https://github.com/zig-nostr/plaza/blob/main/scripts/install-macos.sh), or skip it and [build from source](https://github.com/zig-nostr/plaza#build): the same `scripts/package-macos.sh` that produced this artifact runs on your machine.

If you would rather not connect a key at all, Plaza reads without one, and every gated verb asks at the moment you reach for it.
