**Plaza** is a fast, local-first Nostr client, built natively in Zig. macOS (Apple Silicon), **ad-hoc signed (not notarized)**.

### What's new in v0.17.1

Five fixes, none of them reported. After the last release I went looking for the shape of the bugs in it rather than waiting to be told about the rest, and these are what turned up. Every one has a test that fails without the fix.

**"Leave this place?" asked about the room you meant.** The confirmation stayed armed while a link carried you into a different community, and the card then showed that one with the confirmation still up. Confirming took the wrong room off your rail, along with the notes it remembered.

**A place you were visiting stops disappearing.** A visit is not in your list, so the rail keeps a seat for it. Only going Home ever filled that seat: stepping onto another room from the rail, or following a link out of a visit, left nothing naming the place you had been in and no way back to it.

**The room you are in is remembered when you got there by a link.** Every other way in wrote it down. Open a room from the rail, follow a link into another, quit, and Plaza reopened the first one.

**Your own feed keeps loading older notes.** A place's feed has a bottom, and reaching it told Plaza the feed had ended. That answer was about the room, but it stuck to everything: going Home afterwards left your own feed unable to load anything older until you restarted.

**A note goes to the room it was written in.** If you use the undo pause, or a remote signer, or a note is retried later, it was published to whichever community you had wandered into by then rather than the one you wrote it in. Where a place says "only these relays", that meant the note reached nobody at all.
