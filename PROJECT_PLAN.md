# Project Plan — "SceneStack" (working title)
## A simple Ableton Live–style DAW for macOS

**Platform:** macOS 14+ (Apple Silicon + Intel)
**UI:** SwiftUI
**Audio:** AVAudioEngine / Core Audio / AudioUnit v3
**Language:** Swift 5.10+

---

## 1. Vision

A lightweight loop-oriented DAW inspired by Ableton Live's two-view workflow:

- **Session (Clip) View** — a grid of launchable audio clips organised in tracks
  (columns) and scenes (rows). Clips launch quantised to the bar, like Live.
- **Arrangement (Track) View** — a horizontal timeline where clips sit on
  tracks against a bar/beat ruler for linear arrangement and recording.

Core capabilities:

- Record audio from the **built-in microphone by default**, with a device
  picker for any external Core Audio input (USB/Thunderbolt interfaces,
  aggregate devices).
- **Metronome** with accented downbeat and configurable **count-in**
  (0/1/2/4 bars) before recording.
- Per-track **effect chains hosting AU (Audio Unit) effect plugins**.
- A **colourful, appealing SwiftUI interface**: saturated per-track colour
  themes, rounded clip cells with playback progress rings, animated level
  meters, dark background with vivid accents (Live/Push aesthetic).

Explicit non-goals for v1: VST plugin support (dropped — AU only), MIDI
tracks/instruments, warping/time-stretch, automation lanes, audio export mixdown beyond a simple bounce, AUv2 UI
embedding quirks beyond what AUViewController gives us.

---

## 2. Technology choices

| Concern | Choice | Notes |
|---|---|---|
| Audio graph | `AVAudioEngine` | Mixer-per-track topology; handles format conversion, tap-based metering |
| Recording | `AVAudioInputNode` tap → `AVAudioFile` | Input device selected via Core Audio HAL (`kAudioHardwarePropertyDevices`, `kAudioOutputUnitProperty_CurrentDevice` on the input unit) |
| Clip playback | `AVAudioPlayerNode` per clip slot | Sample-accurate `scheduleSegment` for quantised launch |
| Metronome | `AVAudioSourceNode` (synthesised click) | Sample-accurate; no file loading; accent via pitch/gain |
| Transport clock | Host-time based (`mach_absolute_time` / `AVAudioTime`) | Single source of truth; UI observes at 60 Hz via `TimelineView` |
| AU hosting | `AVAudioUnitComponentManager` + `AVAudioUnit.instantiate` | Effects of type `aufx`; plugin UI via `requestViewController` wrapped in `NSViewControllerRepresentable` |
| Persistence | Project bundle (`.sts` folder): `project.json` (Codable) + `Audio/` clip files | AU/VST state saved via `fullState` / component `getState` |
| Waveforms | Precomputed peak files, drawn with SwiftUI `Canvas` | Background rendering on clip import/record |
| UI | SwiftUI + `Observation` framework | AppKit escape hatches only for plugin windows |

**Why AVAudioEngine and not raw Core Audio?** It gives us the graph, format
negotiation, AU hosting, and taps for free. The real-time-sensitive pieces
(metronome source node, clip scheduling) still get sample accuracy through
`AVAudioTime` scheduling. If we hit latency/timing limits we can migrate the
render path to an AUGraph-style manual render loop later without changing the
model layer.

---

## 3. Architecture

```
┌────────────────────────────────────────────────────────┐
│                     SwiftUI Views                      │
│  SessionGridView · ArrangementView · MixerStripView    │
│  TransportBar · DeviceChainView · PluginWindowHost     │
└──────────────────────┬─────────────────────────────────┘
                       │ @Observable view models
┌──────────────────────▼─────────────────────────────────┐
│                    Project Model                       │
│  Project → Tracks → ClipSlots/Clips → DeviceChain      │
│  (Codable, undo-manager aware, no audio types)         │
└──────────────────────┬─────────────────────────────────┘
                       │ commands / state snapshots
┌──────────────────────▼─────────────────────────────────┐
│                   Audio Engine Layer                   │
│  TransportClock · TrackChannel (player→FX→mixer)       │
│  MetronomeNode · RecordingService · DeviceManager      │
│  PluginHost (AU)                                       │
└────────────────────────────────────────────────────────┘
```

