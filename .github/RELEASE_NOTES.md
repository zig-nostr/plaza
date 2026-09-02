**Plaza** is a fast, local-first Nostr client, built natively in Zig. macOS (Apple Silicon), **ad-hoc signed (not notarized)**.

### What's new in v0.17.0

All of this came from people telling me it was broken. Every fix has a test that fails without it.

**Switching between places works.** With two places entered, opening one kept showing the other's feed, and it stayed wrong after a restart. Following a link out of one room and into another was treated as an update to the room you were already in, so the second place inherited the first one's notes and then remembered them as its own. There was a second way in too: for a few seconds after following a link, pressing a row on the places rail did not stick.

**A room shows its own mark, or none.** Walking from a place that has a logo into one that does not left the first community's logo sitting on the second one's info card. A logo that arrives after you have moved on is no longer painted onto the room you moved to, or saved as belonging to it.

**Follow works.** On a new key it did nothing at all: the button offered Follow, and pressing it published nothing and said nothing. From a note's menu it did nothing in the feed, and inside a thread it followed the wrong person, whoever started the thread rather than whoever you clicked.

**Following one person follows one person.** Your first follow used to publish the whole starter pack as your contact list, so a single press signed for nine accounts you never chose and every face in the feed turned to Following at once. It names only the person you pressed.

**Your feed is yours to choose.** A new key keeps reading the starter pack after following a few people, instead of dropping to a feed of one account as payment for one press. The feed name at the top of the window switches between the starter pack and the people you follow, and remembers which one you picked.
