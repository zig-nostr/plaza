**Plaza** is a fast, local-first Nostr client, built natively in Zig. macOS (Apple Silicon), **ad-hoc signed (not notarized)**.

### What's new in v0.16.0

**A place brings its own relays.** A community says where it reads and where it writes, and Plaza now listens to both. Two things follow.

A feed can be about **people** rather than a relay. Hallway's Monero instance has one: twenty names and no relay of its own. Plaza used to drop a feed like that at the parser, so the room never appeared and nothing said why. It asks the place's own relays now.

And **a note written inside a place reaches that place.** It used to go to your relays and not to the community's, which is the opposite of what writing somewhere means.

**A place shows its own logo and can say where it reads a kind.** The Monero instance reads notes in Nosmero, so a note there offers to open in Nosmero, beside the app's own link rather than instead of it. Every address is checked before it is offered or fetched: https only, no credentials, and the menu row names the site it will open before you press it.

**A place can name what its own room says.** While a room is empty, connecting, or unreachable, the community's own words are used if it wrote any. Only those three lines: a place can name its room and cannot rename your Settings.

**Fixed: the welcome in a place's info card.** It was laid out wider than the card, so the right edge of every line ran onto the frame; it reserved a fixed height, so a short welcome sat above a tall empty box; an image written without alt text left its markdown on screen; and its links were drawn as links but could not be pressed.
