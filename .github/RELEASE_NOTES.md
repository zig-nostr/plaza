**Plaza** is a fast, local-first Nostr client, built natively in Zig. macOS (Apple Silicon), **ad-hoc signed (not notarized)**.

### What's new in v0.2.6

- **A reply now reaches everyone already in the thread**, not only the person being answered. Every distinct author in the conversation is notified, capped so a long thread cannot turn one reply into a mass notification.

### What's new in v0.2.5

- **Notes now carry the tags their text implies.** A `#hashtag` publishes a `t` tag, so the note is findable in a hashtag feed instead of only by your followers. A mention publishes a `p` tag, so the person you named actually hears about it. An image URL publishes an `imeta` tag, so other clients can lay the picture out. A `note1` or `nevent1` reference publishes a `q` tag, so it reads as a quote.
- **Quote a note** from its menu or its right-click. It appends the reference to whatever is already in your composer rather than replacing it.
- **Replies carry those tags too.** They always had their threading tags and never had these.
- A link with a `#fragment` no longer publishes a topic named after the fragment, and a non-ASCII hashtag like `#café` is no longer cut short.
- A `github.com/.../raw/...` image link is rewritten to `raw.githubusercontent.com` before posting. The first is a redirect that many clients refuse to render inline; the second is the same file.

### Install

```sh
curl -fsSL https://raw.githubusercontent.com/zig-nostr/plaza/main/scripts/install-macos.sh | bash
```

The installer downloads this release, verifies its SHA-256, installs `Plaza.app` to `/Applications`, clears the download-quarantine flag, and opens it.

It touches the app bundle and nothing else. Your key, your session and your local store live in `~/.plaza` and are left alone, so upgrading never costs you your identity.

### Why it is not notarized

Plaza signs notes with your key. The trust anchor for that is a build you can reproduce from source, not an Apple signature you cannot inspect. Read the [installer](https://github.com/zig-nostr/plaza/blob/main/scripts/install-macos.sh), or skip it and [build from source](https://github.com/zig-nostr/plaza#build): the same `scripts/package-macos.sh` that produced this artifact runs on your machine.

If you would rather not connect a key at all, Plaza reads without one, and every gated verb asks at the moment you reach for it.
