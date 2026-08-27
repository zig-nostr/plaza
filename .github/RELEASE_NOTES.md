**Plaza** is a fast, local-first Nostr client, built natively in Zig. macOS (Apple Silicon), **ad-hoc signed (not notarized)**.

### What's new in v0.12.6

**Posts show their replies, reposts, likes and zaps again.** Plaza only ever asked relays about notes that arrived while the app was open, and it asks for what is newer than the newest note it already has. So on every launch after the first, most of your feed was made of notes nobody had asked about, and all four numbers read zero. Opening a post fetched that one post's numbers, which is why they would appear for exactly the one you had looked at and nowhere else. Plaza now asks about the posts it is showing you.

**A post's date line stopped flickering.** "11h via Damus Notedeck" was a few pixels too wide for the space it had, so it broke onto a second line that had nowhere to go: it painted over the handle below it and vanished again as you scrolled. It stays on one line now, in a column wide enough for the longest thing it can say.

**Turning the counts off turns them off in threads too.** With every count hidden, opening a post still put "0 replies 0 reposts 0 likes 0 sats" across the top of it. A hidden count is gone now rather than shown as zero, and with all four hidden the whole band goes with them.

**The bookmark and the "..." are gone from under each post.** The bookmark did nothing, and the "..." opened a menu carrying exactly what a right-click on the post already carries. Right-click is still there, with all of it: quote, copy, open on the web, follow. Turning every verb off now leaves no empty band behind either.

**Sign out left the menu behind the relay count.** It only opened Settings with the confirmation showing, and Settings is where it lives.

**The signer window keeps up with your terminal.** If you import a key with the terminal command it offers, the window notices within a second instead of sitting on the paste screen. **And its two passphrase fields draw stars**, with an eye beside them, hidden every time it opens.

### Install

```sh
curl -fsSL https://raw.githubusercontent.com/zig-nostr/plaza/main/scripts/install-macos.sh | bash
```

The installer downloads this release, verifies its SHA-256, installs `Plaza.app` to `/Applications`, clears the download-quarantine flag, and opens it.

It touches the app bundle and nothing else. Your session and your local store live in `~/.plaza`, your key in the login Keychain, and both are left alone, so upgrading never costs you your identity.

### Why it is not notarized

Plaza signs notes with your key. The trust anchor for that is a build you can reproduce from source, not an Apple signature you cannot inspect. Read the [installer](https://github.com/zig-nostr/plaza/blob/main/scripts/install-macos.sh), or skip it and [build from source](https://github.com/zig-nostr/plaza#build): the same `scripts/package-macos.sh` that produced this artifact runs on your machine.

If you would rather not connect a key at all, Plaza reads without one, and every gated verb asks at the moment you reach for it.
