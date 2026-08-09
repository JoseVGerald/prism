# Prism

A native YouTube Music client for macOS and iPhone, with a real Liquid Glass interface.

Not a browser wrapper with a skin on it. Prism runs the actual `music.youtube.com`
in a webview you never see, and drives it from a SwiftUI app through an injected
JavaScript bridge. Playback, your account, and Premium all come from the real
service — so there is no stream-extraction hack to break when YouTube changes
something.

## What was built, and what went wrong building it

[`docs/macos-inventory.md`](docs/macos-inventory.md) — 82 features across nine
areas, and the 88 bugs and hard limits found while building them, grouped by the
lesson each one teaches rather than by the order they appeared.

It was written *before* the iOS port so the port had something to be measured
against, and two of its risk calls turned out to matter: volume was named the
top iOS risk (correct — it is why crossfade cannot run there), and the
`nonisolated` artwork handler was correctly identified as a MediaPlayer
behaviour rather than a macOS one, so it survived the port unchanged instead of
crashing iOS identically.

## Two platforms, one codebase

Prism runs on macOS and on iPhone. The engine, the injected bridge, the queue
mechanics, history, stats, search ranking and the whole of AutoMix are the same
files on both — they talk to a webview and to plain Swift types, neither of
which is platform-specific. Only the arrangement is rebuilt for the phone: a
sidebar becomes a tab bar, a side-by-side queue becomes a sheet, and a transport
revealed on hover becomes one that is simply always there.

```bash
./build.sh && open Prism.app            # macOS
./build-ios.sh --run                    # iPhone 16 Pro simulator
```

`build-ios.sh` compiles with `swiftc` against the simulator SDK and assembles
the bundle by hand, exactly as `build.sh` does — no Xcode project, no pbxproj.
`AutoMixCore` is a module on macOS and compiled straight in on iOS, which is why
its import is wrapped in `#if canImport(AutoMixCore)`.

### What iOS does not get, and why it is absent rather than faked

| Feature | Why |
| --- | --- |
| Notch island | An `NSPanel` pinned to `auxiliaryTopLeftArea`. iOS's Dynamic Island is ActivityKit Live Activities — a different feature with a different lifecycle, not a port of this one. |
| Output switching | CoreAudio's default-device API does not exist on iOS. Routing belongs to the system, so the player uses `AVRoutePickerView` instead. |
| System-audio probe | ScreenCaptureKit is macOS-only and no iOS API hands one app another's audio. |
| Compact mode, desktop blur | Both are ideas about windows. There is nothing behind an iOS app to sample, so `DesktopBlur` is a plain material there rather than a still image pretending to be live translucency. |
| Menu commands, Dock icon | No menu bar; an iOS icon is a static bundle asset. |

Platform differences are confined to `Sources/Prism/Platform.swift` — the image
type, the colour maths, the webview host, and how a URL is opened. The rule is
to shim the *type*, never to fake the *feature*.

### iOS-specific requirements

Two things are load-bearing and easy to lose:

* **`UIBackgroundModes: audio` in Info.plist *and* an active
  `AVAudioSession(.playback)`.** Both are present and correct. They are *still*
  not enough — see "foreground-only" below — but removing either would break
  more than it already is.
* **`allowsInlineMediaPlayback = true`.** Without it the page is handed to the
  fullscreen native player and the bridge loses control of it entirely.

The shadow webview used for crossfade has the same rule as on macOS but iOS
enforces it harder: it must be in the window at a real size, so `mount()` uses
`insertSubview(_:at: 0)` with `alpha = 0.02`.

### Measure with media loaded, or do not measure at all

This section previously carried a table showing `video.volume = 0.25` reading
back as `0.25`, and concluded that crossfade would work on iOS. **That was
wrong, and the way it was wrong is the useful part:** the measurement was taken
on an idle page, before anything had loaded. Once real media is attached, WebKit
on iOS clamps the volume back to 1 and never fires a `volumechange`.

Re-measured with a track loaded (`readyState 4`, duration 232.8 s), three
consecutive trials:

| | Result |
| --- | --- |
| `v.volume = 0.2` | reads **0.2**, then **1** |
| `volumechange` events | **0** |
| `p.setVolume(20)` | `getVolume()` says **20**, element volume is **1** |
| `v.muted` | toggles and holds — the one gain lever that works |
| `playbackRate` 1.10 / 0.90 | media advanced 6.600 s / 5.401 s per 6 s wall — **exact** |
| `preservesPitch` | supported and writable |

YouTube's own wrapper **reports a gain it did not apply**, which is what makes
this trap worth naming: every ramp looks like it worked, in the logs and in the
API, while the audio never changes.

**So crossfade is off on iOS**, gated by `Transitions.isSupported`, and the UI
says why rather than offering a slider that does nothing. A fade driven by an
inert gain is not a quiet failure — both tracks would play at full volume for
the whole overlap and then cut, which is audibly *worse* than no crossfade.
Mute works, but mute is binary and a blend needs a ramp.

**The Web Audio route was tested and is worse than useless.** Routing the
element through `createMediaElementSource` → `GainNode` builds fine and the gain
holds its value, but the stream is cross-origin, so the graph receives silence —
analyser energy `sum 0, peak 0` at both gain 1.0 and 0.15 while the media clock
advanced 2.00 s. Since `createMediaElementSource` also *takes over* the
element's output, using it would mute playback entirely. Same taint that
defeated `AnalyserNode` on macOS.

So there is no gain lever on iOS at all: `volume` is ignored, YouTube's
`setVolume` lies, Web Audio silences, and `muted` is binary. `playbackRate` *is*
genuinely effective (measured 1.10 → 6.600 s of media per 6 s of wall clock), so
AutoMix's tempo machinery would survive intact if a gain mechanism is ever
found.

### Verifying the iOS UI without taps

`simctl` has no tap primitive, and the simulator panel that does needs a
permission this project cannot assume. Without a way in, every screen past the
launch tab is unverifiable — which is worse than a missing feature, because a
layout that breaks on the phone then ships silently.

`DebugDrive` solves it the same way `PRISM_EVAL` does: write a word into
`.prism-eval/ui` inside the app container and the app goes there.

```bash
C=$(xcrun simctl get_app_container "iPhone 16 Pro" com.gerald.prism.ios data)
printf 'search:blonde' > "$C/.prism-eval/ui"     # also: library, dashboard, player, queue, lyrics
xcrun simctl io "iPhone 16 Pro" screenshot shot.png
```

It found three real bugs that code review had not:

* **The Listening title rendered vertically, one letter per line.** The header
  put the title beside a segmented picker pinned to `width: 320` — wider than a
  phone's content area — so the title was squeezed to a few points. Now a
  `ViewThatFits`: side by side on a Mac, stacked on a phone.
* **The queue sheet never opened.** SwiftUI presents one sheet per view, and the
  player sheet's queue button set a second `isPresented` flag then dismissed
  itself; the dismissal had not finished, so the presentation was dropped. Now a
  single `Sheet` enum, so swapping one sheet for another is explicit.
* **The queue sheet was 290 pt wide in a full-width sheet**, because that is the
  Mac sidebar's width, and it drew "Queue" twice — once as a navigation title
  and once in its own header.
* **Track titles were truncated to "Rendezv…" and "Rosary (f…"** on album pages.
  Three inline action buttons plus a duration leave no room on a 393 pt screen.
  They are macOS-only now: every one of those actions is already in the
  long-press menu, which is the platform's own idiom rather than a consolation.

All seven screens have now been driven and looked at — For You, Search, Library,
Listening, the player sheet, the queue sheet and album detail — plus lyrics
mode. Four layout bugs, all of them invisible to code review and all of them
found within minutes of actually looking at the thing.

### Video mode on a phone is a different feature to video mode on a Mac

Porting it directly produced a string of wrong answers, each corrected by
looking at the screen rather than at the code. The last of them was the most
expensive and the most instructive, so it is written up last.

