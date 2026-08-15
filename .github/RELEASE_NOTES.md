**Plaza** is a fast, local-first Nostr client, built natively in Zig. macOS (Apple Silicon), **ad-hoc signed (not notarized)**.

### What's new in v0.6.0

**Your key is not in a plain file any more.** Plaza keeps your secret key in a separate process from the one that draws the screen, which is the right shape and was not the whole job: at rest it was raw hex in a file only your account could read. That file is handed over by a copied home folder, a Time Machine backup, or a stolen disk. It now lives in the macOS Keychain, which is encrypted with your login password, so none of those three give it up. An existing key moves across on the next launch, and only after the copy has been read back and checked, because it is the only copy on your Mac.

Being precise about what that does not do, since it is easy to assume otherwise: it does not stop another program running as you from reading it. Plaza is ad-hoc signed, and a Keychain item's access control binds to a signing identity that ad-hoc signing does not have. This is encryption at rest, not app-level isolation, and the code says so where anyone would go looking.

**A client you can make quiet, properly.** Reaction counts, repost counts and zap totals could already be taken away. Reply counts could not, and the verbs themselves could not: you could hide the number beside the heart but not the heart. Both now, so if you never zap you can remove zapping rather than only its total.

Hiding a verb takes its count with it, and what you hide, the feed stops asking relays for. Hide reactions and it stops requesting them, which is less bandwidth, less parsing and a smaller store rather than a number painted over. Two exceptions are stated on the rows themselves rather than left to assumption: reposting is still fetched, because that is the same stream that tells Plaza whether you reposted something, and your notifications keep working, because that is a separate subscription. You still hear when somebody reacts to your own note.

The section was called QUIET, which reads like do-not-disturb. It is NOTES.

### Install

```sh
curl -fsSL https://raw.githubusercontent.com/zig-nostr/plaza/main/scripts/install-macos.sh | bash
```

The installer downloads this release, verifies its SHA-256, installs `Plaza.app` to `/Applications`, clears the download-quarantine flag, and opens it.

It touches the app bundle and nothing else. Your key, your session and your local store live in `~/.plaza` and are left alone, so upgrading never costs you your identity.

### Why it is not notarized

Plaza signs notes with your key. The trust anchor for that is a build you can reproduce from source, not an Apple signature you cannot inspect. Read the [installer](https://github.com/zig-nostr/plaza/blob/main/scripts/install-macos.sh), or skip it and [build from source](https://github.com/zig-nostr/plaza#build): the same `scripts/package-macos.sh` that produced this artifact runs on your machine.

If you would rather not connect a key at all, Plaza reads without one, and every gated verb asks at the moment you reach for it.
