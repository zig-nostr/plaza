**Plaza** is a fast, local-first Nostr client, built natively in Zig. macOS (Apple Silicon), **ad-hoc signed (not notarized)**.

### What's new in v0.15.0

**A note can be taken back before it is sent.** Turn on "Hold notes and replies before sending" in Settings, and pressing Post waits a few seconds instead of sending. The button becomes Undo and counts down. Press it again and the note is taken back.

The wait is before the note is signed, which is what makes it a real undo. Once a note is signed and out, asking relays to delete it is only a request: some will ignore it, and anyone who already has it keeps it. Nothing is signed until the clock runs out, so taking it back leaves nothing behind anywhere.

The composer stays open while it counts, so you can fix the typo you spotted a moment too late and the corrected note is the one that goes. Replies work the same way.

Off unless you turn it on, at five or ten seconds. Asked for in [#330](https://github.com/zig-nostr/plaza/issues/330).