**The page's coordinates are not points, and no arithmetic survives that.**
For a while video mode worked by transforming the webview so the video landed
on a slot reserved in Prism's layout, then masking everything else away. It
needed one thing to be true — that a rectangle measured in the page could be
converted to a rectangle on screen — and on a phone it is not. A 100×100 CSS px
probe, drawn *by the page itself*, measured **98×84 pt on screen**: 1:1
horizontally, squashed to 0.84 vertically. Nothing in the page knows this;
`visualViewport.scale` reports 1 and `innerHeight` matches `clientHeight`.

Four attempts to model it all failed in different places, and the trail is worth
keeping because each step looked like the answer:

* The element box is not the picture — `object-fit: contain` letterboxes inside
  it (402×338 box, 402×226 picture). Correcting for that moved the band without
  removing it.
* Where the picture sits in the box could not be deduced. `getComputedStyle`
  said `50% 50%`; it measurably was not centred. `object-position: 50% 100%`
  *did* move it by exactly the predicted 56px, so the property is honoured — the
  default placement simply is not what it claims.
* `object-fit: cover`, which fills the box by definition, did not remove the
  shortfall either.
* Every attempt to read the webview's own frame fed back into itself, because
  SwiftUI's `.offset` moves the real frame: `view.frame`, `view.center`,
  `view.convert(_:to:)` and a `GeometryReader` in the webview's background all
  returned a value that already included the placement. Measured, the reported y
  went 105, then **1062**, climbing with each pass — the same runaway shape the
  macOS fill has to damp, in a new disguise.

The fix was to stop computing anything. Video mode now makes **every player
container transparent**, down to `#movie_player` itself, so the only thing the
page paints is the picture and Prism's backdrop shows through everywhere else.
The webview is not transformed, nothing is masked, and there is no measurement
to drift. The video sits where the page puts it — full width, at the top — and
Prism's own player fills the rest of the screen.

If you are tempted to reintroduce the slot-and-mask approach, re-run the 100×100
probe first.

**Two useful facts found on the way.** `.mask` is composited in the view's own
layout space and does *not* travel with a following `.offset`; an `.overlay` in
the same position *does*. And the black band under the video was never the video
— it was the mask extending past the page's own box.

**Do draw Prism's transport, and hide YouTube's.** An earlier build kept the
page's controls on the grounds that they are good on touch and two transports
would collide. The result was worse than either: the page's coloured header, its
tab strip and its scrubber all around a video with nowhere to be. Both platforms
now hide the page chrome and draw Prism's own.

The chrome-hiding list was also incomplete in a way selector-guessing could not
find. `ytmusic-player-controls` / `#player-controls` is a transport belonging to
the player *page*, distinct from the player bar and from the `.ytp-` chrome
inside the video, and nothing named it — so a second scrubber and a second set
of skip buttons drew straight across Prism's. It was found by walking the DOM
for anything visible in the band where the duplicates appeared, which is how it
should have been found the first time.

**A video is watched sideways, so landscape is the design and portrait is the
fallback.** The first port had that backwards. It laid the portrait stack —
title, artwork slot, scrubber, transport, button row — into 402pt of height and
the result was unusable: every row on top of the picture and on top of each
other, with the picture itself a small band behind them. `IOSVideoOverlay` is
built for landscape instead — controls pushed to the edges, nothing in the
middle, a scrim only where there is text — and portrait gets the same
arrangement with more room to breathe.

**WebKit's media layer does not paint into the box CSS gives it.** This is the
finding that explains every earlier failure in this section, and it took a
probe to see. Pin the `<video>` to the viewport —
`position: fixed; width: 100vw; height: 100dvh; object-fit: cover` — and the
element measures exactly 874×402, the whole viewport, while the compositor
paints the picture at roughly 801×219, centred, backdrop showing all round it.
The page is not at fault: a magenta `div` drawn by the page at those same
bounds spans the screen edge to edge. Only the video layer under-fills, and
nothing in the page reports where it actually lands.

So the picture is blown up from Swift instead. `videoBleed` is 2.6 in
landscape — a measured constant, arrived at by screenshot, because there is no
measurement to derive it from. Portrait keeps its natural width: filling a
19.5:9 screen with a 16:9 frame needs about 4.2× and what survives is an
unwatchable close-up.

**`.clipped()` was hiding the answer for three iterations.** A strip of backdrop
stayed down one long edge at 1.9×, 2.5× and 2.8×, never shrinking — which is
what gave it away, since a gap in *scaled* content would have closed as the
scale grew. `.clipped()` clips to the layout frame, and that frame is not the
whole screen even with the safe area escaped. Removing it filled the edge at
once, and dropped the factor needed from 2.8 to 2.6. Nothing needed clipping:
the overlay draws above and the backdrop below.

**Rotation needs a test hook.** `simctl` cannot turn the device and the panel's
tap primitive cannot reach the Simulator's menus, so the landscape layout — the
one video mode is actually *for* — could not be looked at at all. `DebugDrive`
now takes `landscape` and `portrait` and calls
`requestGeometryUpdate(.iOS(interfaceOrientations:))`.

**A CSS trap worth naming.** The rule hiding narrow-screen chrome was written
across several lines and joined with `\n`. Whitespace between `:is(...)` and
`:not(...)` is a **descendant combinator**, so it matched the *children* of
those elements instead of the elements themselves — measured: eight overlays
became three rather than none. On one line, zero. The offenders were
`#nav-bar-background` and `#player-bar-background`, which are separate elements
from the `ytmusic-nav-bar` and `ytmusic-player-bar` components already hidden.

### Nothing on iPhone ever asked for the library

The Library tab showed "Nothing in your library yet" on every launch, and the
Retry button beneath it worked every time. That shape — broken until you press
the thing that forces it — is worth recognising, because it means the fetch was
never started rather than failing.

`grep` found why: every caller of `loadLibraryIfNeeded()` lived in a macOS-only
file. The sidebar item called it, the menu command called it, and the iOS tab
just set `model.route = .library` and waited for data nobody had asked for. The
one exception was Retry, which calls it with `force: true`.

The fetch now belongs to `LibraryPane` itself, in a `.task`, so a new way of
reaching the pane cannot forget to start it.

Two things this hid, both confirmed working once the data arrived: playlist
artwork (it was never missing, just never requested) and playlist detail with
the Play-all button.

### Touching the webview crashed the app, and always had

Tapping anywhere on the sign-in page killed the process:

    *** Terminating app due to uncaught exception 'NSInvalidArgumentException',
    reason: '*** -[__NSArrayM insertObject:atIndex:]: object cannot be nil'
        -[UIGestureRecognizer _delayTouchesForEvent:inPhase:]
        -[UIGestureEnvironment _updateForEvent:window:]

UIKit's gesture machinery finding nil where a delayed touch should be. Not the
app's own state: reduced to the bare webview with no siblings, no chrome and no
modifiers, it still died on the first tap.

Four plausible causes were tried and cleared, recorded so nobody spends the
time again — the `scaleEffect` used for video bleed, the surrounding view tree,
hosting the shared `WKWebView` straight out of `makeUIView` rather than inside
a container it owns, and the missing `UIApplicationSceneManifest`. None of them.

The fix is to leave the crashing path unused: `EngineWebViewContainer` clears
`delaysTouchesBegan` / `delaysTouchesEnded` on every recognizer from the
webview's subtree up to the window. Delaying touches exists to let a gesture
win a race against the view beneath it, and there is no such race here — the
webview is interactive in exactly one situation and nothing competes for the
touch.

**This bug is as old as the iOS port.** The webview is hit-testable only during
sign-in, and until sign-in started loading a real form, the page behind that
overlay was a music video — nothing anyone would think to tap. Making sign-in
work is what made the crash reachable. A feature nobody could use was hiding a
crash nobody could hit.

### The sign-in button has to go somewhere you can sign in

Tapping **Sign in** used to reveal the engine's webview and nothing else. The
engine is parked wherever playback left it, which is normally the player — so
the button produced a music video with a "Sign in to YouTube Music, then come
back" bar over it and no sign-in form anywhere on screen. It looked like a dead
button and was reported as one.

