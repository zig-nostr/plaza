**Plaza** is a fast, local-first Nostr client, built natively in Zig. macOS (Apple Silicon), **ad-hoc signed (not notarized)**.

### What's new in v0.8.0

**Plaza can sign for other apps.** Turn it on in Settings, copy the link, paste it into Coracle or Jumble or anything else that speaks NIP-46, and that app signs with your key without ever holding it. This is the thing a browser extension does, done by the process on your Mac that already holds your key instead of by an extension living inside your browser.

It is off unless you turn it on. While it is on, Plaza connects to relays and other apps can reach it, and an app nobody asked to be a signer should not open that up because it happens to hold a key.

**Nothing signs without you.** An app has to be let in first, and being let in does not let it sign: the first time it wants to do something, Plaza asks, and asks again separately for each kind of thing. Signing a note and changing who you follow are different questions, because they are different risks.

Each answer carries how long it lasts. Allow once, allow for a day, always, or deny. A denial is remembered too, so an app that asks for something you do not want can be told no and stop asking. When an answer runs out the question simply opens again, and a prompt you never answered is not treated as a no: walking away from your machine is not a decision.

The question is asked in terms of what would happen, not which method was called. "An app wants to change who you follow" rather than "sign_event kind 3".

**You can see and undo all of it.** Settings lists every app that is connected, with a button to disconnect any of them. Turning the whole thing off ends every session at once. That visibility is the point: a signer you cannot audit is one you have to trust.

The link also appears in the Notary window, so it is where the key is, not only in Settings.

### Install

```sh
curl -fsSL https://raw.githubusercontent.com/zig-nostr/plaza/main/scripts/install-macos.sh | bash
```

The installer downloads this release, verifies its SHA-256, installs `Plaza.app` to `/Applications`, clears the download-quarantine flag, and opens it.

It touches the app bundle and nothing else. Your key, your session and your local store live in `~/.plaza` and are left alone, so upgrading never costs you your identity.

### Why it is not notarized

Plaza signs notes with your key. The trust anchor for that is a build you can reproduce from source, not an Apple signature you cannot inspect. Read the [installer](https://github.com/zig-nostr/plaza/blob/main/scripts/install-macos.sh), or skip it and [build from source](https://github.com/zig-nostr/plaza#build): the same `scripts/package-macos.sh` that produced this artifact runs on your machine.

If you would rather not connect a key at all, Plaza reads without one, and every gated verb asks at the moment you reach for it.
