import AVFoundation
import XCTest
@testable import SceneStack

/// Recording is a performance against what's already in the scene, so the rest
/// of the scene has to be playing while a take is captured.
///
/// It used not to be, when recording began from a stopped transport: the
/// count-in ran and then you played to silence. Whether you heard the backing
/// depended on having pressed play first — which made it look as though the
/// monitoring switch controlled it.
///
/// The take itself needs a granted microphone permission, so what's covered
/// here is the part that doesn't: the rest of the scene starting, on the right
/// tracks, anchored to the take's bar 1.
final class RecordBackingTrackTests: XCTestCase {

    @MainActor
    private func makeToneClip(in engine: TransportEngine, level: Float) -> Clip {
        let format = engine.standardFormat
        let frames = AVAudioFrameCount(format.sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(format.channelCount) {
            let data = buffer.floatChannelData![channel]
            for frame in 0..<Int(frames) { data[frame] = level }
        }
        return Clip(name: "Tone", colorIndex: 0, buffer: buffer, loopBars: 1,
                    fileURL: nil, nativeTempo: engine.tempo)
    }

    @MainActor
    func testSceneStartsUnderTheTakeExceptOnTheRecordedTrack() async throws {
        let engine = TransportEngine()
        defer { engine.shutdown() }
        try XCTSkipIf(engine.engineError != nil, "no usable audio here")
        engine.masterVolume = 0

        // Scene 0 has clips on three tracks; track 0 is the one being recorded.
        let recorded = engine.tracks[0]
        let backing = engine.tracks[1]
        let alsoBacking = engine.tracks[2]
        recorded.slots[0] = makeToneClip(in: engine, level: 0.5)
        backing.slots[0] = makeToneClip(in: engine, level: 0.5)
        alsoBacking.slots[0] = makeToneClip(in: engine, level: 0.5)

        let anchor = engine.startRolling()
        engine.launcher.launchSceneUnderRecording(0, startingAt: 0, hostTime: anchor,
                                                  excluding: recorded.id)

        // Queued immediately, on the backing tracks only.
        XCTAssertNotNil(engine.playback[backing.id]?.queuedClipID)
        XCTAssertNotNil(engine.playback[alsoBacking.id]?.queuedClipID)
        XCTAssertNil(engine.playback[recorded.id]?.queuedClipID,
                     "the track being recorded into must not launch its own clip")

        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(engine.playback[backing.id]?.playingClipID, backing.slots[0]?.id)
        XCTAssertEqual(engine.playback[alsoBacking.id]?.playingClipID, alsoBacking.slots[0]?.id)
        XCTAssertNil(engine.playback[recorded.id]?.playingClipID)
    }

    /// And the backing is actually audible, not merely marked as playing.
    @MainActor
    func testBackingTrackAudioReachesTheGraph() async throws {
        let engine = TransportEngine()
        defer { engine.shutdown() }
        try XCTSkipIf(engine.engineError != nil, "no usable audio here")
        engine.masterVolume = 0

        let recorded = engine.tracks[0]
        let backing = engine.tracks[1]
        backing.slots[0] = makeToneClip(in: engine, level: 0.5)

        let channel = try XCTUnwrap(engine.graph.channel(for: backing.id))
        let probe = LevelProbe()
        channel.inputMixer.installTap(onBus: 0, bufferSize: 512, format: nil) { buffer, _ in
            probe.absorb(buffer)
        }
        defer { channel.inputMixer.removeTap(onBus: 0) }

        let anchor = engine.startRolling()
        engine.launcher.launchSceneUnderRecording(0, startingAt: 0, hostTime: anchor,
                                                  excluding: recorded.id)
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertGreaterThan(probe.peak, 0.4, "the backing clip should be sounding")
    }

    /// An empty scene row must not leave anything queued — nothing to play
    /// against is fine, a stuck queued state is not.
    @MainActor
    func testEmptySceneLeavesNothingQueued() async throws {
        let engine = TransportEngine()
        defer { engine.shutdown() }
        try XCTSkipIf(engine.engineError != nil, "no usable audio here")

        let recorded = engine.tracks[0]
        _ = engine.startRolling()
        engine.launcher.launchSceneUnderRecording(0, startingAt: 0, hostTime: HostClock.now,
                                                  excluding: recorded.id)

        for track in engine.tracks {
            XCTAssertNil(engine.playback[track.id]?.queuedClipID)
        }
    }

    /// Monitoring governs whether you hear *yourself*, not whether the backing
    /// plays — the two were being conflated.
    @MainActor
    func testBackingIsIndependentOfTheMonitoringSetting() async throws {
        for monitoring in [false, true] {
            let engine = TransportEngine()
            defer { engine.shutdown() }
            try XCTSkipIf(engine.engineError != nil, "no usable audio here")
            engine.masterVolume = 0
            engine.monitorInput = monitoring

            let recorded = engine.tracks[0]
            let backing = engine.tracks[1]
            backing.slots[0] = makeToneClip(in: engine, level: 0.5)

            let anchor = engine.startRolling()
            engine.launcher.launchSceneUnderRecording(0, startingAt: 0, hostTime: anchor,
                                                      excluding: recorded.id)
            try await Task.sleep(nanoseconds: 350_000_000)

            XCTAssertEqual(engine.playback[backing.id]?.playingClipID, backing.slots[0]?.id,
                           "backing must play with monitoring \(monitoring ? "on" : "off")")
        }
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