`Engine.beginSignIn()` now navigates to Google's own form
(`accounts.google.com/ServiceLogin?service=youtube&continue=…`) before revealing
the view, and `endSignIn()` always reloads `music.youtube.com` on the way out —
always, because a completed sign-in lands there via `continue` and an abandoned
one leaves the webview on an accounts page with no player, and telling those
apart from the URL is guesswork.

It has to be the *same* webview: it carries the `.default()` data store, so a
login completed in a second webview would leave its cookies where the engine
cannot see them. Navigating away stops playback, which is the honest cost of
signing in, and video mode is turned off first so the injected stylesheet is not
left half-applied.

Google serves the form to the engine's desktop Safari user agent without the
"this browser may not be secure" block.

### The iOS 26 tab bar owns the bottom of the screen

The mini player drew on top of the tab bar's labels. Three arrangements, only
one of which is right:

* A sibling in a `VStack` drew *below* the bar, off the bottom of the screen.
* `.safeAreaInset(edge: .bottom)` drew *over* it. The inset is applied at the
  `TabView`'s own bottom edge, and in iOS 26 the tab bar is a floating glass
  capsule *inside* that edge rather than a strip below it — so the inset and the
  bar were handed the same band of screen.
* `.tabViewBottomAccessory` is the slot built for exactly this. It sits above
  the bar by construction, supplies its own glass, and shortens the pages by the
  right amount.

Two details. The accessory reserves its slot whatever the content is, so
returning an empty view left a bare glass capsule floating above the bar with
nothing playing — `tabViewBottomAccessory(isEnabled:)` (iOS 26.1, which is why
the deployment target is 26.1) is the fix. And with
`tabBarMinimizeBehavior(.onScrollDown)` the accessory collapses *into* the bar
on scroll, so the player reads `\.tabViewBottomAccessoryPlacement` and drops to
a title and one button when it is `.inline`.

While fixing it: the tab bar started on For You and the pane on
`AppModel.route`, which is Now Playing, so the highlight and the content
disagreed at launch.

### Three things only a full sweep found

Driving every screen in turn, rather than the one just changed, turned up three
bugs that each had a reason for hiding.

**Page chrome that only appears when the video is not playing.** Every check of
video mode had been made mid-song. Left on a buffering player, YouTube puts back
a poster frame with its own large play button in the middle of it and an info
button in the corner — `.ytp-cued-thumbnail-overlay`, `.ytp-large-play-button`,
`.ytp-cards-button`, none of which the hidden-chrome list named. If you are
auditing injected CSS, audit it in every player state, not just the one you
happen to be in.

**Lyrics drew across the Dynamic Island.** The pane is positioned correctly —
measured, it starts at y=62 — but it is *also* handed a 62pt top safe-area
inset, and a `ScrollView` honours that by drawing its content up through it.
Right for a list under a translucent bar, wrong for opaque text on a plain
backdrop. Two fixes failed before the third worked: moving the backdrop out of
the `ZStack` into a `.background` changed nothing, and `.safeAreaPadding(.top)`
only pushed the first line down far enough to still be legible across the
island, because a scroll view will always draw through whatever space it is
given. Fading the top edge with a `.mask` settles it for good — and is what a
lyric sheet should look like anyway.

Cover art hid this for the whole life of the feature: it is centred between two
spacers and never reaches the top edge.

**The dashboard's two columns do not fit a phone.** `Top artists` and
`Most played` side by side in 402pt leaves each about 180, and once
`Most played` has spent that on a rank, artwork and a play count there is
nothing left for the title — every row read `G…`, `Ri…`, `…`. A
`ViewThatFits` picks the horizontal arrangement only where it genuinely fits,
so the Mac keeps its two columns and the phone stacks them.

### The parity audit found one thing genuinely missing

A feature-by-feature macOS→iOS matrix (17 parity, 7 parity-unverified, 2
degraded, 8 absent-by-platform) turned up exactly one item that *should* work on
iOS and did not: **the Transitions UI was unreachable there.**

`CrossfadeControl` is only instantiated by `NowPlayingBar`, which is only
instantiated by `RootView` — a macOS-only file. So on iPhone there was no way to
discover that AutoMix exists, or why crossfade is off. Worse,
`Transitions.unsupportedReason` was written *specifically* to explain that to an
iOS user and `grep` found only its own declaration: nothing ever read it.

That contradicted the rule the feature was built on — off, and says why, rather
than running and sounding broken. There is now a Transitions sheet on the iOS
player that reads `unsupportedReason` and states plainly that tempo control
works while gain does not, so AutoMix's timing would return if a gain mechanism
ever appears.

### A snapshot must describe one track

The metadata-lag fix in `History` was incomplete, and a regression audit caught
the rest of it: a finished play could be logged with the **next** track's
artwork, while its videoId and title were correctly paired.

Cause: `snapshot()` built `track` from two sources that tick independently —
`getVideoData()` for the id and title, and the queue's selected row
(`currentEntry`) for artwork and duration. Mid-transition they describe
different songs, so the record was internally inconsistent before `History` ever
saw it. Choosing a later snapshot, which is what the `History` fix does, cannot
repair a snapshot that was already self-contradictory.

The queue row is now only borrowed from when `currentEntry.videoId` matches the
player's own, and the fallback is the thumbnail derived from the id itself,
which cannot disagree with the track it belongs to. Shared code, so macOS had
this too.

### Three bugs an independent tester found that I did not

Worth recording because none were visible in the UI being looked at.

**The listening log filed every play under the previous song's name.**
`getVideoData()` updates `video_id` a tick or two *before* `title` and
`author`, so the snapshot that first announces a new track still carries the
old one's metadata. `History.observe` captured `currentTrack` only at the
transition and never refreshed it, so the id was always right and the name
always wrong:

```
dQw4w9WgXcQ (Never Gonna Give You Up) -> "Unknown", ""
3JZ_D3ELwOQ (Flexin' On Ya)           -> "Never Gonna Give You Up"
9bZkp7q19f0 (Gangnam Style)           -> "Flexin' On Ya (2014)"
```

Invisible in the player, which reads the live snapshot; it only surfaced in
Listening, top artists and recently-played — every one of which was silently
mislabelled. **This was shared code, so macOS had it too.** The id identifies
the play; the rest is now taken from the newest snapshot right up to flush.

**Every artist page had a black header photo.** `upscale()` rewrote any
`=wNNN-hNNN` thumbnail to a square. Cover art is square already so this was
harmless there, but an artist's immersive header is a wide banner crop
(`w540-h225`), and asking the CDN for a square of one returns HTTP 200 with a
**fully black JPEG** — confirmed by sampling the decoded pixels, average
brightness 0. `upscale` now preserves the source aspect ratio.

**The player and lyrics froze on a stale track while audio kept going.** The
bridge was posting correct snapshots every 250 ms throughout — verified by
hooking `postMessage` — so the break was on the SwiftUI side. Cause: every tab
rendered the *same* `pane`, whose content is chosen by `model.route`, giving
five structurally identical subtrees that differ only by tab item. SwiftUI keeps
them all alive and may serve a cached one. Only the selected tab builds the pane
now, so there is one live instance and nothing stale to hand back.

### A TabView paints over everything behind it

This one cost two separate bugs. Anything placed behind a `TabView` in an
enclosing `ZStack` is covered by the TabView's own opaque background: the app
rendered flat black everywhere except inside a presented sheet, which is not in
the TabView and therefore looked right. The backdrop now lives *inside* the tab
page. Video mode hit the same wall — frames were demonstrably decoding
(1015 → 1053 in three seconds, none dropped) while the screen showed black — and
is solved by taking the TabView out of the picture entirely rather than fighting
the layering.

Related: a mini player placed as a `VStack` sibling of a `TabView` renders
*below* the tab bar. It has to be a `safeAreaInset(edge: .bottom)`, which also
shortens the pages by the right amount.

