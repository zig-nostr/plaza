# Architecture

How Plaza is put together, and where to look first. For how to install and use it, read the [README](README.md). For how to change it, read [`AGENTS.md`](AGENTS.md), which also holds the full file layout.

## What it is

A native Nostr client for macOS and Linux, written in Zig 0.16 on the [`nostr`](https://github.com/zig-nostr/nostr) library and the [Native SDK](https://github.com/vercel-labs/native). The toolkit draws every pixel on a canvas: there is no browser and no WebView.

Plaza is one process. The protocol work (keys, events, relay connections, the local store) comes from the `nostr` library, which `build.zig` links straight into the app. The signing key is not in that process. It lives in Notary's daemon, which Plaza starts as a child and talks to over loopback, or in an external NIP-46 signer. `holdsKeyInProcessForTest` in `src/main.zig` is a constant false that a test reads, so a variable that could hold a secret key cannot be added without that test failing.

The app is local-first. The feed is a query against an LMDB store that the app process opens itself (`openFeedStore` in `main.zig`, at `$HOME/.plaza/feed.mdb`), so a read is a call into the library with no socket and no second process. Background threads fill that store from relays. Nothing on the read path waits for the network.

## The one process

`src/main.zig` is the hub, and it follows the Native SDK's Elm-style loop.

- `Model` holds view state only: what is open, what is typed, counters, the notes the feed is showing. It is the one value the toolkit reflects for `native check`.
- `Msg` is every event the app can receive: presses and edits, timers, and the result of every effect (a fetch that finished, a process that printed a line or exited).
- `update(model, msg, fx)` is the only place the model changes. It starts effects through `fx` and returns.
- `appView` (in `view_app.zig`) builds the widget tree from the model. It picks a screen by `Model.stage` and layers sheets over it. The join screen is declarative markup in `onboarding.native`; every other screen is a hand-written Zig view, because an inline picture needs a runtime image id that the markup grammar does not carry.
- `boot` runs once and starts the timers. `main` wires the app: it loads settings, restores the session, resolves the keyholder binary, creates the `PlazaApp`, opens the store and starts the relay threads through `startFeed`, then hands control to the runner.

Three timers drive everything that is not a press. `refresh_timer_key` fires `.tick` once a second and is where the store is reconciled into the model, queued writes are drained, and every fetch that needs `fx` is started. `animation_timer_key` fires `.animate` for playing GIFs. `profile_timer_key` fires `.profiles` every two seconds and asks for the profiles and quoted notes the view wants.

Every other file in `src/` imports `main.zig` and takes the names it uses from there (`const Model = main.Model;`), and `main.zig` re-exports what each file declares, so a call site reads `main.x` wherever `x` lives. A module-level `var` cannot be re-exported, so it is always named through the file that owns it (`follows.g_follows`, `main.g_io`).

The library is built one optimize mode safer than the app. `libraryOptimize` in `build.zig` gives a ReleaseFast app a ReleaseSafe `nostr`, because the library parses bytes a stranger chose. Plaza's own parsers get the same protection from `@setRuntimeSafety(true)` at the top of each function that walks foreign bytes (the rule is written once, near the top of `main.zig`).

## Where each part lives

`AGENTS.md` has the full list. By group:

- App-wide numbers and settings: `tuning` (layout metrics, caps, timer and effect keys), `prefs`, `hiding`, `updates`, `links`, `login`, `places`.
- Relays: `relay_table` (the eight pool slots and the bootstrap set), `relay_list` (the reader's own NIP-65 list), `routing` (outbox reads), `relay_conn` (connection state, one-shot asks, the keeper), `relay_hints`, `relay_auth` (NIP-42), `ingest` (the reader threads).
- The store and what is cached from it: `store_glue` (the one door in), `feed_state`, `thread_model`, `note_build`, `profile_cache`, `person_card`, `quote_cache`, `addresses`, `link_preview`, `engagement`, `inbox`, and the picture path (`image_cache`, `image_pool`, `feed_media`).
- The reader's own lists: `own_lists`, `follows`, `mutes`, `bookmarks`, `private_lists`.
- Signing and the session: `keyholder` (Notary), `remote_signer` (NIP-46), `session`, `own_profile`.
- Writing: `drafts`, `uploads`, `blossom`, `media_servers`, `compose`, `outbox`.
- Moving between screens: `people_search`, `search`, `profile_notes`, `navigation`.
- Views: `view_<area>.zig`, one per screen or surface, plus `theme`, `painted` and `plaza_icons`.
- Tests: `tests.zig` and `tests/<area>.zig`.

Also in the tree: `src/stb_impl.c` and the stb headers, which decode and resize pictures (the canvas image registry takes at most 512 by 512 and has no downscaler), `src/urlscheme.m`, which receives `plaza://` links on macOS because the toolkit registers the scheme and delivers nothing, and `src/seed_feed/`, a store seeder built only on request for the frame-budget script.

## How data flows

### Relays into the store

`startFeed` opens the store, loads the reader's lists and relay table from disk, then starts detached threads: one per pool slot (`ingestRelay`, `max_relays` of them), one per discovered-relay slot (`discoveredRelayThread`, `max_discovered_relays`), and one `relayKeeper`. A thread belongs to a slot and not to a relay, so adding a relay is claiming a slot and removing one leaves a thread that finds its slot empty and waits.

Each reader owns its own `std.Io.Threaded` and its own secp256k1 `Signer`. It dials, sends one REQ for the feed, one for the inbox, and later one for engagement, and reads until the connection ends. Each event is verified as it goes into `plazaIngestFrom` in `store_glue.zig`, which calls `plazaIngest` and records which relay delivered it. `plazaIngest` is the only door into the store: it keeps a copy of the reader's own replaceable records before a newer one overwrites them (see the rules below) and tells the feed what arrived.

A reader that loses its connection redials with a doubling wait (`reconnectDelayMs`, capped at five minutes) and a per-slot spread (`reconnectJitterMs`). A connection only clears the ladder by lasting a minute (`nextReconnectAttempts`), because a relay that accepts a socket and drops it is not healthy. The loop wakes every second (`ingest_wake`) to notice a relay that was removed, repointed or set write-only, since a thread blocked in `receive` cannot notice anything.

### The store to the view

On each tick `Model.refresh` compares the store's event count against `g_last_count` and rebuilds the notes only when something moved. `plazaIngest` also tells the feed what kind of change it was: `noteFeedArrival` queues the id of an added kind 1 event, and `invalidateFeed` asks for a full read (a deletion, a repost, a change in who is followed). `rebuildNotes` drains the queue with `takeFeedArrivals` and, when the list in hand can be brought up to date by adding, `spliceArrivals` reads exactly those ids and merges them into the rows already built. Otherwise `rebuildNotesFromStore` reads the window again, one `store.query` per kind so the query planner stays on the author-and-kind index.

What the view is drawing is published back to the reader threads through `publishFeedWatch`, so each relay is asked for the engagement of the notes on screen.

### Outbox reads

Following someone does not reach them if they publish to relays the reader is not on. `routing.zig` turns each followed author's kind 10002 into a ranking of relays by how many follows write there (`rankRelaySuggestions`, `selectWriteRelays`) and picks up to eight relays to dial beyond the pool (`chooseRoutedRelays`, `fillDiscovered`). Each pool or routed relay is then asked only about the follows who write there (`poolAuthors`, `buildFeedFilters`, `buildRoutedFilters`), plus the residual: every author no chosen relay covers, so nobody is asked of nobody. The invariant has a test by name.

Authors with no stored relay list are put to a few well-known indexer relays once per run by `sweepRelayLists`. A routed relay that refuses the connection three times gives up its slot for six hours (`noteRelayRefusal`). The keeper thread calls `followRouteChanges` each tick to re-ask or retire a routed socket whose slot moved, from a thread that is not blocked reading it.

### One-shot questions

A profile, a quoted note, a place's document or an address is fetched by asking the sockets the pool already holds (`askPool` in `relay_conn.zig`) under a subscription id that starts with `one_shot_sub_prefix`. The asking thread writes the REQ and waits for nothing. The reader that owns the socket ingests the answer into the store like any other event and closes the subscription at EOSE, and the view finds the result on the next tick. A relay named by someone else's data (an `nevent` hint, an author's list) is dialled on a short-lived socket instead, watched by the keeper under a deadline (`watchOneShot`, `one_shot_budget_ms`) so a relay that goes quiet cannot hold a thread forever.

### Publishing

A press that writes goes through `signAndPublish` in `compose.zig`, the one door for every published event. It adds the client tag if the reader asked for one, captures the room the press was made in, and calls the signer chosen by `keyholder.g_signer_kind`: `requestHelperSign` for Notary, `requestRemoteSign` for a bunker. The signed event comes back as a message and lands in `ingestAndPublish`, which stores it with `plazaIngest`, queues it with `enqueueOutbox` before any network work so a note that never goes out is still one the app knows it owes, and spawns `publishWorker`.

`publishEvent` in `outbox.zig` writes to the open place's relays first, then, unless the place keeps its notes to its own relays, to every pool relay marked write (reading the relay's OK and recording it against the slot with `recordOutboxAck`), then to the read relays of the people the event names (`recipientInboxUrls`: public `wss://` relays only, and none the pool already covers). The outbox is a small queue, saved to disk on change and loaded by `loadOutbox` at launch. The tick drains it with `drainOutbox` whenever a relay is up, with a retry delay that grows per round (`outboxRetryDelay`) and resets when a relay comes back.

## The signer

Plaza holds no key. Signing goes one of two ways, set by `g_signer_kind`.

**Notary's daemon, as a child process.** `resolveHelper` finds the `signer` binary beside Plaza's own executable (or Notary's checkout in a dev tree) and mints a secret. `spawnHelper` starts it as `signer --approval-http 127.0.0.1:0` and writes the secret to its stdin, so the credential is never in a file, an argument or the environment. The daemon prints its port on a line starting `notary-approval-port`, which the `.helper_line` message reads into `g_helper_port`. From then on Plaza talks to it with a bearer header: `pollHelper` asks `GET /pubkey` to learn whether it is empty, locked or ready (`HelperState`), and `POST /setup`, `/sign`, `/nip44/encrypt` and `/nip44/decrypt` carry the rest through `helperFetch`. If the daemon exits, `.helper_exited` starts it again up to `helper_restart_limit` times. Notary's windows for creating, importing and unlocking a key are a third binary Plaza spawns against the same address (`spawnNotaryWindow`), so there is never a second keyholder and no key material enters Plaza.

**A NIP-46 bunker.** `connectRemoteSigner` takes a `bunker://` link and keeps an ephemeral client key as the transport identity only. `nip46ReceiveLoop` is a thread that listens on the bunker's relay for answers addressed to that key, correlates each by request id against the eight-slot `g_pending` table, and verifies a signed event before it is published.

Both paths take a `PendingUndo` as an argument to `signAndPublish`, so a signature that never comes back leaves the screen as it was. Most writes change the screen before they are signed (a follow moves the list, a like fills in), and the undo records what to put back: the follow or mute and the stamp to return to, the like, the repost, the typed text of a reply, the relay list stamp, a profile edit's unsaved picture. It is per request: it travels in `g_helper_sign` for Notary and in the request's own `g_pending` slot for a bunker, so a failure puts back that press and no other. A signature releases it (`releaseUndo`).

A refusal, a timeout (`helper_sign_timeout_s`, thirty seconds, the same number as the wire deadline), or a signer that answers with the wrong key marks the request failed, and the tick's `scanHelperSign` or `scanPendingRemote` retires it: it gives back the note's text and calls `applyUndo`. A bunker request that never got out (its id or JSON could not be built), or an answer that cannot be used (it does not verify, or another key signed it), is parked in the table as failed by `parkFailedSign` and retired the same way. A parked request has no id, so no answer can match it. If the table filled up in between, it waits in `g_pending_overflow` beside the table, under the same lock, and the tick retires that too. `signerReady` is false for a bunker while all eight slots are taken, so a press is refused before it moves anything. A signature that comes back from Notary is checked before it is published: it must verify and it must be signed by the account that is signed in.

Refused text comes back by one rule in `drafts.zig`, for the composer and the reply box alike. It goes into its box only when the box is empty and nothing is held there for the post pause (`giveDraftBack`, `putBackRefusedReply`). Otherwise it is kept aside in memory, up to `refused_slots`, and a line under the box (`refusedNote` in `view_compose.zig`) says how many, with Copy and Dismiss. A reply to a thread that is not open is kept for that thread. Copy is the only thing that writes refused text to the clipboard, and the texts are let go only when the clipboard answers that it has them (`refusedCopied`). A note's content warning stays with its own text.

A separate pause exists on the near side of the signature. When the reader sets a post delay, `compose.g_post_due_s` holds a note in the composer and `firePost` signs it on the tick when the clock runs out, because a kind 5 deletion after publishing is only a request.

## Threads and locks

Plaza is a UI thread plus detached workers: the relay threads above, the keeper, the publish and fetch workers, the NIP-46 listener, and short-lived threads for sweeps and hints. Shared state is process globals (`g_` names), and the model stays plain view state.

Only the UI thread touches the `Model`, the `Effects` handle (nothing else can start a timer, a fetch or a spawn), the composer and drafts, the refused texts kept beside a box, the `g_helper_sign` slot, the copies the not-stored hold keeps, the picture slots and the registry, and `g_io`, which is set once in `main`. A worker that needs the UI to do something sets a flag or queues a record and waits for the next tick: arrivals are a queue of ids, a failed sign is a `failed` bit on a slot, the relay-list sweep ends by setting `g_relay_ranks_dirty`.

The globals the reader threads do touch are the store itself (LMDB serializes writers and hands readers a snapshot, and each `nostr.store` call is its own transaction), the relay table (`lockRelayTable`, read through `relaySnapshot`), the follow set, the discovered and refused relay tables (`lockDiscovered`, `lockRefused`), the feed arrival queue, the engagement table, the inbox, the seen-on table in `relay_hints.zig`, the mute, bookmark and media-server lists, the decrypted halves of the private lists (`lockHalves` in `private_lists.zig`, taken after `pendingLock` where both are held, and read out as copies), the NIP-42 state (`g_auth_lock`), the backup ring in `store_glue.zig`, the pending table and its overflow (`pendingLock`), the feed-watch set in `ingest.zig`, the outbox queue, the one-shot sockets in `relay_conn.zig`, the place feed's ids, the suggested relays, the own-profile and profile-paging state, and the people-search inbox and index. Each of these has its own lock beside it. Connection status per slot is an array of atomics, and so are the generation counters that tell a reader its question has changed (`followGeneration`, `identityGeneration`, the bunker's `g_remote_generation`), the not-stored hold's stamps, and the private bookmark announcement that the bunker listener's publish sets.

The locks are hand-rolled spinlocks: an `std.atomic.Value(bool)` taken with `cmpxchgWeak` in a loop. They fit because every critical section is a short scan or a fixed-size copy with no I/O inside it, and `std.Io.Mutex` would need an `Io` handed through threads that deliberately never share one.

They are not reentrant, and that is the rule that matters. Taking a lock and then calling a helper that takes the same lock does not fail: it hangs. So code that holds one copies what it needs and releases it before calling anything else. `applyUndo` snapshots the follow set under the lock and calls `setFollows`, which takes the same lock, only after unlocking. The keeper reads `discoveredSnapshot` before it takes a live-relay lock, because holding two locks in an order nothing else agrees on is how the pool once deadlocked. A new lock gets its own, taken alone, and does not nest inside another.

Each live relay is also offered to the keeper under a per-slot lock (`offerLiveRelay`, `lockLiveRelay`). The owning thread withdraws its connection before freeing it, and the keeper holds the lock for as long as it touches the pointer, which is what makes a ping or a half-close safe against a connection being torn down. The bunker listener offers its socket with `offerBunkerListener`, which checks the pairing's generation and stores the socket in one step under that lock, so a listener for a pairing that has ended can never take the slot of the one that replaced it.

## Effects and keys

A side effect starts from `update` or `boot` through `fx`: `fx.fetch`, `fx.spawn`, `fx.startTimer`, a clipboard write. Each takes a numeric key and a message constructor for the result (`Effects.responseMsg(.helper_signed)`, `Effects.exitMsg(.notary_exited)`). The toolkit refuses a second effect on a key that is still live and reports it as a `.rejected` outcome, so keys are a shared namespace that is allocated on purpose.

Fixed keys are single numbers: the timers (1, 2, 3), the clipboard copies from 100 to 106 (106 is Copy under a box that keeps refused text), the update check at 110, the keyholder's spawn, poll, setup, sign and window keys from 40 to 44 with a relay's NIP-42 sign at 45, the private-bookmark seal at 64, the profile banner at 5000 and a place's logo at 5200. Per-item work uses a base plus a slot: the private-list decrypts from 48 (with a sequence number above the low 16 bits), avatars from 1000, media from 2000, NIP-05 checks from 3000, link previews from 4000, warm-ahead fetches at 6000 and 7000, with the NIP-05 search lookups at `0x0500_0000`. `tuning.zig` holds most of them, and the rest sit beside the code that uses them (`helper_sign_key` in `keyholder.zig`, `helper_auth_key` in `relay_auth.zig`, `private_half_key_base` and `private_seal_key` in `private_lists.zig`, `banner_fetch_key` in `view_profile.zig`, `place_logo_fetch_key` in `view_place.zig`). Everything that takes a key must stay inside its range, so add a new one next to its neighbours and not at an arbitrary number.

The helper signs on one key, so only one Notary signature is out at a time, and a bunker has eight request slots. `signerReady` says whether one can be started. A press that gets "not now" moves nothing and says the signer is busy; a write the app queued itself, such as the relay list, stays pending and the tick tries it again.

Keyboard activation goes through `onKey` and `keyActivation`. The toolkit gives Tab a stop, a focus ring and Return or Space activation only to its own controls and to `list_item`, so a row that answers a press is built with `pressRow` in `view_note.zig`, and a test walks every screen and fails on a bare press.

## Rules that shape the code

**Never build a write on a record older than the one that went out.** Notary's signature is published even when the store refuses it, and then the store is a write behind the relays. `noteOwnWriteUnstored` (from `ingestAndPublish`) holds a copy of what went out, by kind, and while it is held that copy is the base every write of the kind builds on (`ownWriteBase` in `own_profile.zig`, used by every list, profile and name write instead of `ownRecordJson`). The tick's `retryUnstoredOwnWrites` offers the copy to the store again, after two seconds and then twice as long each time up to five minutes, and the hold goes only once the store has a record of that kind at least as new, normally the same event coming back from a relay. A held record that could not be copied refuses writes of its kind with a reason, since there is nothing to build on. The copy is only touched on the UI thread; the stamps are atomics because a reader thread clears them from the ingest path.

**Never write a replaceable list over one that was not read back.** A kind 0, 3, 10000, 10002 or 10063 replaces the reader's data on every relay, and an empty answer from a relay means only that relay has none. `own_lists.zig` decides when a write may start (`canWriteFollows`, `noHistoryKnown`, the `ListKind` read state), and the read state counts a relay as having answered only when its EOSE came from the current subscription and none of the reader's own records was dropped (`SelfRead`). A key made by this app has provably no history. For any other account with nothing found, `askFreshFirst` asks the reader before starting a list from nothing and says what it would replace. A follow builds on the stored contact list and keeps every tag and the content it does not own. And because the store replaces a superseded record in the same transaction, `plazaIngest` keeps the last three replaced versions of each of the reader's own lists (`keepReplaced`, read back by `ownListBackups`).

**Dial only public relay addresses that came from other people's data.** A relay named by a note, an `nevent`, a profile or an author's relay list is dialled unattended, so `isSafeRelayUrl` keeps the string sane first (`wss://` only, no control characters, bounded), and `isPublicRelayUrl` then refuses a login in the address, a bracketed IPv6 address, a name with no dot, private and local suffixes including `.onion`, and any numeric address that is not a plain public dotted quad. The same rule runs the other way for hints Plaza writes: `isHintableRelay` refuses private hosts and any URL with a query or fragment, which usually carries an access token.

**Fetch nothing for a covered note.** A note whose author marked it sensitive (NIP-36) stays covered until the reader presses it, unless they changed the setting. `noteCovered` and `quoteCovered` are the one answer the text, the pictures, the link card and the row height all ask, and `feed_media.zig` and `link_preview.zig` return before they start a fetch for a covered note. With media previews off (`prefs.mediaPreviews`), nothing a note points at is fetched until the reader asks for that note.

**Pictures go through a resizing proxy by default.** The registry decodes at most 512 by 512 and the fetch effect caps a body at 256 KiB, so with the proxy on, `mediaUrl` sends every picture through a weserv-compatible proxy (`prefs.mediaProxy` and `mediaProxyOn`, a public one by default), a place's logo included. Only with it off is a host that resizes for itself asked for a smaller copy. The reader can switch it off, or point it at their own. When a proxy refuses a host by policy, `rememberProxyRefusal` records the host and `prefs.g_media_direct_fallback` ("Ask the host when the proxy refuses" in Settings) decides whether that picture is fetched directly, which tells that host the reader's address; turning it off stops direct fetches at once. A picture address whose host is spelled as a loopback or LAN address is never requested (`isPublicMediaUrl`, the same host rule relays use).

**Validate what comes from a relay at the boundary.** Events are verified before they count (a forged relay list does not become the reader's routing), a relay's inbox or engagement events are verified before they are shown, and every wait on a socket has a deadline.

## How it is tested

The unit tests live in `src/tests/<area>.zig`, one file for the code whose behaviour it checks, and `src/tests.zig` is the harness: shared fixtures such as a store in a temporary directory, `buildTree` (the real view, as shipped), and `app_sources`, the list of source files that the tests which read source text use. A new file is imported from `main.zig` and added to `app_sources`, and a test fails on any file `main.zig` imports that the list does not name. Behaviour is reached through `...ForTest` functions each module exposes, and the key paths have stand-ins, so the keyholder test drives `handleHelperSigned` with a body instead of a socket.

Window and layout contracts are tested against the manifest. `build.zig` reads `app.zon` and hands the test binary the window's `min_width`, width, height and the app version, and the sweep tests lay out every screen from exactly that width and fail if the content outgrows it.

`zig build model-contract` writes the typed contract of `Model` and `Msg`, and `native check` reads it to validate the markup bindings and the manifest. Without the contract `native check` quietly downgrades to a structural pass, so CI fails the step if it says so. `Model.view_unbound` and `Msg.view_unbound` list the names that are used from Zig and not from markup.

The test binary does not compile every network path. Code that dials or spawns is behind `builtin.is_test`, `networkAllowed` and `relayFetchAllowed`, which are comptime false under test, so a unit test cannot open a socket and the code after such a check is not analysed. A compile error confined to those paths passes `zig build test` and fails in the app build, so `native build` or `zig build` on the app is part of every change. A test, `no thread that dials a relay is spawned without a gate above it`, reads the source and fails on a dialling worker spawned with no gate above it.

CI (`.github/workflows/ci.yml`) has these jobs. `app` runs on macOS: emit the model contract, `native check`, `native test`, an optimized link of the model-contract tool, `native build`, and `zig fmt --check src`. `portability` runs on Linux: `zig build`, `zig build test`, `zig build test -Doptimize=ReleaseFast` (the mode that ships, and the only job where the frame budgets run), and the format check. `linux-package` packages both architectures with the pinned Notary. `release-notes` checks that the version in `app.zon` matches `.github/RELEASE_NOTES.md`, and that the installers are pure ASCII and parse. `acceptance` runs two journeys of `scripts/acceptance.sh` against a real build, a cold start into a feed and the packaged bundle. The remaining journeys publish to relays and run by hand, and `scripts/frame-budget.sh` measures frame cost against its budgets.

## Where to start reading

1. `src/main.zig`: `Model`, `Msg`, `update` and `boot`, to see what the app can do and how a message becomes an effect.
2. `src/ingest.zig`, `src/store_glue.zig` and `src/feed_state.zig`: relay to store to feed.
3. `src/routing.zig`: which relays are asked about whom.
4. `src/compose.zig` and `src/outbox.zig`: the write path. Then `src/keyholder.zig` and `src/remote_signer.zig` for signing.
5. `src/own_lists.zig` and `src/follows.zig`: the rule about replaceable lists, in the code that enforces it.
6. A `view_<area>.zig` and its `src/tests/view_<area>.zig`, then `src/tests.zig`, for how a screen is built and checked.
