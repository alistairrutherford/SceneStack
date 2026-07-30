import AVFoundation
import XCTest
@testable import SceneStack

/// Input monitoring routes live input into the armed track's channel, so the
/// performer hears themselves through that track's effects and fader.
///
/// The audible mic path can't be exercised here — it needs a granted
/// microphone permission and a real device. What these cover is the routing
/// rule, and that switching the route around doesn't corrupt the graph.
final class InputMonitoringTests: XCTestCase {

    // MARK: - The routing rule

    private let track = UUID()

    func testMonitorsTheArmedTrackWhenEnabledAndInputIsLive() {
        XCTAssertEqual(TransportEngine.monitorTarget(monitorEnabled: true,
                                                     inputConfigured: true,
                                                     armedTrackID: track), track)
    }

    func testNoMonitoringWhenSwitchedOff() {
        XCTAssertNil(TransportEngine.monitorTarget(monitorEnabled: false,
                                                   inputConfigured: true,
                                                   armedTrackID: track))
    }

    func testNoMonitoringUntilTheInputIsLive() {
        // Routing from an input that hasn't been brought up would connect from
        // a node reporting no channels.
        XCTAssertNil(TransportEngine.monitorTarget(monitorEnabled: true,
                                                   inputConfigured: false,
                                                   armedTrackID: track))
    }

    func testNoMonitoringWithNothingArmed() {
        XCTAssertNil(TransportEngine.monitorTarget(monitorEnabled: true,
                                                   inputConfigured: true,
                                                   armedTrackID: nil))
    }

    // MARK: - Graph behaviour

    /// Switching the monitor route repeatedly, while clips are playing, must
    /// leave the graph intact — this is the failure mode that would matter,
    /// since the route changes every time the armed track changes.
    @MainActor
    func testTogglingMonitoringDoesNotDisturbPlayback() async throws {
        let engine = TransportEngine()
        defer { engine.shutdown() }
        try XCTSkipIf(engine.engineError != nil, "no usable audio here")
        engine.masterVolume = 0

        let format = engine.standardFormat
        let frames = AVAudioFrameCount(format.sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(format.channelCount) {
            let data = buffer.floatChannelData![channel]
            for frame in 0..<Int(frames) { data[frame] = 0.5 }
        }
        let track = engine.tracks[0]
        let clip = Clip(name: "Tone", colorIndex: 0, buffer: buffer, loopBars: 1,
                        fileURL: nil, nativeTempo: engine.tempo)
        track.slots[0] = clip

        let channel = try XCTUnwrap(engine.graph.channel(for: track.id))
        let heard = LevelProbe()
        channel.inputMixer.installTap(onBus: 0, bufferSize: 512, format: nil) { buffer, _ in
            heard.absorb(buffer)
        }
        defer { channel.inputMixer.removeTap(onBus: 0) }

        engine.launch(clip: clip, on: track)
        try await Task.sleep(nanoseconds: 300_000_000)

        // Route monitoring on and off across several tracks while audio runs.
        for target in [engine.tracks[0].id, engine.tracks[1].id, nil, engine.tracks[0].id] {
            await engine.graph.setMonitoring(to: target, gain: 1.0)
            try await Task.sleep(nanoseconds: 80_000_000)
        }

        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(engine.graph.isRunning, "the audio engine must survive the rewiring")
        XCTAssertGreaterThan(heard.peak, 0.4,
                             "the clip should still be playing after the monitor route changed")
    }

    /// Requesting monitoring for a track that doesn't exist must not be
    /// recorded as if it had been connected, or the next request for a real
    /// track would be skipped as "already monitoring".
    @MainActor
    func testUnroutableRequestIsNotRecordedAsConnected() async throws {
        let engine = TransportEngine()
        defer { engine.shutdown() }
        try XCTSkipIf(engine.engineError != nil, "no usable audio here")

        await engine.graph.setMonitoring(to: UUID(), gain: 1.0)
        XCTAssertNil(engine.graph.monitoredTrackID)
    }

    /// The route has to land on the *armed track's* channel — that's the whole
    /// point, since it's what puts the input through that track's effects and
    /// fader. Checked by inspecting the graph rather than by listening.
    @MainActor
    func testMonitorRouteLandsOnTheRequestedTracksChannel() async throws {
        let engine = TransportEngine()
        defer { engine.shutdown() }
        try XCTSkipIf(engine.engineError != nil, "no usable audio here")

        let first = engine.tracks[0]
        let second = engine.tracks[1]
        await engine.graph.setMonitoring(to: first.id, gain: 1.0)
        try XCTSkipIf(engine.graph.monitoredTrackID == nil,
                      "no live input node in this environment")

        func monitorFeeds(_ track: Track) -> Bool {
            let channel = engine.graph.channel(for: track.id)
            return engine.graph.engine
                .outputConnectionPoints(for: engine.graph.monitorMixer, outputBus: 0)
                .contains { $0.node === channel?.inputMixer }
        }

        XCTAssertTrue(monitorFeeds(first), "input should reach the monitored track's channel")
        XCTAssertFalse(monitorFeeds(second))

        // Arming a different track moves the route, leaving nothing behind.
        await engine.graph.setMonitoring(to: second.id, gain: 1.0)
        XCTAssertTrue(monitorFeeds(second))
        XCTAssertFalse(monitorFeeds(first), "the old route must be torn down, not left connected")

        // And switching it off disconnects entirely.
        await engine.graph.setMonitoring(to: nil, gain: 1.0)
        XCTAssertFalse(monitorFeeds(first))
        XCTAssertFalse(monitorFeeds(second))
        XCTAssertNil(engine.graph.monitoredTrackID)
    }

    @MainActor
    func testDeletingTheMonitoredTrackClearsTheRoute() async throws {
        let engine = TransportEngine()
        defer { engine.shutdown() }
        try XCTSkipIf(engine.engineError != nil, "no usable audio here")

        let track = engine.tracks[0]
        await engine.graph.setMonitoring(to: track.id, gain: 1.0)
        // Only meaningful if the route was actually established (it needs a
        // live input node), so skip rather than assert a false negative.
        try XCTSkipIf(engine.graph.monitoredTrackID == nil,
                      "no live input node in this environment")

        engine.deleteTrack(track)
        XCTAssertNil(engine.graph.monitoredTrackID)
    }
}

/// Tracks the loudest sample seen on a tap, off the audio thread.
private final class LevelProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var loudest: Float = 0

    func absorb(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        var local: Float = 0
        for frame in 0..<Int(buffer.frameLength) { local = max(local, abs(data[0][frame])) }
        lock.lock()
        loudest = max(loudest, local)
        lock.unlock()
    }

    var peak: Float {
        lock.lock()
        defer { lock.unlock() }
        return loudest
    }
}