### Playback on iPhone is foreground-only, and that is architectural

Backgrounding the app stops the music after about 1.5 s:

```
MediaElementSession::beginInterruption(... type = EnteringBackground)
WebProcessProxy::updateAudibleMediaAssertions: Releasing MediaPlayback assertion
```

This is not a missing entitlement. The audio is decoded in WebKit's WebContent
process, not the app's, and WebKit interrupts its own media on background as a
matter of policy. Three fixes were tried and measured:

| Attempt | Result |
| --- | --- |
| `UIBackgroundModes: audio` + active `AVAudioSession(.playback)` | The **app** process genuinely survives — verified still running at 1:24 elapsed while backgrounded. WebKit cuts the media regardless. |
| Silent `AVAudioEngine` keep-alive, to make the app an audible-media client in its own right | No change. Removed rather than left burning battery for nothing. |
| Picture-in-Picture, the sanctioned route for web media to continue backgrounded | `webkitSupportsPresentationMode('picture-in-picture')` returns **false** for YouTube's element. |

The only remaining route is extracting the stream and playing it through
`AVPlayer` — exactly what this project refuses to do, since not extracting is
the reason nothing here breaks when YouTube changes. So on iPhone, playback is
foreground-only. That is a consequence of hosting the real service in a webview,
not a bug waiting to be fixed.

The debug console works on iOS too: launch with
`SIMCTL_CHILD_PRISM_EVAL=1 xcrun simctl launch "iPhone 16 Pro" com.gerald.prism.ios`
and drive it through the app container's `.prism-eval/in.js`
(`xcrun simctl get_app_container "iPhone 16 Pro" com.gerald.prism.ios data`).

## Build and run

```bash
./build.sh && open Prism.app
```

Needs macOS 26+ and the Xcode Command Line Tools. No Xcode, Node, or Homebrew.

**Launch it with `open`, not by running the binary.** Executing
`Prism.app/Contents/MacOS/Prism` from a shell starts a process that never
connects to the window server: no window, no webview, no engine — it just sits
there at 0% CPU looking alive. Every "the app isn't responding to anything"
dead end traced back to this.

If an Xcode update has reset the licence agreement, `swift build` refuses to run
until someone types `sudo xcodebuild -license`. `build.sh` detects that (by
probing `swift -version`, since `xcodebuild -version` still succeeds in that
state) and falls back to the Command Line Tools toolchain, which ships the same
macOS 26 SDK.

### Debug console

```bash
open --env PRISM_EVAL=1 Prism.app
echo 'return document.querySelector("ytmusic-player-queue").queue.getItems().length' > ~/.prism-eval/in.js
cat ~/.prism-eval/out.json
```

With `PRISM_EVAL=1` the engine watches `~/.prism-eval/in.js`, runs whatever
lands there in the page (top-level `await` allowed), and writes the JSON result
to `out.json`. Every wrong conclusion in this project's history came from
reading a screenshot instead of asking the page what it actually did; this is
the cheap way to ask.

Crossfade also writes `~/.prism-eval/fade.log`. The handle is opened once at
launch and held at its own offset, so **neither deleting nor truncating that
file while Prism is running does what you want**:

* *Deleting* it sends the trace to an unlinked inode — the writes vanish.
* *Truncating* it (`: > fade.log`) leaves the handle's offset where it was, so
  the next write lands past the new end and the file becomes **sparse**. It now
  begins with thousands of NUL bytes, `grep` decides it is binary and prints
  nothing, and the log looks empty when it is not. `strings fade.log` shows the
  entries that were there all along. This cost a debugging cycle: a transition
  that had worked perfectly read as "no fade happened".

Restart the app to get a clean log, or just read to the end of the existing one.

## First launch

Click **Sign in** in the sidebar. The real YouTube Music page comes to the
front; log into Google, then hit **Done**. The session persists across launches,
so this is a one-time step.

## Features

**Playback** — play/pause, next, previous, draggable scrubber, volume, shuffle,
repeat. All state mirrored live from the engine.

**Queue** — live contents, click any row to jump, remove, add to queue, play
next, shuffle, and clear (which keeps whatever is playing). Drag a row to
reorder it: the row lifts and the list parts around it. Right-click any row for
Play / Move to Top / Up / Down / Bottom / Download / Remove — the reliable way
to shift something the length of a long queue. Auto-scrolls to the current
track.

**For You** — the landing page the first time Prism runs, and one click on the
wordmark after that. Recently played, suggestions seeded from artists you
actually listen to, and a month-at-a-glance strip.

**Listening** — your own stats, every day of the year rather than once in
December: hours, plays, distinct artists, day streak, a daily activity chart,
top artists and most-played tracks over 7 days / 30 days / 12 months / all time.
Import a Google Takeout export to fill in everything you listened to before
Prism existed, on any device, and connect Last.fm to carry your plays off this
machine. The page shows where its numbers come from and marks any total that
rests on an estimate.

**Lyrics** — synced lines that light up and centre themselves as the track
plays, from LRCLIB, falling back to YouTube's untimed sheet. Click any timed
line to jump there.

**Notch island** — always on, no toggle. On a notched Mac, cover art sits to
the left of the notch and waves to the right while music plays. Hover for about
half a second and it drops into an island: art centred, waves flanking it,
shuffle / previous / play / next / repeat underneath, a progress hairline and a
peek at what is up next. It only exists while a track is loaded, so an idle
notch behaves exactly like stock macOS. Content starts `notchHeight + 14` below
the top of the panel — the bezel physically covers the top, and clearing only
the notch height left the artwork butted against it.

**Room controls** — the sidebar picker lists every audio output with Bluetooth
first and moves system audio to whichever you choose.

**Media keys and Now Playing** — the keys, Control Center and the Now Playing
tile drive Prism with the correct title, artist and artwork. In-app shortcuts
live under the Playback and Go menus.

**Transitions** — crossfade of 6–16s (or off; there is nothing shorter, because
under six seconds it is a fade rather than a mix), plus **AutoMix**: the length
comes from both tracks' tempos as a musical phrase, and the two tracks are bent
towards one shared tempo so their beats line up through the overlap. When no
tempo is known — which is most of the time — the outgoing track still eases into
the mix. Toggle the bend off if you would rather it did not.

**Search** — filter chips across the top (All / Songs / Music videos / Albums /
Artists / Playlists), YouTube's own **Top result** promoted above everything,
then songs, albums and artists. Per-row play / play-next / add-to-queue /
download, and an explicit badge where YouTube marks one. Songs are capped at six
before the album and artist rows, so those are not buried twenty results down;
the rest follow underneath. Searching an album name leads with the album rather
than with a track that happens to sit inside it.
Results are re-ranked against your own listening: searching "Power" put a
Monkey Safari remix and a reupload called "Kanye West - POWER" above the actual
track, because the raw feed is returned in document order. Ranking is a sort and
never a filter — an exact title match still beats familiarity, so a song by
someone you have never played is still reachable by name.

**Playing a song starts a radio.** A bare `watchEndpoint` builds a queue of
exactly one: nothing follows it, and crossfade cannot arm because there is no
next track to preload. Verified live — playing a search result took the queue
from 1 to 50. Right-click any row for *Play just this song* to opt out.

**Library** — your playlists and albums, opened into a track list with a Play
button that queues the whole thing in one shot via its playlistId.

**Compact mode** — click the cover art. The sidebar collapses to an icon rail,
the queue closes, the art centers, and a block equalizer flanks it on both
sides. Transport fades in on mouse movement and hides after ~2.6s idle. Click
the art again or use the collapse button to exit.

**Artwork-driven colour** — the album art is sampled into top/middle/bottom
bands and drives both the backdrop and the equalizer gradient.

**Music video mode** — when the current track carries real picture (any
`MUSIC_VIDEO_TYPE` other than `ATV`, which is the static-art audio version), a
*Music video* toggle appears under the title and in the compact rail. Turning it
on plays the video as the app's background: the sidebar, queue and transport
stay frosted over it while the Now Playing pane goes fully clear, so the picture
reads sharply through the middle. Toggling back restores the cover art without
interrupting playback.

