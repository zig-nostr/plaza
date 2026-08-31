**Plaza** is a fast, local-first Nostr client, built natively in Zig. macOS (Apple Silicon), **ad-hoc signed (not notarized)**.

### What's new in v0.14.0

**A place can have more than one feed, and you can switch between them.** Hallway's own configuration ships five, and Plaza read the first and discarded the rest, so a community with a main room, a quieter one and a livestream feed showed one of them and no sign the others existed. All of them are read now. The feed you are in names itself in the header, and where there is more than one that name is the switcher; a place with a single feed still shows a plain label, because a control that opens nothing is worse than no control.

**A place wears its own colour.** A community that states one in its configuration gets it: the accent, the button you press to enter, its tile on the rail, and the handles, mentions and links throughout its feed, in the colour they chose rather than Plaza's violet. Anything that means a *state* is deliberately left alone: a warning, a zap, an unread mark. A yellow room should not make an error look like weather. Out of a place the interface is porcelain and violet again, and a place that states no colour never changes anything.

**Every place is told apart on the rail**, colour or not: one that says nothing about itself takes a tint from its host's key, the same way a face does. A column of rooms used to be identical grey squares distinguished by a single letter.

**The host's welcome opens when you arrive.** It was reachable only from the Info button, which nobody presses on the way in, so the one part of a place written in its own voice went unread. It now opens once, in a card you can close, and Info still has it afterwards.

**A place reads the kinds its feeds ask for.** A feed that carries livestreams or wikis was subscribed to plain notes regardless of what it said, which is a working relay and an empty room, indistinguishable from the outside from a broken one.

**Sharing a note goes through the community's gateway** when a place names one, and the menu row now says where it will take you, "Open on njump.me" rather than "Open on the web", so the destination is visible before the press rather than after. A gateway a place names is checked first: https only, no credentials in the address, and no query or fragment that could carry a redirect.

**Fixed: a place edited since your last visit showed you the old one.** A place is a replaceable event, and the copy in your local store when you follow a link is last session's. Plaza applied it and stopped looking, so the host's current version arrived a moment later and never reached the room. It now upgrades in place, keeping the notes already on screen and without dropping a working connection to do it.

**Fixed: a long welcome pushed Close and Leave off the bottom of the Info card.** The card had no height bound, so a place with a few headings and a list grew a window it did not fit in, and the reader most likely to want Leave could not reach it. The host's text scrolls inside the card now, whole.

**Fixed: a place could forget the room it had remembered.** The notes a place opens with were written down even when there were none to write, so a room whose relay had not answered yet could erase what the next launch was going to show you.
