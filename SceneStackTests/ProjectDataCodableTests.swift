import XCTest
@testable import SceneStack

/// The `.sts` JSON schema must survive an encode/decode round-trip
/// so saved projects reopen intact.
final class ProjectDataCodableTests: XCTestCase {

    func testProjectDataRoundTrips() throws {
        let clipID = UUID()
        let clip = ProjectStore.ClipData(id: clipID, name: "Kick",
                                         colorIndex: 2, loopBars: 2, audioFile: "kick.caf")
        let effect = ProjectStore.EffectData(name: "AUNBandEQ", manufacturer: "Apple",
                                             componentType: 0x61756678, componentSubType: 1,
                                             componentManufacturer: 2, isBypassed: true, state: Data([1, 2, 3]))
        let track = ProjectStore.TrackData(name: "Drums", colorIndex: 0,
                                           volume: 0.8, pan: -0.5,
                                           isMuted: false, isSoloed: true, isOverdub: true,
                                           slots: [clipID, nil], placements: nil, effects: [effect])
        let project = ProjectStore.ProjectData(tempo: 128, beatsPerBar: 4, countInBars: 2,
                                               quantize: "1 Bar", sceneCount: 4,
                                               masterVolume: 0.9, clips: [clip], tracks: [track])

        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(ProjectStore.ProjectData.self, from: data)

        XCTAssertEqual(decoded.tempo, 128)
        XCTAssertEqual(decoded.beatsPerBar, 4)
        XCTAssertEqual(decoded.countInBars, 2)
        XCTAssertEqual(decoded.quantize, "1 Bar")
        XCTAssertEqual(decoded.sceneCount, 4)
        XCTAssertEqual(decoded.masterVolume, 0.9)

        XCTAssertEqual(decoded.clips.count, 1)
        XCTAssertEqual(decoded.clips[0].id, clipID)
        XCTAssertEqual(decoded.clips[0].name, "Kick")
        XCTAssertEqual(decoded.clips[0].loopBars, 2)

        XCTAssertEqual(decoded.tracks.count, 1)
        let decodedTrack = decoded.tracks[0]
        XCTAssertEqual(decodedTrack.name, "Drums")
        XCTAssertEqual(decodedTrack.pan, -0.5)
        XCTAssertTrue(decodedTrack.isSoloed)
        XCTAssertTrue(decodedTrack.isOverdub ?? false)
        XCTAssertEqual(decodedTrack.slots, [clipID, nil])
        XCTAssertEqual(decodedTrack.effects?.count, 1)
        XCTAssertEqual(decodedTrack.effects?[0].name, "AUNBandEQ")
        XCTAssertTrue(decodedTrack.effects?[0].isBypassed ?? false)
        XCTAssertEqual(decodedTrack.effects?[0].state, Data([1, 2, 3]))
    }

    func testLegacyProjectWithoutOverdubOrEffectsDecodes() throws {
        // Older files omit isOverdub / effects (added later) — must still load.
        let json = """
        {
          "version": 1, "tempo": 120, "beatsPerBar": 4, "countInBars": 1,
          "quantize": "1 Bar", "sceneCount": 8, "playheadBar": 0, "masterVolume": 0.9,
          "clips": [],
          "tracks": [
            { "name": "Track 1", "colorIndex": 0, "volume": 0.8, "pan": 0.0,
              "isMuted": false, "isSoloed": false, "slots": [null, null] }
          ]
        }
        """
        let decoded = try JSONDecoder().decode(ProjectStore.ProjectData.self,
                                               from: Data(json.utf8))
        XCTAssertEqual(decoded.tracks.count, 1)
        XCTAssertNil(decoded.tracks[0].isOverdub)
        XCTAssertNil(decoded.tracks[0].effects)
        XCTAssertEqual(decoded.tracks[0].slots.count, 2)
    }
}
