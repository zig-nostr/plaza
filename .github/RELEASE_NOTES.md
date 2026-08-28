**Plaza** is a fast, local-first Nostr client, built natively in Zig. macOS (Apple Silicon), **ad-hoc signed (not notarized)**.

### What's new in v0.13.2

**Fixed: a write that was never signed no longer looks like it worked.** Every press in this app moves the screen straight away, which is what makes it feel immediate and is worth keeping. What was missing was the other half: if the signature never came back, nothing put any of it back. So a follow, a mute, a like, a repost or a profile edit could reach no relay at all while the app showed it as done.

Two of them were worse than that. A mute stamped your list forward, which kept your real mute list off the screen for the rest of the session, so somebody you had asked never to see again stayed visible with no way to correct it. A relay-list edit did the same and wrote its stamp to disk, so it survived a restart.

Now each of those is put back, and says so.

**A refused reply keeps what you typed.** It used to be cleared and gone.

**A restored draft tells you why.** If a note could not be signed, the draft came back with no explanation.

**Your other writes are retried.** Only notes were tracked and retried before, so anything else that reached no relay was published once and forgotten.

**Fixed: the terminal command for importing a key named the wrong app.** If you installed Plaza on its own, the key window told you to run a command inside `Notary.app`, which is not on your Mac unless you installed Notary separately as well. It now names the signer Plaza ships.

**Fixed: turning off "answering your other devices" looked like it did nothing.** The setting was saved correctly, but the window read its state back from the keyholder, which kept reporting the value it had at startup, so the switch flipped back.
