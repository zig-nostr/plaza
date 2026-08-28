**Plaza** is a fast, local-first Nostr client, built natively in Zig. macOS (Apple Silicon), **ad-hoc signed (not notarized)**.

### What's new in v0.13.3

**Fixed: bringing your key left the app in guest mode.** Plaza starts its own keyholder and asks it to sign. The key window it opened was told none of that, so it went looking for a keyholder of its own and, inside the packaged app, started a second one beside the first. You typed your passphrase, that window said it was unlocked, and Plaza was still sitting there with your key locked and no way to say so. Restarting did the same thing again.

The key window now opens on the keyholder Plaza is already using. One keyholder, shared, instead of two that cannot see each other.

If Plaza's keyholder has not started yet, the press says so rather than opening a window that would start a second one. There is no fallback here on purpose: the fallback was the bug.

**The suite that opens a real window now runs on every change.** Every unit test passed while v0.13.0 could not write to a relay, and while the app window was laid out taller than its own canvas. Neither is visible to a test that never opens a window. That suite now runs in CI: a cold start on a real profile, and the packaged bundle launched with its keyholder beside it.
