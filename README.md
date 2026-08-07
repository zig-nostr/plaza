# Plaza

**A fast, local-first Nostr client, built natively in Zig.**

Plaza is the flagship app of the [zig-nostr](https://github.com/zig-nostr)
ecosystem, a native Nostr client where you read without an account and post in
four clicks, and the feed renders from disk. It's built on the
[`nostr`](https://github.com/zig-nostr/nostr) protocol library, and can sign
through [Notary](https://github.com/zig-nostr/notary) so your key never enters a
client.

> **Status: early.** A first run opens straight into a feed, signed in as
> nobody: a curated starter pack, already populated, with a strip along the top
> offering a key when you want one. Create an identity, bring an existing key, or
> connect an external signer (Notary) over NIP-46 so your key never touches the
> app. The feed carries real names, avatars and pictures,
> rendered straight from a local store that a pool of background threads keeps
> filled, one process, no IPC. Composing signs a note (locally, or by a
> round-trip to the signer) that is stored at once and published to the pool.
> Private messages land in a milestone ahead. macOS first.

![Plaza: a native feed read from disk. Zig and Metal, no Electron, and the feed is a local query.](docs/shots/hero.jpg)

## What it looks like

| | | |
| --- | --- | --- |
| ![The feed is a local query: it renders from disk, so it is there before the network is](docs/shots/panel-feed.jpg) | ![Everyone resolved: names, faces and verification, straight from the local store](docs/shots/panel-profile.jpg) | ![Conversations in full: replies nest where they belong, reconciled in the background](docs/shots/panel-thread.jpg) |

<sub>Real windows, photographed from the running app against real notes from
public relays. Every pixel inside the window is the app's own, so nothing here
shows a screen the app cannot draw.</sub>

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/zig-nostr/plaza/main/scripts/install-macos.sh | bash
```

macOS on Apple Silicon. The installer verifies the download's SHA-256, installs
`Plaza.app`, clears the download-quarantine flag so it opens without a Gatekeeper
detour, and launches it. It touches the bundle and nothing else: your key,
session and local store live in `~/.plaza` and survive every upgrade.

Plaza is ad-hoc signed and not notarized on purpose. It signs notes with your
key, so the trust anchor is a build you can reproduce rather than an Apple
signature you cannot inspect. Read the
[installer](scripts/install-macos.sh), or build the same artifact yourself:

```sh
scripts/package-macos.sh   # -> dist/Plaza.app, ad-hoc signed
```

## Performance

The feed is a windowed list: it builds only the rows near the viewport, so what
it costs follows the window rather than the length of the feed. Measured on the
build that ships (ReleaseFast), scrolling hard through a live feed on an account
that follows three hundred people:

| Stage | p90 | Budget |
| --- | --- | --- |
| Rebuild | 315us | 700us |
| Layout | 1700us | 2400us |
| Patch | 57us | 200us |

A 120 Hz frame is 8333us, so a hard scroll spends about a quarter of one, and
the GPU path never falls back to CPU pixels. A long feed mounts around 330
widget nodes rather than one per note.

The number that matters is that it does not move with the size of the account.
The same scroll on the same machine, before the feed stopped asking the database
who you follow once per card, cost 24423us per rebuild: three whole frames to
draw one, and worse the more people you followed.

The feed reads every account you follow, not a slice of it. At the ceiling of
2048, with each of those accounts carrying a profile older than their notes
(which is the real shape: a bio is written once and posted over ever since), a
rebuild measures 5989us against the 16667us of a 60Hz frame. The subscription
splits those authors across filters relays will accept and sends them in one
REQ, so it asks about all of them rather than the first few hundred.

That ceiling is measured by the test suite rather than by the script below:

```sh
zig build test -Doptimize=ReleaseFast
```

Measure it yourself, and fail on a regression:

```sh
scripts/frame-budget.sh
```

## Develop

```sh
native dev     # build and run with hot reload
native test    # run the test suite
native build   # produce a ReleaseFast binary in zig-out/bin/
native check   # validate the markup and manifest
```

Before a release there is a second suite, which drives a real build the way a
person drives it: a cold start filling a feed from the public internet, a
packaged bundle launched through LaunchServices, and an account's contact list
edited and read back off a relay with an independent tool.

```sh
scripts/acceptance.sh
```

It is not part of CI. It publishes signed events to public relays, so it needs a
throwaway account rather than a checkout, and it says so and skips rather than
guessing. The details are in the script.

Plaza is a [Native SDK](https://github.com/vercel-labs/native) app: plain Zig
for the logic and the feed (`src/main.zig`), declarative `.native` markup for
the static screens, rendered natively, no browser, no Electron.

Linux builds and tests in CI on every change. Windows is not in the matrix:
the relay transport resolves hostnames through libc `getaddrinfo`, which Zig's
standard library does not declare for Windows, so nothing depending on the
library links there (`zig-nostr/nostr#59`). Packaged releases for either come
later regardless.

## License

MIT, see [LICENSE](LICENSE).
