# SceneStack — Implementation Status

A running summary of what has been built. The aspirational scope lives in
[`PROJECT_PLAN.md`](PROJECT_PLAN.md); this file records what actually exists and
what's left. (App formerly named *Stringstack*; renamed **SceneStack** — saves
`.sts` project bundles.)

**Stack:** SwiftUI + AVAudioEngine + Audio Unit (AU) effects, macOS. Session /
clip-view only — the linear arrangement view was built and then **deliberately
removed** to focus the app on the loop-launching clip view.

---

## Feature areas — done

### Transport & timing
- Play / stop / record; sample-accurate clock driven by the metronome source node.
- Tempo (steppers, type-in, drag), time signature, **count-in** (off/1/2/4 bars),
  **quantise** (None / 1 Beat / 1 Bar) for clip launches, metronome toggle + volume.
- Main Play launches the **selected scene**; bar-countdown count-in display.

### Recording
- Records from the built-in mic by default; external Core Audio inputs via a
  device picker, with hot-plug handling and a robust input bring-up sequence.
- Arm-gated (record button greys out unless the selected track is armed);
  count-in from stopped, bar-quantised punch-in while rolling.
- **REC BARS** fixed length (1/2/4/8) or **Free** (default) — fixed takes
  auto-finish and loop seamlessly; short takes are silence-padded.
- **Overdub vs Replace** per track (o/r); input-level slider + gain.
- **Input monitoring** (MON in the input bar): live input is routed into the
  armed track's channel, so you hear yourself through that track's effects,
  fader and pan — the same path the recorded take will play back through. The
  route follows the armed track and fades when it switches. Off by default and
  persisted as a preference: monitoring an open mic on speakers feeds back.

### Clips & scenes
- Grid of tracks (columns) × scenes (rows); clip launch/stop quantised, with
  queued-pulse and playback follow-lines (cell + inspector).
- Clip transitions are **scheduled on the audio thread at both ends**: the
  incoming clip starts via `play(at:)`, and the outgoing one is ended by a 4 ms
  fade scheduled with `.interrupts` at the same boundary. The main thread is out
  of the audio path — it only does bookkeeping afterwards. (Measured: overlap
  went from a jittery 20–26 ms at full level, ending in a hard cut, to a
  deterministic 3.2 ms fade.)
- Clips: launch / select / move / **duplicate (⌘D)** / **rename** / recolour /
  delete; drag-in audio files; waveform thumbnails.
- Scenes: **numbered** (always consecutive), **drag-reorder**, duplicate, delete
  (grid can be emptied); scene launch/stop buttons.

### Mixer & effects
- Per-track channel strip: arm, mute, **exclusive solo**, o/r, volume, rotary pan
  knob, **stereo VU meter** (post-fader, reflects pan); **master** meter + fader.
- AU effect chains per track: browse/insert/reorder/bypass/remove, plugin editor
  windows, saved state; **click-free chain rebuild** via a short output fade.

### Projects & persistence
- `.sts` bundles (JSON + per-clip audio); New / Open / Save / Save As with an
  unsaved-changes guard; autosave; **reopens last project on launch**
  (security-scoped bookmark).
- Saves are **atomic**: the bundle is built in a staging directory on the
  destination's volume and swapped in only once complete, so a failed save
  can't destroy the project it was overwriting. Clip audio already in the
  bundle is carried forward rather than re-encoded, and autosave only runs
  when there are actual changes (and reports failures).
- Metronome + input-gain settings persist as app preferences; Reduce-Motion honoured.
- **Undo/redo** across clips, scenes, tracks (add/delete with effect restore),
  and the mixer (volume/pan/mute/solo — continuous controls coalesced to one
  undo per gesture).

### Clip tempo-follow (warping)
- Clips store an immutable `sourceBuffer` at their `nativeTempo`; when the project
  tempo differs, the loop is re-warped to stay bar-aligned.
- **Pitch-preserving time-stretch** (`AudioUtil.timeStretch`, offline
  `AVAudioUnitTimePitch`, steady-state looped-window extraction for a seam-free
  loop), falling back to plain resampling if the stretcher can't run.
- The warp is **debounced** (~200 ms): the metronome retargets tempo instantly,
  the costly per-clip re-warp runs when the tempo settles; playing loops are
  phase-realigned on re-warp.
- Renders run **off the main actor**, one clip at a time, so re-warping a
  session never freezes the UI. (Measured on eight 4-second clips: the main
  actor went from ~890 ms unavailable to under 10 ms.) Clips that are currently
  sounding warp first and re-align as soon as their own buffer is ready, rather
  than waiting for the whole session.
