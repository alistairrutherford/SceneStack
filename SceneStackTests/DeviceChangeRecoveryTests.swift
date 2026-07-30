import AVFoundation
import XCTest
@testable import SceneStack

/// Plugging headphones in (or pulling them out, or swapping an interface)
/// changes the audio hardware under the running engine. AVAudioEngine responds
/// by stopping itself and dropping its I/O connections — so without explicit
/// handling the app goes silent and stays silent: nothing plays, nothing
/// records, no error shown.
///
/// The real hardware transition can't be staged here, so these drive the same
/// notification AVAudioEngine posts, and check the graph comes back.
final class DeviceChangeRecoveryTests: XCTestCase {

    @MainActor
    private func makeToneClip(in engine: TransportEngine, level: Float = 0.5) -> Clip {
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

    /// Posting the notification is how AVAudioEngine tells us the device moved.
    @MainActor
    private func simulateDeviceChange(on engine: TransportEngine) async {
        // The real notification arrives with the engine already stopped.
        engine.graph.stop()
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange,
                                        object: engine.graph.engine)
        // The observer is delivered on the main queue.
        try? await Task.sleep(nanoseconds: 200_000_000)
    }

    @MainActor
    func testEngineRestartsAndPlaysAgainAfterADeviceChange() async throws {
        let engine = TransportEngine()
        defer { engine.shutdown() }
        try XCTSkipIf(engine.engineError != nil, "no usable audio here")
        engine.masterVolume = 0

        let track = engine.tracks[0]
        let clip = makeToneClip(in: engine)
        track.slots[0] = clip

        await simulateDeviceChange(on: engine)

        XCTAssertTrue(engine.graph.isRunning, "the engine must be restarted, not left stopped")
        XCTAssertEqual(engine.mode, .stopped, "transport should be stopped, not left half-running")
        XCTAssertNotNil(engine.statusMessage, "a silent device change is the confusing part")

        // The real test: audio still reaches the graph afterwards.
        let channel = try XCTUnwrap(engine.graph.channel(for: track.id))
        let probe = LevelProbe()
        channel.inputMixer.installTap(onBus: 0, bufferSize: 512, format: nil) { buffer, _ in
            probe.absorb(buffer)
        }
        defer { channel.inputMixer.removeTap(onBus: 0) }

        engine.launch(clip: clip, on: track)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertGreaterThan(probe.peak, 0.4, "playback must work again after a device change")
    }

    @MainActor
    func testDeviceChangeWhilePlayingStopsCleanlyAndExplains() async throws {
        let engine = TransportEngine()
        defer { engine.shutdown() }
        try XCTSkipIf(engine.engineError != nil, "no usable audio here")
        engine.masterVolume = 0

        let track = engine.tracks[0]
        let clip = makeToneClip(in: engine)
        track.slots[0] = clip
        engine.launch(clip: clip, on: track)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(engine.mode, .playing)

        await simulateDeviceChange(on: engine)

        XCTAssertEqual(engine.mode, .stopped)
        XCTAssertTrue(engine.graph.isRunning)
        XCTAssertEqual(engine.statusMessage,
                       "Audio device changed — playback stopped. Press play to continue.")
        // Playback state must be cleared, not left claiming a clip is sounding.
        XCTAssertNil(engine.playback[track.id]?.playingClipID)
    }

    /// The master meter tap has to survive being re-installed; a bus takes only
    /// one tap and installing a second throws.
    @MainActor
    func testRepeatedDeviceChangesDoNotThrowOnTapReinstall() async throws {
        let engine = TransportEngine()
        defer { engine.shutdown() }
        try XCTSkipIf(engine.engineError != nil, "no usable audio here")
        engine.masterVolume = 0

        for _ in 0..<3 {
            await simulateDeviceChange(on: engine)
            XCTAssertTrue(engine.graph.isRunning)
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
