**Plaza** is a fast, local-first Nostr client, built natively in Zig. macOS (Apple Silicon), **ad-hoc signed (not notarized)**.

### What's new in v0.12.2

**Faces that were stuck behind a proxy refusing their host.** Plaza asks an image proxy to fetch and shrink pictures, and the default one refuses whole domains by policy rather than by picture: any `.pub` address comes back as "Domain or TLD blocked by policy". Ditto's media server is `blossom.ditto.pub`, so anybody whose picture lives there arrived as initials and a flat colour band, on every screen, and stayed that way.

The feed's own pictures already knew what to do about this: when the proxy refuses the host rather than the picture, ask the host itself. Faces and banners never learned it, so notes rendered and the people in them did not. Both now do, once per picture, and only when it was the host that was refused. A picture the proxy could not find is not asked for again, because it will not be at the host either.

A face fetched this way is the full-size file rather than the small one the proxy would have returned, which costs more to download and is why this happens only when there is no other way to get the picture at all.

### Install

```sh
curl -fsSL https://raw.githubusercontent.com/zig-nostr/plaza/main/scripts/install-macos.sh | bash
```

The installer downloads this release, verifies its SHA-256, installs `Plaza.app` to `/Applications`, clears the download-quarantine flag, and opens it.

It touches the app bundle and nothing else. Your session and your local store live in `~/.plaza`, your key in the login Keychain, and both are left alone, so upgrading never costs you your identity.

### Why it is not notarized

Plaza signs notes with your key. The trust anchor for that is a build you can reproduce from source, not an Apple signature you cannot inspect. Read the [installer](https://github.com/zig-nostr/plaza/blob/main/scripts/install-macos.sh), or skip it and [build from source](https://github.com/zig-nostr/plaza#build): the same `scripts/package-macos.sh` that produced this artifact runs on your machine.

If you would rather not connect a key at all, Plaza reads without one, and every gated verb asks at the moment you reach for it.