- Each clip keeps a small **cache of recent warps**, so returning to a tempo
  it has already been warped to costs nothing. Bounded to two entries, since
  each one costs as much memory as the clip's audio.

---

## Architecture

`TransportEngine` (`@MainActor @Observable`) is the coordinator/façade the SwiftUI
views talk to via `@Environment`. Heavy responsibilities are split into focused
collaborators it owns:

- **`AudioGraph`** — all raw AVAudioEngine node plumbing (channels, mixing,
  effect wiring, lifecycle, metering, faded chain rebuild, the input-monitor
  route).
- **`AudioInputController`** — mic input bring-up + device management.
- **`ClipLauncher`** — quantised launch/stop, A/B player swap, phase-aligned
  in-progress relaunch.
- **`RecordingController`** — capture → trim → clip creation (overdub/replace).
- **`BeatMath`** — pure timing/index math (quantise boundary, recorded-bar
  rounding, scene-move remap), extracted so it's testable without audio.
- Support: `MetronomeSource`, `RecordingService`, `MeterTap`, `HostClock`,
  `Waveform`, `AudioUtil`, `ProjectStore`, `DeviceManager`, `Theme`.

AppKit escape hatches (global Delete key, focus handling, plugin windows) are
isolated behind SwiftUI modifiers in `AppKitSupport` / `PluginWindows`.

---

## Tests

`SceneStackTests` — **76 tests**, run headless:

```bash
xcodebuild test -project SceneStack.xcodeproj -scheme SceneStack -destination 'platform=macOS'
```

Suites: `BeatMathTests`, `HostClockTests`, `AudioUtilTests` (mix/slice/convert/
resample), `WaveformTests`, `ProjectDataCodableTests` (`.sts` schema round-trip),
`ProjectStoreSwapTests` (atomic-save staging/swap), `ClipWarpTests` (tempo-follow
frame maths), `MetronomeTimingTests`. The pure logic is deliberately
engine-independent so the tests are fast. (The harness once caught a real
bar-rounding bug.)

Two suites deliberately go beyond pure logic, because the things they cover
can't be checked any other way:

- `PlayerNodeInterruptTests` pins the two `AVAudioPlayerNode` behaviours the
  clip-switch fade depends on (`.interrupts` truncates at the *scheduled* time;
  an interrupted loop doesn't resume). Rendered offline, so it's deterministic.
- `ProjectStoreRoundTripTests`, `ClipSwitchTimingTests` and
  `TempoWarpResponsivenessTests` build a real `TransportEngine`: to cover the
  actual save/reopen path, to *measure* a clip switch through a tap on the track
  mixer, and to measure how long the main actor is unavailable while a session
  re-warps. Each must call `engine.shutdown()` — see the `MetronomeSource` note
  under known limitations. The suite still finishes in ~5 s.

---

## Known limitations / deferred

- **Warp quality** is Apple's single general stretcher — clean for modest tempo
  changes, softer transients / warble at large ratios (slowing sounds worse than
  speeding). Matching Ableton's per-material warp modes would need custom DSP.
  A real-time time-pitch node (continuous, live tempo sweeps) is the alternative
  "Option B", not yet built.
- Warp rendering is off the main actor, but **project open still warps
  synchronously** (`ProjectStore.read`), so opening a large set pauses for
  roughly 50 ms per clip. Same fix applies; `read` would have to become async.
- **`MetronomeSource`'s render block captures `[unowned self]`** (real-time code
  can neither retain nor lock). Releasing a `TransportEngine` while its graph is
  still rendering therefore crashes on the audio thread. The app never hits this
  — its engine lives as long as the process — and `TransportEngine.shutdown()`
  closes the window for anything that does create engines. The durable fix is to
  move the render state into an object the node holds strongly.
- The boundary fade covers quantised launches and stops. Two paths still cut
  hard: the global transport stop (immediate by design — there's no future
  boundary to schedule against), and a clip that is *queued but not yet playing*
  when a stop is scheduled, which still sounds from its own boundary until the
  stop boundary.
- **Input monitoring's audible path is untested.** The tests cover the routing
  rule and prove the graph is wired to the right channel and torn down cleanly,
  but a granted microphone permission is needed to confirm sound actually
  arrives — verify by ear, on headphones, before relying on it.
- AU effects only (no VST); one recording input at a time.
- No export/bounce, and no master insert chain or aux sends — the other two
  gaps from the same review as input monitoring.
- Deferred features: MIDI clip launching (computer-keyboard launching exists),
  out-of-process plugin scanning.