## AutoMix

`Sources/AutoMixCore` is a standalone library with no UI and no WebKit: Camelot
key notation and a compatibility matrix, tempo matching with half/double-time
folding, phrase-length selection, blend-curve generators, a bass-swap curve and the tempo glide.
81 assertions cover it.

```bash
swift run AutoMixTests
```

A plain executable rather than a `.testTarget`, because `swift test` on macOS
needs Xcode's XCTest runner and this machine's Xcode licence is unaccepted. It
exits non-zero on failure.

**Time-stretch works, and it is not free.** `MixCapabilities` is what the host
player can actually do. Prism declares `.webPlayer`. An earlier version
declared `.volumeAndSeekOnly` on the belief that a YouTube player could only
change volume and seek; that was wrong, and measuring it settled the question:

| Measured on the live player | Result |
| --- | --- |
| `preservesPitch` supported, default true | pitch-corrected stretch is real |
| set `playbackRate` 1.06 / 0.94 | effective 1.060 / 0.940, exact |
| YouTube's own `setPlaybackRate` | quantised to 0.25…2, useless for a 1.6% match |
| set on the `<video>` element instead | accepts any value |
| rate set while paused, then seek + play | survives both; still exact |
| **every rate change** | **freezes the media clock 350–500 ms** |
| a 0.5% change vs a 5% change | same cost — it is flat |
| `preservesPitch = false` | 510 ms → 370 ms; still not free |
| stepping every 250 ms | playback froze outright: clock stuck at 92.9 s for 3 s |

That last row is the design constraint. A smooth continuous glide is
impossible; the pipeline never gets long enough between flushes to make
progress. So a rate change is not a parameter to automate, it is an expensive
event to **hide**, and `TempoRamp` exists to place a small number of them where
nobody can hear them:

* The **incoming** track is set once while still paused — free, because a rate
  set on a paused element survives the seek and play that follow. This absorbs
  most of the tempo gap and is what makes the beats line up through the overlap.
* The **outgoing** track bends in two or three eased steps, all inside
  `maskWindow` (0.60…0.94 of the blend), where its own gain is 10–21 dB down
  and the incoming track is covering it. This is the audible lead-in.
* At the seam the rate is **abandoned**: loading a track resets it to 1 anyway,
  so the new song plays at its own true tempo, nothing accumulates across a
  playlist, and no freeze is ever spent on audible music to undo it.

Budgets are asymmetric on purpose — 3% for the outgoing track, whose bend is
heard while it happens, 6% for the incoming one, which is set silently. A gap
neither side can cover reports *no* glide rather than a bad one.

The bass swap still cannot run: there is no filter on the audio path. BPM and
key still cannot be computed here either — the audio is decoded inside WebKit
from a cross-origin stream, so there is no PCM, no `AVAudioNode`, and a Web
Audio `AnalyserNode` on tainted media returns silence.

### Tempo data is the real limit, not the maths

**Tempo comes from Deezer's public API** — no account, no key, the only free
source still answering. AcousticBrainz, which used to carry full audio
features, now returns `{"mbid_mapping":{}}` for every lookup.

Coverage is far worse than it looks, and it is worth being blunt about:

```
octane playlist, 13 tracks, all found on Deezer:   tempo known for 0/13
```

Deezer *has* every track — correct titles, correct durations — and publishes
`bpm: 0` for all of them. Whole catalogues are simply unmeasured. So a design
that only bends when it knows both tempos would never fire on most real music.

Hence two paths, and the plan says which one it took:

* **Both tempos known** — beat-matched glide, both tracks bent to one shared
  tempo, confidence reported honestly.
* **Either tempo unknown** — the outgoing track still eases 2.5% into the mix.
  This cannot claim the beats will line up and does not pretend to: nothing is
  asked of the incoming track and confidence stays 0. It is the turntable
  slowing under the mix, labelled as an effect rather than a measurement.

Deezer publishes no key at all, so the harmonic side is built and tested but
idle until a source with keys is plugged into `TrackAnalysisSource`.

### Six seconds, minimum

Every path floors the blend at six seconds, including the fallbacks. Under that
there is no room to be a mix and nowhere to hide a bend. The floor is reached
by **doubling the phrase** — 16 beats to 32 — rather than padding the time, so
the blend still lands on a bar line. Two exceptions, both deliberate: a
harmonic clash keeps its short 4-beat idea and takes the floor as plain
seconds, and genuinely running out of track is the only thing allowed to
undercut it.

A real transition from the trace, on a pair with no tempo data:

```
[AUTOMIX] no tempo to match, easing out 2.5% into the mix
[FADE_MATH] bend at t 0.72 -> x0.9972 (out gain 0.430)
[FADE_MATH] bend at t 0.83 -> x0.9889 (out gain 0.261)
[FADE_MATH] bend at t 0.94 -> x0.9750 (out gain 0.088)
[FADE_MATH] align 1 shadow 7.893 main 7.731 drift +0.163
[FADE_MATH] align 2 shadow 8.253 main 8.275 drift -0.022
```

### Aim where the shadow will be, not where it was

The handover used to converge to a constant error instead of to zero: +0.159
then +0.132 on consecutive attempts, both the same ~150 ms of unaccounted
latency, never improving. A seek costs a round trip *plus* a re-buffer, and
aiming with a fixed 0.2 s guess lands short every time by the amount the guess
was wrong. Feeding each measured drift back into the estimate fixes it — two
consecutive live transitions then landed at -0.022 and -0.032, inside the 60 ms
band where two copies of the same audio blend without anything audible.


## Architecture

```
SwiftUI (Liquid Glass)          ← what you see
      ↕  Engine.swift            ← observable state + commands
      ↕  Bridge.swift (JS)       ← injected into the page
WKWebView → music.youtube.com    ← the real player, hidden behind the backdrop
```

### Things that will bite you

**The webview stays mounted at full size.** WebKit throttles or suspends media
in views that are detached or zero-sized, so it is layered *behind* the opaque
blurred-artwork backdrop rather than hidden. `Backdrop` is load-bearing.

**Queue writes go through Redux, not endpoints.** `queueAddEndpoint` is a trap:
`resolveCommand`, `handleServiceEndpoint`, and a `yt-service-request` event all
accept it, return `true`, and change nothing — while its `onEmptyQueue` fallback
silently *replaces* what you are playing. Watching `store.dispatch` during a
genuine menu click showed the real mechanism:

```js
store.dispatch({ type: 'ADD_ITEMS', payload: {
  nextQueueItemId, index, items: [playlistPanelVideoRenderer], shouldAssignIds: true }})
```

The renderer must come from `/youtubei/v1/next` — search results are a different
shape (`musicResponsiveListItemRenderer`) and will not work.

**Every queue method takes an item object, not an index.** This was the queue
bug. `removeItem(n)` and `selectQueueItem(n)` both resolve their argument with
`getItems().findIndex(c => e_(c) === n)`, so an integer matches nothing:
removing silently did nothing at all, and clicking a row threw
`undefined is not an object`. Passing `getItems()[i]` fixes `selectQueueItem`;
`removeItem` still missed, so removal goes through the store like everything
else. The full set, read out of YouTube's own handlers:

```js
store.dispatch({ type: 'REMOVE_ITEM', payload: index })
store.dispatch({ type: 'MOVE_ITEM',   payload: { fromIndex, toIndex } })
store.dispatch({ type: 'CLEAR',       payload: [indicesToKEEP] })
store.dispatch({ type: 'SET_INDEX',   payload: index })
```

Three things about them are easy to get wrong:

- **`MOVE_ITEM`'s `toIndex` is applied after the row is spliced out**, so it is
  a final resting position, not a pre-removal one.
- **`CLEAR`'s payload is a keep-list, not a kill-list.** Passing `[]` is not a
  full wipe — it drives `nextQueueItemId` to `-Infinity` via
  `Math.max(...[]) + 1`. Omit the payload entirely for that.
