**Plaza** is a fast, local-first Nostr client, built natively in Zig. macOS (Apple Silicon), **ad-hoc signed (not notarized)**.

### What's new in v0.5.0

**Mentions are people again.** A `nostr:npub…` in a note has always been drawn as `@name`, which is what makes a note readable and was also what threw away the only thing a press could have acted on. Pressing one now opens that profile. It fixes something visible on the way: a display name of two words was styled as far as the first word only, because the old reading of a mention stopped at the first space.

**You can repost.** The icon has carried a real count and no action since the row was drawn. It sends now, built to what other clients actually send rather than to a reading of the spec: kind:6 for a kind:1, the reposted note carried in the content so a reader who has never seen it does not have to go and ask, and an `e` tag whose empty relay-hint field is load-bearing. There is no un-repost, which is what the clients that have thought about it do.

**Your mute list works.** Plaza had never read one, so somebody muted years ago in whatever client you came from was still in the feed here, still able to ring the bell, and still under every thread. It reads NIP-51's mute list now and honours it in the feed, in threads and in notifications, and you can mute and unmute from a profile.

Writing that list is the careful part, because it is a replaceable record: publishing one replaces what you have muted everywhere at once. Plaza will not write one it has not read back first, and says so rather than sitting there doing nothing. Everything it does not itself understand is carried through untouched, including muted words and hashtags set in another client, and including the private half. If your mute list has private entries Plaza cannot read, it refuses the write rather than publishing over them.

**A client you can make quiet.** Reaction counts, repost counts and zap totals can each be taken away, in Settings, under QUIET. The part that makes this more than a switch: what you hide, the feed stops asking relays for. Hide reaction counts and it stops requesting them, so it is less bandwidth, less parsing and a smaller store rather than a number painted over. Your notifications are a separate subscription and keep working, so you still hear when somebody reacts to your own note. One of the three says plainly that hiding it changes only what is drawn, because knowing whether you reposted something comes down the same stream as everybody else's reposts.

Everything hideable is listed on that screen whether or not it is hidden, which is the point of it: hide something in the feed and there is nothing left there to press to get it back.

**Underneath: the checks stay on where the bytes are not ours.** Plaza ships in a mode that compiles out Zig's bounds, overflow and cast checks. That is the right trade for the code drawing a frame and the wrong one for code parsing bytes a stranger sent, so the parsing this app does for itself now keeps its checks: note content, mentions, quote spans, image metadata, blurhashes, profile bodies, the head of a fetched page. Measured, it costs nothing you can see. It has already caught one real bug in this release.

The vendored image decoders are C and no Zig setting reaches them, so what stands in front of them is a size check on what they hand back, before anything multiplies two numbers that came out of a stranger's file.

### Install

```sh
curl -fsSL https://raw.githubusercontent.com/zig-nostr/plaza/main/scripts/install-macos.sh | bash
```

The installer downloads this release, verifies its SHA-256, installs `Plaza.app` to `/Applications`, clears the download-quarantine flag, and opens it.

It touches the app bundle and nothing else. Your key, your session and your local store live in `~/.plaza` and are left alone, so upgrading never costs you your identity.

### Why it is not notarized

Plaza signs notes with your key. The trust anchor for that is a build you can reproduce from source, not an Apple signature you cannot inspect. Read the [installer](https://github.com/zig-nostr/plaza/blob/main/scripts/install-macos.sh), or skip it and [build from source](https://github.com/zig-nostr/plaza#build): the same `scripts/package-macos.sh` that produced this artifact runs on your machine.

If you would rather not connect a key at all, Plaza reads without one, and every gated verb asks at the moment you reach for it.
