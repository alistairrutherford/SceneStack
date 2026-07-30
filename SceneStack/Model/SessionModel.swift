import AVFoundation
import Observation

/// A track: a column in the session grid. Holds no audio nodes — the engine
/// keeps a `TrackChannel` per track, keyed by `id`.
@MainActor
@Observable
final class Track: Identifiable {
    let id = UUID()
    var name: String
    var colorIndex: Int
    var isArmed = false
    var isMuted = false
    var isSoloed = false
    /// When recording into a cell that already holds a clip: overdub (layer
    /// the new take onto the existing audio) if true, otherwise replace it.
    var isOverdub = false
    var volume = 0.8
    var pan = 0.0
    var slots: [Clip?]
    /// Insert-effect chain, processed in order between the track's players
    /// and its fader mixer.
    var effects: [EffectInstance] = []

    init(name: String, colorIndex: Int, sceneCount: Int) {
        self.name = name
        self.colorIndex = colorIndex
        self.slots = Array(repeating: nil, count: sceneCount)
    }
}

/// An audio loop living in a session grid slot. Buffers are normalised to
/// the engine's standard format at creation so any clip can play on any
/// track player.
///
/// A clip owns its immutable `sourceBuffer` — `loopBars` bars of audio at its
/// `nativeTempo` — plus a derived `buffer` used for playback. When the project
/// tempo differs from `nativeTempo` the source is warped so the loop still
/// spans exactly `loopBars` bars at the current tempo instead of drifting.
/// The warp is a **pitch-preserving time-stretch** (Ableton-style), falling
/// back to plain resampling only if the stretcher can't run.
@MainActor
@Observable
final class Clip: Identifiable {
    let id: UUID
    var name: String
    /// Index into `Theme.trackPalette` — the model stays UI-free.
    var colorIndex: Int
    /// The original, un-warped audio: `loopBars` bars at `nativeTempo`.
    let sourceBuffer: AVAudioPCMBuffer
    /// Tempo (BPM) at which `sourceBuffer` spans exactly `loopBars` bars.
    let nativeTempo: Double
    /// The buffer players actually schedule — `sourceBuffer`, or a warped copy
    /// when the project tempo differs from `nativeTempo`.
    private(set) var buffer: AVAudioPCMBuffer
    let loopBars: Int
    let fileURL: URL?
    /// Low-res peaks for grid cells and placements.
    let waveform: [Float]
    /// High-res peaks for the clip inspector.
    let detailWaveform: [Float]

    init(id: UUID = UUID(), name: String, colorIndex: Int, buffer: AVAudioPCMBuffer,
         loopBars: Int, fileURL: URL?, nativeTempo: Double) {
        self.id = id
        self.name = name
        self.colorIndex = colorIndex
        self.sourceBuffer = buffer
        self.buffer = buffer
        self.nativeTempo = nativeTempo
        self.loopBars = loopBars
        self.fileURL = fileURL
        // Peaks come from the source so the drawn shape is tempo-independent.
        self.waveform = Waveform.peaks(for: buffer, bins: 96)
        self.detailWaveform = Waveform.peaks(for: buffer, bins: 480)
    }

    /// Recent warp results, keyed by the frame count they were rendered to.
    /// A render costs tens of milliseconds, and tempo editing revisits the same
    /// values constantly (nudge up, nudge back, A/B two tempos), so the
    /// previous result is worth keeping. Capped tightly: each entry costs as
    /// much memory as the clip's audio.
    @ObservationIgnored private var warpCache: [(frames: Int, buffer: AVAudioPCMBuffer)] = []
    private static let warpCacheLimit = 2

    /// The frame count this clip's loop has to occupy at `tempo`, or nil when
    /// the source already fits — i.e. at (or within a hair of) its native tempo.
    private func targetFrames(for tempo: Double) -> Int? {
        guard tempo > 0, abs(tempo - nativeTempo) > 0.01 else { return nil }
        return Int((Double(sourceBuffer.frameLength) * nativeTempo / tempo).rounded())
    }