- **Nothing renumbers the selection.** `selectedItemIndex` is what
  `getCurrentItemIndex()` reads, and neither remove nor move touches it, so any
  edit crossing the playing track leaves the highlight — and what plays next —
  one row out. Prism recomputes and dispatches `SET_INDEX` after each edit.

Removing the track that is playing also has to hand playback on *first*
(YouTube's own `removeItem` does this), or the player is left pointing at a song
that is no longer in the queue.

**Undo is a queue snapshot, not a replay.** Every destructive edit pushes the
raw `getItems()` array onto a stack in the bridge first, so undo is one
`RESET_ITEMS` dispatch — no `/next` refetching, and undoing a *clear* costs the
same as undoing a single remove. On restore the selection is pointed at whatever
is actually playing rather than at the old index: undo puts the list back, it
does not rewind playback.

**Lyrics timing does not come from YouTube.** Its lyrics browse response carries
`serializedLyricInfo` and no cue ranges — same shape from the web, `IOS_MUSIC`
and `ANDROID_MUSIC` client contexts. LRCLIB supplies real LRC timings and is
tried first; YouTube is the untimed fallback.

**A crossfade needs the shadow webview mounted in the window.** This is the
same trap as the main engine, and it cost a full debugging round: the shadow
player sat at state `-1` for an entire fade while its volume ramped dutifully
from 0 to 97. The ramp was real; the audio was not, because WebKit suspends
media in a detached webview. It is now added to the window's content view at
480×270 with `alphaValue = 0.02` — invisible, and allowed to play. Verified from
the trace: shadow state `1`, clock advancing 1.11 → 5.59 across the fade.

**Equal-power is right for the fade and wrong for the handover.** They are
different problems. Song-to-song blends two *uncorrelated* signals, whose
powers add — `cos`/`sin` keeps `gainA² + gainB² = 1` and the loudness flat, and
two linear ramps would sag ~3 dB in the middle. But the handover blends two
players carrying the *same* track at the same position: identical aligned audio
sums by *amplitude*, so `cos + sin` peaks at √2 — a +3 dB lift exactly at the
seam. Correlated signals want a linear pair. Prism now uses equal-power for the
fade and linear for the swap.

**Do not chase the alignment.** YouTube's seek is not sample accurate and the
player re-buffers afterwards, so it lands slightly behind wherever it was
aimed. Correcting repeatedly makes it worse: a run reached 44ms drift, took one
more correction because the threshold was 40ms, and ended at 132ms. The loop
now accepts anything inside 60ms, abandons a correction that diverges, and
leads each seek by the measured round trip plus the usual re-buffer. Typical
result is 17–55ms.

**Every exit from a fade must restore the volume.** This was the worst bug in
the file. A cancelled ramp returned before `handover()`, leaving the main
player's volume wherever the ramp had got to — often near zero — with `fading`
stuck true, so the app went quiet *and* crossfade never ran again. All paths go
through `finish(restoreTo:)` now, and `tick` cancels the moment the playing
track stops being one the fade knows about.

**`shadow = nil` does not unmount a webview.** The superview keeps its own
reference, so the shadow stayed mounted and alive after every fade. Teardown
stops the media, calls `removeFromSuperview()`, and only then drops it — and it
runs after successful fades too, not only when crossfade is switched off.

**A step-counted ramp runs long.** Each step also awaits a JS round trip, so
counting steps made a 5s fade take 6s and the outgoing track ended mid-ramp.
The ramp is driven by wall-clock elapsed time instead.

**Loading a track resets the player's volume — mute across the swap.** This is
what made the incoming song restart from its opening after a mix-in. The fade
ends with the main player at volume 0, then `next()` loads the new track and
YouTube restores the stored volume, so the main player came up at **full volume
on 0:00** and audibly replayed the intro while the shadow was already seconds
in. Alignment did seek it a second later, but by then the listener had heard it.
Captured from a gap-free in-page sample:

```
Good Morni|195.08|v2      fade ending, main almost silent
        |0.00|v100        jumps to 0:00 at FULL volume
Champion|0.09|v100        the opening plays again
```

`mute()` survives the load where `setVolume(0)` does not, and the volume is
re-asserted on every poll until the blend deliberately lifts it. Same moment
after the fix, with the incoming track inaudible until it is in the right place:

```
Stronger|0.00|v0|mtrue    opens at 0:00 but muted
Stronger|6.39|v0|mtrue    seeked to where the shadow reached, still muted
Stronger|7.16|v12|mfalse  unmutes and blends in
```

**Never blend into a player that is not aligned.** The alignment loop has three
exits that leave the main player wherever it happens to be — a clock that would
not read, a correction that diverged, and simply running out of attempts — and
the blend used to run regardless. A rescue pass now checks before handing over
and, when there is no shadow clock to trust, aims at the fade length, because
that is where the incoming track must be by definition.

**Plan before firing, or the outgoing track gets cut short.** The fade used to
trigger at the slider's length while running for the *planned* length. An 84.9
BPM pair plans 2.83s, so a 6s trigger ended the fade with three seconds of the
outgoing song still to play — and skipped them. The plan is now computed when
the next track is armed, and its duration decides when to start.

**Two more crossfade findings, both from the trace:**

- **Do not skip if YouTube already did.** The outgoing track reaches its natural
  end at exactly the moment the fade finishes, so it usually auto-advances on
  its own. Calling `next()` on top of that jumped a whole track — a fade from
  "Good Morning" landed on "Champion" instead of "Stronger". `handover` now
  checks whether the player is already on the expected video first.
- **`youtube.com/embed` is not a usable shadow.** It answered "no player" and
  never made a sound. The shadow loads `music.youtube.com/watch?v=` instead:
  heavier, but signed in, on the Premium stream, and running exactly the API the
  main engine already drives.

Set `PRISM_EVAL=1` and the fade writes `~/.prism-eval/fade.log`:
`[FADE_MATH]` lines carry the equal-power curve and its combined power (which
must stay at 1.000 — two *linear* ramps both sit at 0.5 mid-fade and 0.5+0.5 of
power is 0.707, an audible ~3 dB sag), and `[AUDIO_DEBUG]` lines carry the
shadow's real player state, clock and volume.

**There is no way to measure actual output loudness.** An `AVAudioEngine` tap
computing RMS is the right tool for an app that owns its audio graph — Prism
does not. The audio is decoded inside WebKit's own process from a cross-origin
stream; there is no `AVAudioNode` to tap, and a Web Audio `AnalyserNode` on a
CORS-tainted media element returns silence and mutes output. Real acoustic
verification would need a virtual output device such as BlackHole.

**`MPMediaItemArtwork`'s request handler must not be main-actor isolated.**
MediaPlayer invokes it on its own dispatch queue while building the Now Playing
dictionary. Constructing the artwork inside a `@MainActor` type makes Swift
insert an isolation check into that closure, which trips `dispatch_assert_queue`
and kills the app with a SIGTRAP the first time artwork is published — the
window simply vanishes. `NowPlaying.makeArtwork` is `nonisolated` for this
reason.

**Listening history cannot be imported — but not for the reason once written
here.** This entry used to say `FEmusic_history` returned an empty payload.
Re-measured, that is false: it returns 2.3 MB and 200 tracks across four
shelves ("Today" 34, "Yesterday" 36, "This week" 99, "Last week" 31), each with
a video ID, title and artist. The feed works fine. It is still unusable for
statistics, for three independent reasons:

| Checked | Result |
| --- | --- |
| distinct video IDs vs entries | 200 of 200 — **deduplicated**, so no play counts |
| any timestamp field | none — only the four coarse shelf buckets |
| continuation tokens | **zero** — hard stop at ~2 weeks, no way further back |

Merging that into the counters would corrupt them rather than enrich them:
every track worth exactly one play, and no duration to total. So the log still
starts at first play and lives only in
`~/Library/Application Support/Prism/history.json`.

The feed is genuinely good for *"what have I been listening to lately"* — which
is the For You page's job.

## Where the stats come from

Three sources, and only two of them are allowed near the numbers.

| Source | Feeds the dashboard | Durations |
| --- | --- | --- |
| Prism's own log | yes | **measured** against the player's clock |
| Google Takeout import | yes | estimated |
| `FEmusic_history` | **no** — see above | n/a |

**Takeout is the only complete history that exists.** `YouTube and YouTube
Music` → `history/watch-history.json` carries one entry per play with an exact
ISO timestamp, going back years — and because YouTube history is stored against
the Google account rather than the device, it covers the phone and the browser
too, not just this Mac. `TakeoutImport` keeps rows whose header is
`YouTube Music` (falling back to a `music.youtube.com` URL for older exports),
strips the `Watched ` / `Listened to ` prefix and the ` - Topic` suffix, and
skips removed videos, which Takeout writes as a placeholder with no URL.

What Takeout does **not** carry is how long you listened. So imported plays are
marked `.imported` and given one obvious stand-in length rather than a per-track
guess dressed up as data, and `hours()` prefixes the total with `≈` whenever any
estimate is in range. Counts, artists, dates and streaks stay exact; only the
hours are approximate, and the page says so.

Re-importing is safe and is expected — you top up by re-exporting, and the
overlap will be months. `History.merge` treats any play of the same track within
90 seconds of an existing one as the same listen, so a second import of the same
file adds nothing. Verified: 403-entry export → 401 plays parsed (one removed
video and one plain-YouTube row correctly skipped), re-run added **0**.

**Last.fm** is the live counterpart, for stats that follow you off this machine.
Prism scrobbles its own plays and can pull back plays made elsewhere. One thing
it cannot do: YouTube Music does not scrobble by itself. Android can bridge it
with Pano Scrobbler; **iOS cannot** — apps there cannot observe another app's
playback, and YouTube Music publishes no server-side "now playing" API for
Last.fm to poll. So on iPhone the phone's listening arrives via Takeout, not
Last.fm. Credentials are the user's own free API key; the shared secret and
session key live in the Keychain, not in `UserDefaults`.

Set `PRISM_IMPORT=/path/to/watch-history.json` to run an import at launch
without the open panel, which is how the parser is exercised against a real
export.

**An artist page is not an album page.** Opening an artist read its browse
response with the album parser, which looks for a `musicDetailHeaderRenderer`.
An artist page has none — it carries a `musicImmersiveHeaderRenderer` — so the
title fell through to the literal string "Playlist", the artwork came out
blank, and the seven `musicCarouselShelfRenderer` sections holding 65
`musicTwoRowItemRenderer` cards were ignored entirely. The result was a page
called "Playlist" with five songs and nothing else. The header is now read from
either shape and the carousels become sections, so an artist shows Top songs,
Albums, Singles & EPs and Videos.

**Back has to unwind, not jump.** The detail view hardcoded `route = .library`,
which stranded anyone who arrived from search — and now that an artist links on
to its albums there is a real stack. `closeDetail()` pops one detail at a time
and only then returns to whichever view the first one was opened from.

**An album's play button carries a track's videoId, so check `browseId` first.**
Album rows in search come back with *both* a `browseEndpoint.browseId` of
`MPREb_…` and a `watchEndpoint.videoId` on their play-button overlay — the
first track of the album. `parseListItem` tested `videoId` first, so every
album was filed as a song. The visible symptoms were an Albums row that was
always empty and twenty album entries quietly padding the song list, which is
why "Power — Z-Ro • 2007" looked like a track. `MPRE`, `UC`, `VL`, `PL` and
`OLAK` prefixes are unambiguous, and a genuine song has no `browseEndpoint` at
all, so the browseId decides first.

**Albums and artists have to be asked for separately.** An unfiltered search
returns songs and videos only — measured on "Power": 29
`musicResponsiveListItemRenderer` and *zero* `musicTwoRowItemRenderer`. The
Albums and Artists rows were not being dropped, they were never requested. The
web client's own filter chips send a `params` value, and those same values
return 20 results each as ordinary list items:

| Filter | `params` |
| --- | --- |
| Albums | `EgWKAQIYAWoKEAkQChAFEAMQBA==` |
| Artists | `EgWKAQIgAWoKEAkQChAFEAMQBA==` |
| Playlists | `EgWKAQIoAWoKEAkQAxAEEAkQBQ==` |

They are fired concurrently with the main query, so four requests cost one round
trip, and a filter that fails cannot take the songs down with it.

**A reorder changes neither the queue length nor the index.** The bridge's
change-detection hash has to include the order itself, or every move is
swallowed before it reaches Swift.

**Do not pin row identity to the slot.** `ForEach(queue) { row($0).id($0.index) }`
looks harmless and quietly breaks reordering: SwiftUI treats the slot as
unchanged across a reorder, so the panel keeps rendering the old order and the
current track loses its highlight until the whole panel is torn down and
rebuilt. Let `ForEach` use the element's own id, and give `ScrollViewReader`
that same id to scroll to.

**Reorder is a drag gesture, not `.onDrag`/`.onDrop`.** The AppKit drag session
did start — the row dimmed — but no drop delegate on any other row ever fired,
so the insertion marker stuck to the source gap and nothing committed. A plain
`DragGesture` (as `.highPriorityGesture`, so a tap still reaches the row's
button) works, and lets the list part around the row instead of drawing a line.

**State written from a detached `Task` is dropped.** The gesture's cleanup ran
in a bare `Task {}`, which is not on the main actor here; the writes vanished
and the dragged row stayed stuck in its lifted state, leaving every row below it
offset so the next click landed a row off. `Task { @MainActor in ... }`, or
better, do not defer the reset at all.

**Row actions are never hover-only.** Buttons that appear on hover leave their
own coordinates covered by the row's play target, so clicks aimed at them start
the track instead. They are always laid out, dimmed when not hovered.

**`GlassEffectContainer` cannot lay out the app shell.** It groups glass shapes
for morphing; wrapping scroll views in it lets their content escape the panel
frames entirely.

**`scaledToFill()` needs an explicit frame.** Without one it reports the image's
intrinsic size. This caused two separate bugs: it inflated the root ZStack and
pushed the whole UI out of the window whenever a track started, and inside
`Artwork` it grew the ZStack so the trailing `clipShape` clipped to that grown
size instead of the caller's frame. Wide 16:9 video thumbnails then spilled out
of their box — shunting search-row text sideways and bleeding through the
equalizer. Both are fixed by pinning to `GeometryReader` size and `.clipped()`.

**Equalizer contrast is enforced, not sampled.** Backdrop and equalizer come
from the same artwork, so a faithful palette renders the blocks invisible.
`ArtPalette.shape` forces a wide brightness spread across the three bands and
the equalizer draws a dark separation pass beneath the colour.

**`isMovableByWindowBackground` must stay false.** With it on, any drag that
isn't on a native AppKit control drags the window — so dragging the scrubber
moved the whole app instead of seeking. The transparent title-bar strip still
drags the window, so nothing is lost.

**Never measure the video while a fill is applied — it is a runaway, not a
wobble.** A taller webview means a taller viewport, which pushes the video
further down the page, which reads as a bigger inset, which grows the webview
again. Sampled live on *Hotline Bling* it climbed `top` 817 → 1420 and
`innerHeight` 2728 → 3934 in six steps: on screen, the picture sliding downwards
for twenty seconds until the retry cap stopped it. Two attempts at damping this
failed for the same reason — nothing was oscillating around a fixed point, so
there was no point to converge on. Every reading was genuinely further out than
the last.

**But one measurement is not enough either.** YouTube re-centres the video
whenever the webview resizes, so a placement computed from the natural layout
lands wrong — the picture stops short of the sidebar and the top. So
`AppModel.measureVideoFill` does both:

1. measure with **no placement at all**, waiting for two agreeing readings,
   which means the player page has finished opening;
2. apply, then measure where the picture *actually* ended up and solve for the
   size and offset that centre and cover the window; repeat at most three times.

The correction step is what makes it cover; the unplaced first measurement is
what makes it stop. Verified at 24 consecutive identical readings, in both
compact and normal layouts. A window resize re-runs the whole thing, since a
placement measured against the old bounds leaves black edges.

**Transport centring is measured from the play button, not the bounding box.**
Two separate bugs came from this, and both looked identical to the eye:

- *Compact mode.* Transport is five symmetric controls around play (shuffle,
  prev, play, next, repeat). A sixth on either end keeps the *group* centred
  while shifting play off the axis. Collapse lives in the top-right corner for
  this reason — don't move it back.
- *Now playing bar.* The side blocks are different widths (230pt of track info,
  130pt of volume), so an `HStack` centres the transport in the leftover space,
  putting it 50pt right of the window's true centre. The bar is now a `ZStack`:
  sides pinned left and right, transport centred against the full width at a
  fixed 520pt.

Any layout with unequal side blocks needs the ZStack treatment, not an HStack.

**Video mode is four separate fixes, and it breaks if you drop any of them.**
This took a lot of failed attempts; the order and the restraint both matter.

1. *Open the player page first.* Prism normally leaves YouTube on whatever view
   it loaded, where the video surface is collapsed into the mini player. No
   amount of CSS produces a picture until the page is open — you get a black
   rectangle with the audio playing on. Setting `layout.playerPageOpen = true`
   is **not** enough; the player bar has to actually be clicked.
2. *Then inject the CSS, on a delay.* Hiding the chrome any earlier removes the
   very control step 1 needs to click.
3. *Clear ancestor transforms.* A transformed ancestor becomes the containing
   block for `position: fixed`, which anchored the video to YouTube's layout box
   — it landed offset by exactly the guide width and nav height (240, 64).
4. *Dispatch a `resize`.* The player sized itself for the old box and only
   re-lays-out on resize.

Do **not** try to size or move the video from inside the page. Inline
`position`/`width`/`height` on the `<video>`, a lone inline `object-fit`, and
`player.setSize()` each blank the picture completely while audio keeps running.
Repositioning `#movie_player` in CSS is worse than useless: it moves the layout
box — `getBoundingClientRect` will happily report a perfect full-cover
rectangle — while the picture keeps painting wherever YouTube's compositor put
it. Chasing that cost many builds.

**The picture cannot be moved, so the webview is moved instead.** The page is
left to lay itself out; the bridge reports where the video actually lands
(`videoRect`), and `VideoFill` in `RootView.swift` enlarges the webview by the
chrome around it and pushes it up and left so that region covers the window,
with a generous `bleed` so nothing shows at the edges. No scaling, so no
softening.

**The equalizer is drawn the cheap way on purpose.** The obvious
implementation — three layers, each `.blur()`ed, per side — idled at ~35% CPU
forever. Three changes brought it to ~14% while playing and 0% when paused:
20fps instead of 60, a painted halo instead of a gaussian blur, and batching
each row into one `Path`. Block colour depends only on y, so a whole row shares
a shading and needs a single fill; per-block filling meant thousands of draw
calls a frame. Don't reintroduce `.blur()` here.

## Layout

| File | Role |
| --- | --- |
| `Bridge.swift` | Injected JS: state push, playback, queue dispatch, InnerTube queries |
| `Engine.swift` | WKWebView host, message handling, async query plumbing, debug console |
| `History.swift` | Local listening log, stats, streaks, suggestion seeds |
| `Lyrics.swift` | LRCLIB synced lyrics with a YouTube fallback |
| `NowPlaying.swift` | Media keys, Control Center, Now Playing metadata |
| `AudioOutput.swift` | CoreAudio device list and default-output switching |
| `Transitions.swift` | Crossfade via a second hidden player |
| `Floating.swift` | Non-activating always-on-top panel base |
| `NotchIsland.swift` | The notch panel: art chip collapsed, island on hover |
| `ForYouPane.swift` | Landing page |
| `DashboardPane.swift` | Listening stats |
| `AppModel.swift` | Navigation, search debounce, palette, compact mode, controls fade |
| `RootView.swift` | Window layout, sidebar, icon rail, compact mode, toast |
| `ContentPane.swift` | Now playing, search, library, playlist detail, track rows |
| `QueuePanel.swift` | Live queue: jump, remove, drag-reorder, context menu, shuffle, clear |
| `NowPlayingBar.swift` | Transport, scrubber, volume |
| `Equalizer.swift` | Canvas block equalizer, even random heights, frozen when paused |
| `ArtPalette.swift` | Artwork colour extraction with hue bucketing and contrast spread |
| `Logo.swift` | Chromatic-split note mark, app icon, runtime Dock icon |
| `Support.swift` | Artwork, backdrop, glass buttons, scrubber |

## Status

Verified in a running build against a signed-in Premium account, using
*Graduation* and *Fighting Demons* as test cases:

- Playback, scrubber, volume, shuffle, repeat
- Queue, every operation driven through the real UI and checked against the
  page's own store afterwards: jump, add to queue, play next, remove (including
  removing the track that is playing), drag-reorder up and down, context-menu
  move, shuffle, clear
