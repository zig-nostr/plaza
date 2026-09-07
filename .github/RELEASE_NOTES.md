**Plaza** is a fast, local-first Nostr client, built natively in Zig. macOS (Apple Silicon), **ad-hoc signed (not notarized)**, and Linux (x86_64 and aarch64).

### What's new in v0.18.4

**Japanese, Chinese, Korean and Greek are text on Linux now.** They were solid grey blocks. Off macOS Plaza draws every glyph from the fonts it carries, and those covered Latin and Cyrillic, so anyone reading Nostr in another script saw rows of rectangles. Plaza carries Noto for those scripts now, and the renderer reaches for it when its own font has no glyph. This adds about 13 MB to the Linux download and nothing to the macOS one, which does not need it.

Still not right, and a font would not fix them: Arabic, Hebrew, Thai and Devanagari. Those need letters to join and reorder, which is a different piece of machinery that does not exist yet. Nothing is bundled for them, because a wrong rendering is not clearly better than a missing one.

**Linux draws less per frame.** The toolkit works out which part of the window changed, and the Linux code was throwing that away and converting the whole window every frame. It uses it now.

### What's new in v0.18.3

**Fixed: on Debian the installer never checked for GTK 4.** The check that stops you downloading an app your machine cannot run was gated on finding `ldconfig` on your PATH, and Debian keeps it in `/usr/sbin`, which it does not put on a normal user's PATH. So on Debian the check silently did not happen. In practice almost nobody hit this, because every Debian 13 desktop already has GTK 4, but the safety net was not there.

**A first start that fails now says so.** Plaza was launched at the end of the install with its output thrown away, so a window that died on a missing library was indistinguishable from one that opened behind something.

**The download is verified, or not installed.** If the published SHA-256 could not be fetched, the installer used to warn and install anyway.

**The distribution floor is checked before GTK.** An Ubuntu 22.04 machine has GTK 4.6, so a presence check passed there and told the reader nothing, while the floor is the real reason it cannot run this.

**Two things this page should have said all along.** These downloads need **Ubuntu 23.10+, Debian 13+, or Fedora 39+**; Ubuntu 22.04 and Debian 12 are too old. And on Linux Plaza draws every glyph from the faces it carries, which cover Latin and Cyrillic, so Greek, CJK, Japanese, Korean, Arabic, Hebrew, Thai and Devanagari are drawn as solid blocks rather than as text. If you read Nostr in one of those scripts, the macOS build is the one to use today.

Also carries the current keyholder.

### What's new in v0.18.2

**A relay you remove stops reading within a second.** A relay's reader waited for that relay to say something before it looked at anything else, so removing one, pointing it somewhere else, or setting it write-only left its connection up and still filling your store until it happened to speak. Pausing the pool had the same shape: the button worked, and the relays took as long to leave as they took to talk. On a quiet relay that could be indefinitely.

Measured on the same four relays, pausing the pool: ten seconds before, two now.

**Fixed: a leak on every reconnect.** Closing a relay connection freed everything it had allocated except the connection itself. A pool that reconnects on a dropped socket left one behind each time, for as long as the app ran.

Also carries the current keyholder.

### What's new in v0.18.1

**Fixed: the Linux build would not start.** It died the instant you ran it, with `Illegal instruction` and nothing else, on any machine whose processor was not the one that built it. Every Linux VM on an Apple computer was that case, which is most of the people who would have tried it first.

The binaries are built for a baseline processor now rather than for whichever machine happened to compile them. v0.18.0's Linux downloads have been removed; there was no version of them that worked.

Nothing else changed. Everything in v0.18.0 below is in this release too.

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
