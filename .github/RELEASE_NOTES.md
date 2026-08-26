**Plaza** is a fast, local-first Nostr client, built natively in Zig. macOS (Apple Silicon), **ad-hoc signed (not notarized)**.

### What's new in v0.12.5

**Your key is never written down in the clear.** Plaza keeps your key in the login Keychain, and when the Keychain would not take it the signer wrote the key to a file on your disk instead, unencrypted, and said nothing. A healthy Mac never reached that, which is most of why it was worth fixing: the one path nobody ever watches quietly left the key weaker than the one you asked for, and there was no way to tell from the outside.

It now refuses. A key it cannot store safely is not stored at all, and it says so instead of reporting a generic failure, so there is no version of this where you believe you have an identity that is actually sitting on disk in the open.

### Install

```sh
curl -fsSL https://raw.githubusercontent.com/zig-nostr/plaza/main/scripts/install-macos.sh | bash
```

The installer downloads this release, verifies its SHA-256, installs `Plaza.app` to `/Applications`, clears the download-quarantine flag, and opens it.

It touches the app bundle and nothing else. Your session and your local store live in `~/.plaza`, your key in the login Keychain, and both are left alone, so upgrading never costs you your identity.

### Why it is not notarized

Plaza signs notes with your key. The trust anchor for that is a build you can reproduce from source, not an Apple signature you cannot inspect. Read the [installer](https://github.com/zig-nostr/plaza/blob/main/scripts/install-macos.sh), or skip it and [build from source](https://github.com/zig-nostr/plaza#build): the same `scripts/package-macos.sh` that produced this artifact runs on your machine.

If you would rather not connect a key at all, Plaza reads without one, and every gated verb asks at the moment you reach for it.
