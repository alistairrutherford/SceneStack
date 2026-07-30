import AVFoundation
import XCTest
@testable import SceneStack

/// End-to-end cover for the real save path: a project written through
/// `ProjectStore.write` must reopen intact, and re-saving over an existing
/// bundle (what autosave does) must not lose the audio already in it.
///
/// Unlike the rest of the suite this builds a `TransportEngine`, so it touches
/// AVAudioEngine — but it never starts the transport or plays anything, and it
/// still passes if the audio engine fails to come up, since saving only reads
/// the session model.
final class ProjectStoreRoundTripTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectStoreRoundTrip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A one-bar buffer of a recognisable ramp, so decoded audio can be told
    /// apart from silence.
    @MainActor
    private func makeClip(named name: String, in engine: TransportEngine) -> Clip {
        let format = engine.standardFormat
        let frames = AVAudioFrameCount(format.sampleRate * 2)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(format.channelCount) {
            let data = buffer.floatChannelData![channel]
            for frame in 0..<Int(frames) {
                data[frame] = Float(frame % 100) / 100.0 - 0.5
            }
        }
        return Clip(name: name, colorIndex: 3, buffer: buffer, loopBars: 1,
                    fileURL: nil, nativeTempo: 96)
    }

    @MainActor
    func testProjectSurvivesSaveAndReopen() throws {
        let engine = TransportEngine()
        defer { engine.shutdown() }
        let url = root.appendingPathComponent("Round Trip.sts", isDirectory: true)

        engine.tempo = 96
        let clip = makeClip(named: "Ramp", in: engine)
        let clipID = clip.id
        engine.tracks[0].slots[0] = clip
        engine.tracks[0].name = "Guitars"

        try ProjectStore.write(engine: engine, to: url)

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent("project.json").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent("Audio/\(clipID.uuidString).caf").path))
        XCTAssertFalse(engine.hasUnsavedChanges, "a completed save clears the dirty flag")

        try ProjectStore.read(into: engine, from: url)

        XCTAssertEqual(engine.tempo, 96)
        XCTAssertEqual(engine.tracks.first?.name, "Guitars")
        let reopened = try XCTUnwrap(engine.tracks.first?.slots.first ?? nil)
        XCTAssertEqual(reopened.id, clipID)
        XCTAssertEqual(reopened.name, "Ramp")
        XCTAssertEqual(reopened.loopBars, 1)
        XCTAssertEqual(reopened.nativeTempo, 96)
        XCTAssertGreaterThan(reopened.sourceBuffer.frameLength, 0)
    }

    /// Re-saving over an existing bundle — every autosave — must carry the
    /// already-written audio forward rather than dropping or corrupting it.
    @MainActor
    func testResavingKeepsClipAudioAndDropsDeletedClips() throws {
        let engine = TransportEngine()
        defer { engine.shutdown() }
        let url = root.appendingPathComponent("Resave.sts", isDirectory: true)

        let kept = makeClip(named: "Kept", in: engine)
        let removed = makeClip(named: "Removed", in: engine)
        engine.tracks[0].slots[0] = kept
        engine.tracks[0].slots[1] = removed

        try ProjectStore.write(engine: engine, to: url)
        let keptAudio = url.appendingPathComponent("Audio/\(kept.id.uuidString).caf")
        let removedAudio = url.appendingPathComponent("Audio/\(removed.id.uuidString).caf")
        let originalSize = try FileManager.default
            .attributesOfItem(atPath: keptAudio.path)[.size] as? Int

        // Delete one clip and save again, as an autosave would.
        engine.tracks[0].slots[1] = nil
        try ProjectStore.write(engine: engine, to: url)

        XCTAssertTrue(FileManager.default.fileExists(atPath: keptAudio.path),
                      "audio for a surviving clip must be carried into the new bundle")
        XCTAssertFalse(FileManager.default.fileExists(atPath: removedAudio.path),
                       "audio for a deleted clip must not linger")
        let resavedSize = try FileManager.default
            .attributesOfItem(atPath: keptAudio.path)[.size] as? Int
        XCTAssertEqual(resavedSize, originalSize, "carried-forward audio must be unchanged")

        // And the carried-forward audio still decodes.
        try ProjectStore.read(into: engine, from: url)
        let reopened = try XCTUnwrap(engine.tracks.first?.slots.first ?? nil)
        XCTAssertEqual(reopened.name, "Kept")
        XCTAssertGreaterThan(reopened.sourceBuffer.frameLength, 0)
    }

    /// The point of staging: a save that fails part-way must leave the previous
    /// project exactly as it was, not a half-written bundle. The failure is
    /// injected by making one clip's stored audio unreadable, so the write
    /// throws after it has already processed the other clip.
    @MainActor
    func testFailedSaveLeavesThePreviousProjectIntact() throws {
        let engine = TransportEngine()
        defer { engine.shutdown() }
        let url = root.appendingPathComponent("Guarded.sts", isDirectory: true)

        engine.tempo = 132
        engine.tracks[0].slots[0] = makeClip(named: "First", in: engine)
        let second = makeClip(named: "Second", in: engine)
        engine.tracks[0].slots[1] = second
        try ProjectStore.write(engine: engine, to: url)

        let unreadable = url.appendingPathComponent("Audio/\(second.id.uuidString).caf")
        try FileManager.default.setAttributes([.posixPermissions: 0o000],
                                              ofItemAtPath: unreadable.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                                   ofItemAtPath: unreadable.path)
        }

        engine.tempo = 200
        XCTAssertThrowsError(try ProjectStore.write(engine: engine, to: url),
                             "an unreadable clip file must fail the save")

        let onDisk = try Data(contentsOf: url.appendingPathComponent("project.json"))
        let decoded = try JSONDecoder().decode(ProjectStore.ProjectData.self, from: onDisk)
        XCTAssertEqual(decoded.tempo, 132, "the previous project must survive a failed save")
        XCTAssertEqual(decoded.clips.count, 2, "and keep all of its clips")
        XCTAssertTrue(engine.hasUnsavedChanges, "a failed save must not report success")
    }
}
