**Plaza** is a fast, local-first Nostr client, built natively in Zig. macOS (Apple Silicon), **ad-hoc signed (not notarized)**.

### What's new in v0.4.1

**A relay that will not have you no longer keeps a connection to itself.** v0.4.0 picks the relays it connects to by how many of the people you follow write there. That says which relays carry them; it does not say which will talk to you, and those are not the same set. A paid relay refuses the connection itself, before any Nostr message is exchanged, so there is nothing to negotiate and no error anybody could see: it simply held one of the eight routed slots, dialling and failing, while the coverage counter reported its writers as reached.

Plaza now sets such a relay aside after three failed connections and spends the slot on the next one down, trying it again six hours later. Three and not one, because a handshake also fails for a blip. Relays you added yourself are never dropped this way; they keep retrying however badly they behave, because quietly abandoning your own relay is the opposite of what you asked for.

On the account this was measured on, that moved the coverage figure from 202 to **196**, and the smaller number is the true one: fifty of those people had been behind a closed door, and the freed slot went somewhere that answers.

**Under it: the protocol library is now built with its safety checks on.** Zig compiles bounds, overflow and cast checks out of the mode Plaza ships. That is the right trade for the code that draws a frame and the wrong one for the code that parses bytes a stranger sent, so the two are now built differently: `nostr` gets the checks, Plaza's own render path keeps the speed. Measured, it costs nothing you can see. Building the whole app that way was measured too, and it costs a great deal: the feed rebuild goes from 290 to 852 microseconds.

Also: `seed-feed`, a tool that fabricates a feed for the frame-budget harness, was riding along inside the app bundle in v0.3.0 and v0.4.0. It is gone, and packaging now refuses a bundle carrying anything Plaza does not run.

### Install

```sh
curl -fsSL https://raw.githubusercontent.com/zig-nostr/plaza/main/scripts/install-macos.sh | bash
```

The installer downloads this release, verifies its SHA-256, installs `Plaza.app` to `/Applications`, clears the download-quarantine flag, and opens it.

It touches the app bundle and nothing else. Your key, your session and your local store live in `~/.plaza` and are left alone, so upgrading never costs you your identity.

### Why it is not notarized

Plaza signs notes with your key. The trust anchor for that is a build you can reproduce from source, not an Apple signature you cannot inspect. Read the [installer](https://github.com/zig-nostr/plaza/blob/main/scripts/install-macos.sh), or skip it and [build from source](https://github.com/zig-nostr/plaza#build): the same `scripts/package-macos.sh` that produced this artifact runs on your machine.

If you would rather not connect a key at all, Plaza reads without one, and every gated verb asks at the moment you reach for it.
