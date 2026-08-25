**Plaza** is a fast, local-first Nostr client, built natively in Zig. macOS (Apple Silicon), **ad-hoc signed (not notarized)**.

### What's new in v0.12.4

**You can take a copy of your key.** Creating a key in Plaza left no way to get it out again, which matters more here than it sounds: a nostr key cannot be replaced, so the only copy being on one Mac means losing the Mac loses the account. The screen that removes a key even told you to make sure you had its nsec written down first, with nothing anywhere that would give you one.

Backing up happens in the signer's own window, the same one that minted the key, rather than in Plaza's settings. That is the point rather than an inconvenience: Plaza fetching a key so it could show it to you would make Plaza a program that holds your key, and it is built not to be. Open it from Settings, next to the line that says what is signing for you.

There are two forms. The encrypted one is still behind a passphrase you choose, so it is safe to keep in a password manager or on paper. The other is the key itself, and says so in red, because anyone who reads it becomes you and there is no taking it back.

**An app asking to sign no longer prints over itself.** When another app asked to sign as you, the card that asks whether to allow it drew its three lines on top of one another: the requester's key through the sentence below it, and the four answers through that. On the one card in the app that has to be read carefully before you press anything.

### Install

```sh
curl -fsSL https://raw.githubusercontent.com/zig-nostr/plaza/main/scripts/install-macos.sh | bash
```

The installer downloads this release, verifies its SHA-256, installs `Plaza.app` to `/Applications`, clears the download-quarantine flag, and opens it.

It touches the app bundle and nothing else. Your session and your local store live in `~/.plaza`, your key in the login Keychain, and both are left alone, so upgrading never costs you your identity.

### Why it is not notarized

Plaza signs notes with your key. The trust anchor for that is a build you can reproduce from source, not an Apple signature you cannot inspect. Read the [installer](https://github.com/zig-nostr/plaza/blob/main/scripts/install-macos.sh), or skip it and [build from source](https://github.com/zig-nostr/plaza#build): the same `scripts/package-macos.sh` that produced this artifact runs on your machine.

If you would rather not connect a key at all, Plaza reads without one, and every gated verb asks at the moment you reach for it.