- Search with correct artist/album parsing
- Library: real playlists with artwork
- Compact mode, icon rail, controls fade
- Colour extraction on both saturated and dark artwork
- ~14% CPU while playing with two equalizers live, 0% when paused
- Music video mode on and off, with playback continuing across the toggle

### Known gaps

**No energy queue, deliberately.** A build-up / wind-down reorder was built and
then removed: it fought the crossfade. The fade preloads the *next* track
several seconds early, and reordering the queue changes which track that is, so
an armed fade would be pointing at the wrong song. It was also guesswork —
YouTube publishes no tempo or loudness, the decoded audio is unreachable because
the media is served cross-origin into the webview, and AcousticBrainz now
answers every lookup with `{"mbid_mapping":{}}`. Both reasons on their own were
enough.

**Downloads are unconfirmed.** The `offlineVideoEndpoint` exists on queue and
library items (with a `PREMIUM_STANDALONE_CAIRO` badge), and `resolveCommand`
accepts it without error — but YouTube returns no confirmation and no Downloads
shelf appears afterwards (`FEmusic_offline` comes back empty). Given that the
same call reports false success for queue adds, the UI says "Download
requested", not "Downloaded". Do not trust it until the mechanism is verified
the same way the queue was: intercept `store.dispatch` during a real download
click and find the actual action.

