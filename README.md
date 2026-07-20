# Plaza

**A fast, local-first Nostr client, built natively in Zig.**

Plaza is the flagship app of the [zig-nostr](https://github.com/zig-nostr)
ecosystem, a native Nostr client where you browse and post within two minutes
and the feed renders from disk. It's built on the
[`nostr`](https://github.com/zig-nostr/nostr) protocol library, and can sign
through [Signet](https://github.com/zig-nostr/signet) so your key never enters a
client.

> **Status: early.** A first run opens a welcome screen: create an identity,
> bring an existing key, or connect an external signer (Signet) over NIP-46 so
> your key never touches the app. Either way you land in a follow-based feed
> seeded by a curated starter pack, with real names, avatars and pictures,
> rendered straight from a local store that a pool of background threads keeps
> filled, one process, no IPC. Composing signs a note (locally, or by a
> round-trip to the signer) that is stored at once and published to the pool.
> The outbox model, private messages and packaging land in the milestones
> ahead. macOS first.

## Performance

The feed is a windowed list: it builds only the rows near the viewport, so what
it costs follows the window rather than the length of the feed. Measured on the
build that ships (ReleaseFast), while scrolling hard through a live feed:

| Stage | p90 | Budget |
| --- | --- | --- |
| Rebuild | 54us | 400us |
| Layout | 432us | 1500us |
| Patch | 19us | 200us |

A 120 Hz frame is 8333us, so a hard scroll spends about a tenth of one. Sixty
notes mount 63 widget nodes rather than roughly 500, and the GPU path never fell
back to CPU pixels.

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

Plaza is a [Native SDK](https://github.com/vercel-labs/native) app: plain Zig
for the logic and the feed (`src/main.zig`), declarative `.native` markup for
the static screens, rendered natively, no browser, no Electron. Linux and
Windows build and test in CI; packaged releases for them come later.

## License

MIT, see [LICENSE](LICENSE).