Key rules:

- The **model layer knows nothing about audio types** — it holds file URLs,
  gain values, plugin identifiers + opaque state blobs. This keeps
  persistence, undo, and testing simple.
- The **engine layer is command-driven**: the UI never touches nodes
  directly. `enginé.launchClip(trackID, sceneIndex)` computes the next
  quantise boundary from `TransportClock` and schedules the player node.
- **One `TrackChannel` per track**: `AVAudioPlayerNode` → [effect units…] →
  channel `AVAudioMixerNode` (volume/pan/mute) → main mixer. Rebuilt when the
  device chain changes; crossfaded to avoid clicks.

### Timing model

- Tempo + time signature live on `TransportClock`, which converts between
  beats and `AVAudioTime` host time.
- Clip launch quantisation: on launch request, compute the next bar boundary
  in host time and `scheduleSegment(at:)` — same mechanism drives count-in
  (schedule N bars of clicks, arm recording to start at the boundary).
- Recording start/stop is aligned by trimming the captured buffer to the
  bar-boundary sample offset, so loops are the right length without the user
  being precise.

---

## 4. Data model (v1)

```swift
Project        { name, tempo, timeSignature, tracks: [Track], scenes: [Scene] }
Track          { id, name, color, volume, pan, isMuted, isArmed,
                 inputSource, deviceChain: [DeviceRef], clipSlots: [ClipSlot] }
ClipSlot       { sceneIndex, clip: Clip? }
Clip           { id, name, color, audioFileRef, lengthInBeats, isLooping,
                 arrangementPlacements: [Placement] }   // shared by both views
Placement      { startBeat, duration }                  // arrangement view
DeviceRef      { format: .au, identifier, displayName,
                 stateBlob: Data, isBypassed }
Scene          { name, color }                          // a row in session view
```

---

## 5. Phases & milestones

### Phase 0 — Skeleton & audio proof of concept (1 week)
- Xcode project, app sandbox with microphone + audio-input entitlements,
  `NSMicrophoneUsageDescription`.
- AVAudioEngine running: play a bundled file through a track channel to
  output; basic transport (play/stop) with a host-time clock.
- **Milestone: audio out + a play button.**

### Phase 1 — Transport, metronome, count-in (1–2 weeks)
- `TransportClock` with tempo/time-sig, beat position published to UI.
- `MetronomeNode` (`AVAudioSourceNode` synth click, accented downbeat),
  toggle + volume.
- Count-in: 0/1/2/4-bar setting; recording and playback start armed to the
  post-count-in boundary.
- Transport bar UI: play/stop/record, tempo drag control, metronome toggle,
  animated beat indicator.
- **Milestone: metronome ticks in perfect time; count-in leads into playback.**

### Phase 2 — Recording & devices (2 weeks)
- `DeviceManager`: enumerate Core Audio input devices, default to built-in
  mic, react to device add/remove notifications; per-track input picker
  (device + channel).
- `RecordingService`: input tap → `AVAudioFile` (CAF/AIFF), monitored input
  option, bar-aligned trim on stop.
- Record into a session clip slot (armed track + slot record button) and into
  the arrangement at the playhead.
- Live input level meter on armed tracks.
- **Milestone: record a loop from the mic with count-in; it plays back looped
  and in time.**

### Phase 3 — Session view & clip launching (2–3 weeks)
- Session grid: tracks as columns, scenes as rows; clip cells with colour,
  name, play/stop buttons, launch-progress ring; scene-launch column.
- Quantised launch/stop (next-bar default; setting for none/beat/bar).
- Clip drag-and-drop between slots, drag audio files in from Finder.
- Waveform peak-file generation + thumbnail in cells.
- Colour system: per-track hue themes, clip colour picker, subtle gradients,
  pulse animation on queued clips.
- **Milestone: build and perform a 4-track loop jam entirely in session view.**

### Phase 4 — Arrangement view & mixer (2–3 weeks)
- Timeline with bar/beat ruler, horizontal zoom/scroll, playhead chase.
- Clip placements: drag from session grid or Finder, move/trim/duplicate,
  snap to grid.