    /// Warps `buffer` so the loop spans `loopBars` bars at `tempo`. Frame count
    /// scales by `nativeTempo / tempo`; at (near) the native tempo the source is
    /// reused untouched. Uses a pitch-preserving time-stretch, falling back to
    /// resampling if the stretcher is unavailable.
    ///
    /// Renders inline, so the caller waits. That's the right trade when a clip
    /// is being created (recorded, imported, loaded, duplicated) and can't be
    /// used until it's warped — but not for a tempo change, which re-warps
    /// every clip in the session at once. Use ``warp(to:)`` for that.
    func applyTempo(_ tempo: Double) {
        guard let frames = targetFrames(for: tempo) else {
            buffer = sourceBuffer
            return
        }
        if let cached = cachedWarp(frames) {
            buffer = cached
            return
        }
        let warped = Self.render(sourceBuffer, toFrames: frames)
        buffer = warped
        cacheWarp(warped, frames: frames)
    }

    /// The same warp with the render moved off the main actor, so re-warping a
    /// whole session on a tempo change doesn't freeze the UI. A cache hit (or a
    /// return to the native tempo) resolves without leaving the main actor at
    /// all, so the common cases stay immediate.
    func warp(to tempo: Double) async {
        guard let frames = targetFrames(for: tempo) else {
            buffer = sourceBuffer
            return
        }
        if let cached = cachedWarp(frames) {
            buffer = cached
            return
        }
        let rendered = await Self.renderOffMainActor(AudioBufferBox(sourceBuffer), toFrames: frames)
        buffer = rendered.buffer
        cacheWarp(rendered.buffer, frames: frames)
    }

    private func cachedWarp(_ frames: Int) -> AVAudioPCMBuffer? {
        warpCache.first { $0.frames == frames }?.buffer
    }

    private func cacheWarp(_ buffer: AVAudioPCMBuffer, frames: Int) {
        warpCache.removeAll { $0.frames == frames }
        warpCache.insert((frames, buffer), at: 0)
        if warpCache.count > Self.warpCacheLimit { warpCache.removeLast() }
    }

    nonisolated private static func render(_ source: AVAudioPCMBuffer,
                                           toFrames frames: Int) -> AVAudioPCMBuffer {
        AudioUtil.timeStretch(source, toFrames: frames)
            ?? AudioUtil.resample(source, toFrames: frames)
            ?? source
    }

    /// `nonisolated async` runs on the global executor rather than inheriting
    /// the caller's actor — which is the whole point: this is the tens of
    /// milliseconds of DSP that used to run on the main actor.
    nonisolated private static func renderOffMainActor(_ source: AudioBufferBox,
                                                       toFrames frames: Int) async -> AudioBufferBox {
        AudioBufferBox(render(source.buffer, toFrames: frames))
    }
}

/// A loaded AU effect in a track's device chain.
@MainActor
@Observable
final class EffectInstance: Identifiable {
    let id = UUID()
    let name: String
    let manufacturer: String
    let componentDescription: AudioComponentDescription
    let node: AVAudioUnit

    var isBypassed = false {
        didSet { node.auAudioUnit.shouldBypassEffect = isBypassed }
    }

    init(name: String, manufacturer: String,
         componentDescription: AudioComponentDescription, node: AVAudioUnit) {
        self.name = name
        self.manufacturer = manufacturer
        self.componentDescription = componentDescription
        self.node = node
    }
}

/// A scene: a row in the session grid. Carries only identity — clips live
/// positionally in each `Track.slots` array, keyed by the scene's row index —
/// so its sole job is to give SwiftUI a stable id per row. That identity is
/// what keeps `ForEach` diffing safe as rows are inserted, moved, and deleted
/// (an integer `0..<count` range with `id: \.self` is the anti-pattern that
/// once caused an index-out-of-range crash on scene delete).
///
/// Named `SessionScene` rather than `Scene` to avoid colliding with SwiftUI's
/// `Scene` protocol (the app's `body: some Scene`).
struct SessionScene: Identifiable {
    let id = UUID()
}

/// Addresses one cell in the session grid.
struct SlotRef: Hashable {
    let trackID: UUID
    let scene: Int
}

/// Launch quantisation for session clips.
enum LaunchQuantize: String, CaseIterable, Identifiable {
    case none = "None"
    case beat = "1 Beat"
    case bar = "1 Bar"
    var id: String { rawValue }
}

/// Per-track playback state published for the grid UI.
struct TrackPlayback: Equatable {
    var playingClipID: UUID?
    var playingStartBeat = 0.0
    var queuedClipID: UUID?
    var stopQueued = false
}
