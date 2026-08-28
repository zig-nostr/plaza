**Plaza** is a fast, local-first Nostr client, built natively in Zig. macOS (Apple Silicon), **ad-hoc signed (not notarized)**.

### What's new in v0.13.1

**Fixed: v0.13.0 could not write anything.** Following somebody, muting, posting, reacting, editing your profile: all of it was refused before it reached a relay, and the app showed the press as done. If you ran v0.13.0, nothing you wrote in it was published. That release is now marked a pre-release and this one replaces it.

The cause was in the pairing. Plaza starts its own keyholder and asks it to sign, and that keyholder asked for approval on the first signature of each kind, then filed the question where nothing could answer it. Notary v0.10.2 settles it: a keyholder started by the app it serves was handed a one-time secret by that app over a channel nothing else can reach, so it already knows who is asking. A client that arrives over a relay still answers to the approval queue, because that one really can be anybody.

**And a write nobody signed is now taken back.** Pressing Follow moves the list straight away, which is what makes the feed answer immediately, and that stays. What was missing was the other half: when a signature never arrived, nothing put the list back. The app went on showing a follow that had reached no relay, and would not accept the real list from a relay for the rest of the session. Now the press is undone and you are told it was not signed.