- Global record-into-arrangement (capture session-view performance —
  stretch goal; at minimum, linear recording onto tracks).
- Mixer strips: fader, pan, mute/solo/arm, stereo level meters (tap-based,
  peak + RMS with decay animation).
- Project save/load (`.sts` bundle), autosave, undo/redo via
  `UndoManager` on the model layer.
- **Milestone: arrange, mix, save, reopen.**

### Phase 5 — AU plugin hosting (2 weeks)
- Browse installed AU effects via `AVAudioUnitComponentManager`
  (`aufx` types), searchable device browser panel.
- Insert/remove/reorder/bypass effects in a track's device chain; graph
  rebuild with click-free crossfade.
- Plugin UI: `requestViewController` → floating `NSPanel` per plugin
  (AppKit-hosted), generic parameter fallback UI when no view is provided.
- Persist/restore plugin state (`fullState`) with the project.
- **Milestone: two AU effects (e.g. EQ + reverb) running in series on a
  recorded vocal track, states restored on project reload.**

### Phase 6 — Polish & appeal (2 weeks)
- Visual pass: refined colour palette, clip-launch animations, meter
  ballistics, app icon, welcome/demo project.
- Keyboard shortcuts (space = play, F9 = record, tab = view switch).
- Simple stereo bounce-to-file of the arrangement.
- Performance pass with Instruments (audio thread safety audit — no locks or
  allocation in render blocks), crash-free plugin scanning (out-of-process
  scan or blacklist file).
- **Milestone: v1.0.**

**Rough total: 10–14 weeks part-time-friendly, sequential.** Phases 3 and 4
can swap; phase 5 can be pulled earlier since AU hosting is cheap with
AVAudioEngine.

---

## 6. UI design direction

- **Dark charcoal canvas** (#1c1c1f-ish) so track colours pop; vivid
  saturated palette (coral, amber, mint, cyan, violet, magenta) assigned
  round-robin to new tracks.
- Session cells: rounded rectangles filled with the clip colour at ~80%,
  white waveform thumbnail overlay, circular progress ring while playing,
  soft pulsing border while queued.
- Transport bar: pill-shaped, oversized tempo readout, beat-flash dot.
- Meters: gradient green→amber→red with smooth decay, drawn in `Canvas`
  inside `TimelineView(.animation)`.
- Respect Reduce Motion; keep all colour pairs AA-contrast for text.

---

## 7. Risks & mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Plugin crashes take down the app | Bad UX | v1: catch at scan time with an out-of-process scanner; document. Out-of-process rendering (AUv3 gives some of this free) is a v2 item |
| Clip launch timing drift | Core feature feels wrong | All scheduling in host time via one clock; integration tests that record output and assert click/loop sample offsets |
| App Sandbox vs plugin file access | Third-party AU quirks | Test sandboxed early with common third-party AUs |
| SwiftUI performance on dense grids/meters | Janky UI | `Canvas` + `TimelineView` for hot paths; throttle meter publishes to UI at 30–60 Hz off the audio thread |
| Input device hot-unplug mid-record | Data loss | DeviceManager listens for HAL notifications; auto-fallback to built-in mic, stop recording gracefully, keep partial file |

---

## 8. Testing strategy

- **Model layer:** plain unit tests (Codable round-trips, undo, quantise math
  — beat↔time conversions are pure functions, test them hard).
- **Engine:** offline-render tests (`AVAudioEngine` manual rendering mode) —
  render the metronome for 8 bars and assert click sample positions; record a
  known buffer and assert trim alignment.
- **Plugins:** smoke-test hosting against Apple's built-in AUs (AUDelay,
  AUMatrixReverb) so CI needs no third-party installs.
- **UI:** lightweight — snapshot tests for the grid, manual test script for
  device hot-plug and plugin windows.

---

## 9. Immediate next steps

1. Phase 0: create the Xcode project (`SceneStack.app`), entitlements, engine
   skeleton, play a test file.
2. Build Phase 1's `TransportClock` + metronome first — everything else
   (count-in, quantised launch, recording alignment) hangs off that clock, so
   getting it right early de-risks the whole schedule.
