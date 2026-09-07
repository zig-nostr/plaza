**Plaza** is a fast, local-first Nostr client, built natively in Zig. macOS (Apple Silicon), **ad-hoc signed (not notarized)**, and Linux (x86_64 and aarch64).

### What's new in v0.18.0

**Plaza runs on Linux.** One line, no root, nothing outside your home directory:

```sh
curl -fsSL https://raw.githubusercontent.com/zig-nostr/plaza/main/scripts/install-linux.sh | bash
```

GTK 4 is the one runtime dependency and the installer says so before it downloads anything. It verifies the SHA-256, installs into `~/.local`, registers the desktop entry so `plaza://` links open Plaza, and launches it. Pass `--archive <file>` to install a tarball you already have, which needs no network at all.

It is the same app, not a port with pieces missing: the feed, places, the keyholder, images, mentions, threads. What differs is underneath. macOS hands text to the system to draw; on Linux there is nothing to hand it to, so Plaza draws every glyph itself, and the fixes below are what that turned up.

**Emoji are drawn, in colour.** Off macOS there is no system emoji font to fall back to, so every emoji was a solid grey block, and a name with one in it came out with a bar through it. Plaza carries its own colour emoji face there now.

**Headings, names and bold text are actually bold.** Every weight resolved to the regular face, so an author's name rendered as plain text one step smaller than the note beneath it, which is worse than flat.

**One wheel click scrolls the feed and stops.** It used to launch it: a single notch travelled for about forty seconds, and scrolling back was the only thing that stopped it.

**A `plaza://` link opens the place it names**, whether Plaza is already running or not. Nothing carried the link to the app before, so following one did nothing.

**The clock reads local time.** Every timestamp was UTC.

**Invisible characters stay invisible.** The one that marks an emoji as coloured has no shape of its own and was being drawn as a solid block beside it, so a skull came out as a skull and a grey rectangle.

**A quoted note's time is flush right** like every other timestamp, on both platforms. It sat short of the card's edge.

### What's new in v0.17.1

Five fixes, none of them reported. After the last release I went looking for the shape of the bugs in it rather than waiting to be told about the rest, and these are what turned up. Every one has a test that fails without the fix.

**"Leave this place?" asked about the room you meant.** The confirmation stayed armed while a link carried you into a different community, and the card then showed that one with the confirmation still up. Confirming took the wrong room off your rail, along with the notes it remembered.

**A place you were visiting stops disappearing.** A visit is not in your list, so the rail keeps a seat for it. Only going Home ever filled that seat: stepping onto another room from the rail, or following a link out of a visit, left nothing naming the place you had been in and no way back to it.

**The room you are in is remembered when you got there by a link.** Every other way in wrote it down. Open a room from the rail, follow a link into another, quit, and Plaza reopened the first one.

**Your own feed keeps loading older notes.** A place's feed has a bottom, and reaching it told Plaza the feed had ended. That answer was about the room, but it stuck to everything: going Home afterwards left your own feed unable to load anything older until you restarted.

**A note goes to the room it was written in.** If you use the undo pause, or a remote signer, or a note is retried later, it was published to whichever community you had wandered into by then rather than the one you wrote it in. Where a place says "only these relays", that meant the note reached nobody at all.
