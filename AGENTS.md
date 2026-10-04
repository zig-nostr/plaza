# AGENTS.md

A guide to this repository for coding agents and the people working with them.

## What Plaza is

A native Nostr client for macOS and Linux, written in Zig on the [`nostr`](https://github.com/zig-nostr/nostr) library and the [Native SDK](https://github.com/vercel-labs/native). No browser and no WebView: the toolkit draws every pixel. The feed renders from a local LMDB store in the app's own process, and background threads keep that store filled from relays.

Plaza never holds a secret key. It ships [Notary](https://github.com/zig-nostr/notary) and starts it as a child process that signs on its behalf, or it signs through an external NIP-46 signer. Keep it that way: no field, flag, file or code path in Plaza should ever carry an nsec.

## Layout

```
src/main.zig         # the hub: Model, Msg, update, boot and main, and a re-export of every module's public names
src/<area>.zig       # the app's logic, one file per area (listed below), each beside main.zig
src/view_<area>.zig  # the hand-written views, one file per screen or surface
src/blossom.zig      # Blossom uploads: server addresses, the signed token, preparing a picture, the PUT
src/article.zig      # NIP-23 articles: what a kind:30023 says about itself, its body cut into rows
src/search.zig       # finding a person: matching, ranking, the NIP-50 request and relay status
src/tests.zig        # the test harness: shared helpers, the list of app files, and the test files
src/tests/<area>.zig # the tests, by the file whose code they exercise; app.zig for what stays in main.zig
src/onboarding.native  # declarative markup for the static screens
src/theme.zig        # colors and type
src/painted.zig      # custom-drawn pieces
app.zon              # app manifest; its .version is the release version
build.zig.zon        # dependencies: native_sdk and nostr, pinned by hash
.github/notary-ref   # the Notary release that Plaza bundles
.github/RELEASE_NOTES.md  # the text of each release page
scripts/             # packaging, installers, acceptance and frame-budget checks
```

The areas, each a file under `src/`: app-wide numbers and settings (`tuning`, `prefs`, `hiding`, `updates`, `links`, `login`, `places`); relays (`relay_table`, `relay_list`, `routing`, `relay_conn`, `relay_hints`, `relay_auth`, `ingest`); the store and what is cached from it (`store_glue`, `feed_state`, `thread_model`, `note_build`, `profile_cache`, `person_card`, `quote_cache`, `addresses`, `link_preview`, `engagement`, `inbox`, `image_cache`, `image_pool`, `feed_media`); the reader's own lists (`own_lists`, `follows`, `mutes`, `bookmarks`, `private_lists`); signing and the session (`keyholder`, `remote_signer`, `session`, `own_profile`); writing (`drafts`, `uploads`, `media_servers`, `compose`, `outbox`); and moving between screens (`people_search`, `profile_notes`, `navigation`). Each file opens with a line saying what it holds.

Every module imports `main.zig` and takes the names it uses from there (`const Model = main.Model;`), and main.zig re-exports what each module declares, so a call site reads `main.x` wherever `x` lives. A container-level `var` cannot be re-exported, so it is always named through the file that owns it (`follows.g_follows`, `main.g_io`). A new file is imported from main.zig and added to `app_sources` in `src/tests.zig`: the tests that read the source read that list, and the network gate test fails on a file main.zig imports that the list does not name. A new test goes in the `src/tests/` file for the area it exercises.

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
- A row that answers a press is built with `pressRow` in `src/view_note.zig`, never with a bare `row`, `column` or `data_row` and an `on_press`. The toolkit gives Tab a stop, a focus ring and Return/Space activation to its own controls and to `list_item` only, so a layout kind with a press can be clicked and nothing else. A test walks every screen and fails on one.
- A release is a version bump in `app.zon` plus a matching `### What's new in vX.Y.Z` section in `.github/RELEASE_NOTES.md`. CI checks that the two agree. Merging the bump tags the release and builds it.

## Nostr rules that matter here

- Never publish a replaceable event (kind 0, 3, 10000, 10002 and the rest of `1xxxx`) over data you have not read back first. An empty answer from a relay does not mean the user has no such event. Writing over a list you never read deletes the user's data.
- The one thing that may stand in for a read is the user's own answer. When every relay Plaza reads from has finished and none sent the list, and the relays the user's own kind 10002 says they write to are all among them, Plaza asks before starting a new one and says what that would replace, and it asks again for each kind of list. A relay that has not finished never counts, and neither does a timeout or a relay list that has not been read: those show what went wrong and offer a retry.
- Before designing anything at the protocol level (a new subscription, relay choice, batching, caching, pagination), read how established clients do the same job. Nostr has many traps and they are already solved in shipping code.
- Validate everything that comes from a relay at the boundary.

## Related

- [`nostr`](https://github.com/zig-nostr/nostr): the protocol library. It has an agent skill: `npx skills add zig-nostr/nostr`.
- [Notary](https://github.com/zig-nostr/notary): the signer Plaza bundles. A signer fix reaches Plaza users only when `.github/notary-ref` moves and Plaza releases.
- [deed](https://github.com/zig-nostr/deed): a nostr command line, handy for checking what Plaza wrote to a relay.
- [zignostr.com](https://zignostr.com/plaza): the project site, also served as Markdown at `/plaza.md`.
