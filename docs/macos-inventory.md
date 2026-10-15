# What was built on macOS, and what went wrong building it

An audit of the macOS app, produced before the iOS port so the port had
something to be measured against. Two inventories: every user-facing feature,
and every bug and hard limit discovered while building them.

The bugs are the more useful half. A port re-implements mechanisms, and the
fastest way to reintroduce a bug is not to know it was ever fixed.

Full detail for each trap lives in [`engineering-notes.md`](engineering-notes.md) under *Things that will bite
you*; this is the index and the shape of the thing.

---

## 1. Feature inventory

82 user-facing features across nine areas. Portability is judged against iOS.

### Core engine — 7 features
The headless `music.youtube.com` webview, the injected bridge, a 250 ms
snapshot push plus an immediate `store.subscribe` push, a command channel, an
async query channel with a continuation table, an in-page InnerTube client that
signs its own `SAPISIDHASH`, App Nap suppression, and the `PRISM_EVAL` console.

Nearly all portable. `ProcessInfo.beginActivity` is macOS-only; the console
needed a container path rather than `~`.

### Playback and transport — 6
Play/pause/next/previous/seek, volume and mute, a scrubber with `scrubOverride`
so ticks do not fight the thumb, shuffle and repeat (repeat by clicking
YouTube's own button so its internal state stays in agreement), `playbackRate`
with `preservesPitch`, and a high-resolution live clock read for crossfade
alignment.

Volume was flagged in this audit as **the single highest risk for iOS** — and
that call was right. See §2.

### Queue — 8
Live mirror, jump, remove (including the playing track), reorder, clear,
add-to-queue and play-next, a 20-deep undo stack, and the panel itself with
drag-to-reorder, context menu, and auto-scroll.

All portable. Every one of these is a Redux `store.dispatch`, not an endpoint —
see §2, which is the reason.

### Search, library, navigation — 12
Filter chips using YouTube's own `params`, an all-scope fan-out fired
concurrently, top-result promotion, history-aware re-ranking, browseId-first
classification, radio-on-play, library shelves, playlist/album/artist detail
with three possible header shapes, an unwinding back stack, per-row actions,
explicit badges, downloads.

All portable.

### Listening history and stats — 11
A local log that commits only after 25 s heard, stats over four windows,
provenance marking, Google Takeout import, an idempotent merge, Last.fm
scrobbling with an on-disk retry queue and Keychain-backed secrets, pulling
plays back from Last.fm, and the For You page.

Logic all portable; `NSOpenPanel` and `NSWorkspace.open` needed replacing.

### Lyrics — 3
Synced lyrics from LRCLIB with an untimed YouTube fallback, and a view that
lights and centres the active line.

### System integration — 7
Media keys and the Now Playing tile, artwork publishing, output switching, the
notch island, compact mode, Escape-to-exit, menu commands, a runtime Dock icon.

**The least portable cluster.** Output switching, the notch island, compact
mode, menu commands and the Dock icon have no iOS counterpart.

### Transitions and AutoMix — 16
Crossfade, the shadow webview, readiness polling, an equal-power fade, the
handover with learned-latency alignment, single-exit teardown, a watchdog,
arming policy, the AutoMix planner, `TempoRamp`, `MixCapabilities`, the Deezer
tempo source, the settings UI, 81 assertions, and the fade trace log.

The planner is pure Swift and ports untouched. Execution needs a gain control.

### Visuals — 9
The Liquid Glass shell, the backdrop, artwork palette extraction, the block
equalizer, music video mode, video fill by moving the webview, the video scrim,
the status toast, the wordmark.

---

## 2. Bug and trap inventory

88 entries. Grouped by what they teach, because several are the same lesson
wearing different clothes.

### The reporting-success trap
`queueAddEndpoint` accepts every dispatch method, returns `true`, and changes
nothing — while its `onEmptyQueue` fallback fires anyway and hijacks playback.
The fix was to stop trusting return values and **measure the queue length
before and after**. Queue writes go through `store.dispatch({type:'ADD_ITEMS'})`
with a renderer fetched from `/youtubei/v1/next`.

The same shape recurs: YouTube's `setVolume` reports a gain it never applied;
`resolveCommand` accepts an `offlineVideoEndpoint` and no download appears.
**When the API reports success, check the world.**

### Objects, not indices
`removeItem` and `selectQueueItem` resolve their argument with
`getItems().findIndex(c => e_(c) === n)`, so an integer matches nothing. This
was *the* queue bug. Related: `MOVE_ITEM`'s `toIndex` is post-splice, `CLEAR`'s
payload is a keep-list not a kill-list, and nothing renumbers the selection
after an edit — so every edit crossing the playing track left the highlight one
row out until Prism dispatched `SET_INDEX` itself.

### WebKit suspends media it cannot see
Twice. The engine webview must stay mounted at full size; the crossfade shadow
must be in the window hierarchy at a real size with near-zero alpha. The shadow
spent an entire fade at player state −1 while its volume ramped dutifully from
0 to 97 — the ramp was real, the audio was not.

### The maths of a blend
Equal-power for song-to-song (uncorrelated, powers add); **linear** for the
handover (two players carrying identical aligned audio, amplitudes add, so
`cos + sin` peaks at √2 — a +3 dB bump exactly at the seam).

### Feedback loops beat damping
Video fill was a runaway, not a wobble: taller webview → taller viewport →
video pushed further down → reads as a bigger inset → grows again. `top` climbed
817 → 1420 in six steps. Two damping attempts failed because nothing was
oscillating around a fixed point. The fix was to measure with **no placement
applied**, then correct at most three times.

### Loading a track resets player state
Volume *and* `playbackRate` both reset when a new track loads. A `setVolume(0)`
issued before a skip does not survive it, so the incoming track came up at full
volume on 0:00 and replayed its opening. `mute()` survives; re-assert on every
poll.

### Measure the mechanism, not the picture
The recurring lesson. `FEmusic_history` was documented as returning an empty
payload; re-measured, it returns 2.3 MB and 200 tracks — but deduplicated, with
no timestamps and no continuation tokens, so still useless for statistics, for
entirely different reasons than the ones first written down.

Likewise `MixCapabilities` declared `canTimeStretch: false` on the belief that a
web player could only change volume and seek. Measured: 1.06 set, 1.060 played,
exact, pitch preserved. **Every rate change costs 350–500 ms of frozen audio**,
flat regardless of size — which is why the tempo glide is stepped and hidden
rather than smooth.

### Data is thinner than it looks
`octane`, 13 tracks, all found on Deezer, **tempo known for 0 of 13**. Deezer
publishes `bpm: 0` for whole catalogues. A design that only acts when it knows
both tempos would never fire on real music.

### SwiftUI traps
`GlassEffectContainer` cannot lay out a shell. `scaledToFill()` without a frame
inflates its parent — twice, in two different places. Pinning row identity to a
slot silently breaks reordering. `.onDrag`/`.onDrop` never committed. State
written from a bare `Task {}` is dropped. `.onChange` alone never fires for the
artwork already playing at launch. `@Observable` rejects `lazy`. Row actions are
never hover-only, because the hover target covers their own coordinates.

### Things that cannot be done at all
No PCM: the audio is decoded inside WebKit from a cross-origin stream, so there
is no `AVAudioNode` to tap and a Web Audio `AnalyserNode` returns silence *and
mutes output*. Therefore no loudness measurement, no local BPM or key detection.
AcousticBrainz is dead. YouTube's lyrics carry no cue ranges in any client
context, including the iOS one.

---

## 3. What this predicted about the port

The audit ranked iOS risks before any iOS code existed. Two calls were right and
worth recording:

1. **Volume was named the top risk.** Correct. iOS WebKit ignores
   `HTMLMediaElement.volume` once media is attached, so crossfade cannot run.
2. **The `nonisolated` artwork handler was flagged as a MediaPlayer behaviour,
   not a macOS one.** Correct — it survived the port unchanged and would have
   crashed iOS identically.

Two more things the audit could not have known, both found later by driving the
built app.

**Page coordinates do not map to points on a phone.** A 100x100 CSS px probe
drawn by the page measured 98x84 on screen — 1:1 across, squashed to 0.84 down —
with `visualViewport.scale` reporting 1. Video mode had been ported as "measure
where the video is, transform the webview so it lands on a reserved slot, mask
the rest". That premise is false on iOS and no correction to the arithmetic
saved it; the port now makes the page's containers transparent instead, so there
is nothing to place and nothing to mask. Full detail in `README.md`.

**Sign-in had no sign-in page.** The button revealed the engine webview, which
sits on whatever playback left it on. Shared with macOS, so both platforms had
it and neither had noticed: the Mac's sidebar button did the same thing.

And one the audit could not have known either: `History.observe` captured a track's metadata at the moment of transition,
when `getVideoData()` has the new `video_id` but the *previous* title. Every
play was logged under the previous song's name — on both platforms, for the
whole life of the feature, invisible in the player and wrong in every statistic.
