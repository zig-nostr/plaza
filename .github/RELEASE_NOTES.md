**Plaza** is a fast, local-first Nostr client, built natively in Zig. macOS (Apple Silicon), **ad-hoc signed (not notarized)**.

### What's new in v0.4.0

**Your feed reaches further.** v0.3.0 began connecting to relays the people you follow write to. This finishes it. Each connection now asks only about the people it can answer for, so a small relay is asked about its dozen writers rather than about everyone you follow, and there are eight of those connections rather than four.

The relays are chosen by who they reach rather than by how popular they are, because the popular relays all carry the same crowd: somebody who publishes to one quiet relay is never reached however many busy ones you dial. Measured on an account following 257 people, **202 of them are now covered, 156 of those by two relays each**, up from 193 and 134. Anyone no chosen relay carries is still asked of every relay you picked yourself, so narrowing the questions never costs you a person.

**A relay Plaza has just met is asked for what it holds.** A newly connected relay has answered nothing yet, so bounding its first question by the newest note already on your disk asked a relay full of history you are missing for the one slice it cannot supply. It now delivers hundreds of notes in the first minutes instead of almost none.

**Your connections stop being dropped and redialled for nothing.** A routed connection used to be torn down whenever anything about the routing moved, including things that had nothing to do with it: one person publishing a relay list cost every routed socket a handshake, and hundreds of relay lists arrive in the first seconds of a cold start.

Now each connection is told only about its own slot, a relay that stays in the set keeps its connection, a relay has to reach a quarter more people before a live socket is given up for it, and the routing waits for the flurry to settle before it recomputes at all. When the people on a relay do change, the question is replaced on the socket that is already open rather than by dialling a new one.

### Under it

The `nostr` library is unchanged at v0.8.0.

The feed's own numbers, on the build that ships: a hard scroll costs 275us to rebuild, 1360us to lay out and 55us to patch, against the 8333us of a 120 Hz frame. Measured against a fixed feed the harness seeds itself, so a run means the same thing twice.

### Install

```sh
curl -fsSL https://raw.githubusercontent.com/zig-nostr/plaza/main/scripts/install-macos.sh | bash
```

The installer downloads this release, verifies its SHA-256, installs `Plaza.app` to `/Applications`, clears the download-quarantine flag, and opens it.

It touches the app bundle and nothing else. Your key, your session and your local store live in `~/.plaza` and are left alone, so upgrading never costs you your identity.

### Why it is not notarized

Plaza signs notes with your key. The trust anchor for that is a build you can reproduce from source, not an Apple signature you cannot inspect. Read the [installer](https://github.com/zig-nostr/plaza/blob/main/scripts/install-macos.sh), or skip it and [build from source](https://github.com/zig-nostr/plaza#build): the same `scripts/package-macos.sh` that produced this artifact runs on your machine.

If you would rather not connect a key at all, Plaza reads without one, and every gated verb asks at the moment you reach for it.