**Reorder is local only.** `MOVE_ITEM` updates the queue Prism plays from, but
YouTube's own reorder additionally calls a module-private helper that issues an
`ACTION_MOVE_VIDEO_AFTER` playlist edit against the *server* queue, and nothing
public exposes it (`serverQueueApi` offers only `removeItem` and `shuffle`).
Remove and shuffle stay in step with the server; a move does not, so another
device watching the same queue may show the old order.

**Escape does not exit compact mode.** Three approaches were tried —
`.onExitCommand`, a zero-sized button with `.keyboardShortcut(.escape)`, and an
`NSEvent.addLocalMonitorForEvents` monitor (the code currently in
`EscapeToExit`) — and none fired during testing. Clicking the artwork and the
collapse button both work, so this is a convenience gap, not a trap. Worth
another look; the monitor approach is the most likely to be fixable.

**Queue rows no longer show duration** — the download and remove buttons took
that space in a 290pt panel.

**Video mode needs the webview enlarged past the window.** That is why
YouTube's side panel and suggestion overlays are explicitly hidden — without
that, the extra area beyond the window edges reveals the related-videos list
along the right side.

**Video mode needs playback already running.** Toggling it while the player sits
paused at 0:00 shows black, because there is no decoded frame yet. It fills in
as soon as playback starts — but it reads as a bug in the moment.

**Not implemented:** switching a song to its music-video counterpart. YouTube
models these as separate videoIds joined by a `counterpart` on the queue item,
and no counterpart data appeared in any response during testing, so video mode
only works for tracks that *are* videos. Lyrics, playlist editing, global media
keys and the macOS Now Playing widget are also absent.
