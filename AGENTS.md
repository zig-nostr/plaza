# AGENTS.md

A guide to this repository for coding agents and the people working with them.

## What Plaza is

A native Nostr client for macOS and Linux, written in Zig on the [`nostr`](https://github.com/zig-nostr/nostr) library and the [Native SDK](https://github.com/vercel-labs/native). No browser and no WebView: the toolkit draws every pixel. The feed renders from a local LMDB store in the app's own process, and background threads keep that store filled from relays.

Plaza never holds a secret key. It ships [Notary](https://github.com/zig-nostr/notary) and starts it as a child process that signs on its behalf, or it signs through an external NIP-46 signer. Keep it that way: no field, flag, file or code path in Plaza should ever carry an nsec.

## Layout

```
src/main.zig         # the app: model, update, the hand-written feed view, relay and store work
src/tests.zig        # the test suite
src/onboarding.native  # declarative markup for the static screens
src/theme.zig        # colors and type
src/painted.zig      # custom-drawn pieces
app.zon              # app manifest; its .version is the release version
build.zig.zon        # dependencies: native_sdk and nostr, pinned by hash
.github/notary-ref   # the Notary release that Plaza bundles
.github/RELEASE_NOTES.md  # the text of each release page
scripts/             # packaging, installers, acceptance and frame-budget checks
```

## Build and test

Zig 0.16.0 exactly (pinned in `.zigversion`).

On macOS, with the Native SDK CLI (`npm install -g @native-sdk/cli@0.10.1`, the version CI uses):

```sh
zig build model-contract   # emit the model contract first, or native check skips its typed checks
native check               # validate the markup and manifest
native test                # the test suite
native build               # ReleaseFast binary in zig-out/bin/
native dev                 # build and run
zig fmt --check src
```

On Linux, with `libgtk-4-dev` installed:

```sh
zig build
zig build test
zig build test -Doptimize=ReleaseFast   # the mode that ships; CI runs both
```

Run the tests in ReleaseFast as well as Debug before calling a change done. The app ships ReleaseFast, and optimized builds have caught bugs a Debug build did not.

Two scripts are not part of CI:

- `scripts/frame-budget.sh` measures frame cost while the feed scrolls and fails when a stage passes its budget. Run it on any change to the feed or its rendering.
- `scripts/acceptance.sh` drives a real build against public relays and publishes signed events. It needs a throwaway account. Do not run it without the maintainer's go-ahead.

## Conventions

- `zig fmt` is the formatter; CI fails on unformatted code.
- [Conventional Commits](https://www.conventionalcommits.org/). One concern per pull request, with its tests, and every pull request links its issue.
- Never commit to `main`; everything lands through a reviewed pull request.
- A release is a version bump in `app.zon` plus a matching `### What's new in vX.Y.Z` section in `.github/RELEASE_NOTES.md`. CI checks that the two agree. Merging the bump tags the release and builds it.

## Nostr rules that matter here

- Never publish a replaceable event (kind 0, 3, 10000, 10002 and the rest of `1xxxx`) over data you have not read back first. An empty answer from a relay does not mean the user has no such event. Writing over a list you never read deletes the user's data.
- Before designing anything at the protocol level (a new subscription, relay choice, batching, caching, pagination), read how established clients do the same job. Nostr has many traps and they are already solved in shipping code.
- Validate everything that comes from a relay at the boundary.

## Related

- [`nostr`](https://github.com/zig-nostr/nostr): the protocol library. It has an agent skill: `npx skills add zig-nostr/nostr`.
- [Notary](https://github.com/zig-nostr/notary): the signer Plaza bundles. A signer fix reaches Plaza users only when `.github/notary-ref` moves and Plaza releases.
- [deed](https://github.com/zig-nostr/deed): a nostr command line, handy for checking what Plaza wrote to a relay.
- [zignostr.com](https://zignostr.com/plaza): the project site, also served as Markdown at `/plaza.md`.
