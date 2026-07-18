# Plaza

**A fast, local-first Nostr client, built natively in Zig.**

Plaza is the flagship app of the [zig-nostr](https://github.com/zig-nostr)
ecosystem, a native Nostr client organized around community **"places,"** where
you browse and post within two minutes and the feed renders from disk. It's built
on the [`nostr`](https://github.com/zig-nostr/nostr) protocol library, and can
sign through [Signet](https://github.com/zig-nostr/signet) so your key never
enters a client.

> **Status: early (M5).** A first run opens a welcome screen; creating an identity
> drops you into a follow-based feed seeded by a curated starter pack, rendered
> straight from a local store that a pool of background threads keeps filled, one
> process, no IPC. Composing signs a note that is stored locally at once and
> published to the pool. Connecting an external signer, community "places," and
> the outbox model land in the milestones ahead. macOS first.

## Develop

```sh
native dev     # build and run with hot reload
native test    # run the test suite
native build   # produce a ReleaseFast binary in zig-out/bin/
native check   # validate the markup and manifest
```

Plaza is a [Native SDK](https://github.com/vercel-labs/native) app: declarative
`.native` markup for the view (`src/app.native`) and plain Zig for the logic
(`src/main.zig`), rendered natively, no browser, no Electron.

## License

MIT, see [LICENSE](LICENSE).
