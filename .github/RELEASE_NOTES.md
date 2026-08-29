**Plaza** is a fast, local-first Nostr client, built natively in Zig. macOS (Apple Silicon), **ad-hoc signed (not notarized)**.

### What's new in v0.13.4

**Fixed: a locked keyholder now asks for its passphrase.** Opening Plaza with a key you had already brought showed "Notary is locked" and nothing to press, which reads as being signed out when in fact your key is right there. The key window now opens on it, and closes itself once you have unlocked it.

**Fixed: signing out works, and Plaza recovers from it.** A keyholder that ended stayed ended, so Plaza was left unable to sign anything until it was restarted. It starts a new one now, which comes up locked and asks for your passphrase.

**Also fixed in the keyholder** (Notary v0.10.6): signing out and backing up your key had disappeared from its window whenever an app started it, leaving key deletion as the only control; the terminal command for importing a key named an app you may not have installed; a keyholder answering no relays offered a connection link that went nowhere; and removing a key could start a second keyholder on real relays.
