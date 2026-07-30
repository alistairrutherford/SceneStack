import XCTest
@testable import SceneStack

/// `ProjectStore.write` builds each `.sts` bundle in a staging directory and
/// only swaps it into place once it is complete, so a failed save can't destroy
/// the project it was overwriting. These cover the swap itself — the step that
/// has to be all-or-nothing.
final class ProjectStoreSwapTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectStoreSwapTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Builds a bundle-shaped directory holding `files` (name → contents).
    @discardableResult
    private func makeBundle(_ name: String, files: [String: String]) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for (filename, contents) in files {
            try Data(contents.utf8).write(to: url.appendingPathComponent(filename))
        }
        return url
    }

    private func contents(of bundle: URL, _ filename: String) throws -> String? {
        let url = bundle.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    func testSwapReplacesAnExistingBundle() throws {
        let destination = try makeBundle("Song.sts", files: ["project.json": "old"])
        let staged = try makeBundle("staged.sts", files: ["project.json": "new"])

        try ProjectStore.swapIntoPlace(staged: staged, at: destination)

        XCTAssertEqual(try contents(of: destination, "project.json"), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path),
                       "the staged bundle should be consumed by the swap")
    }

    func testSwapCreatesTheBundleWhenNoneExistsYet() throws {
        // First save of an untitled project: there is nothing to replace.
        let destination = root.appendingPathComponent("Fresh.sts", isDirectory: true)
        let staged = try makeBundle("staged.sts", files: ["project.json": "new"])

        try ProjectStore.swapIntoPlace(staged: staged, at: destination)

        XCTAssertEqual(try contents(of: destination, "project.json"), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
    }

    /// The swap replaces the bundle wholesale rather than merging into it —
    /// which is what drops the audio of clips that have since been deleted.
    func testSwapDoesNotLeaveStaleFilesBehind() throws {
        let destination = try makeBundle("Song.sts", files: [
            "project.json": "old",
            "orphan.caf": "audio for a deleted clip",
        ])
        let staged = try makeBundle("staged.sts", files: ["project.json": "new"])

        try ProjectStore.swapIntoPlace(staged: staged, at: destination)

        XCTAssertEqual(try contents(of: destination, "project.json"), "new")
        XCTAssertNil(try contents(of: destination, "orphan.caf"))
    }

    /// A staged bundle that was never completed must not touch the destination:
    /// the existing project stays exactly as it was.
    func testFailedSwapLeavesTheExistingBundleIntact() throws {
        let destination = try makeBundle("Song.sts", files: ["project.json": "old"])
        let missing = root.appendingPathComponent("never-written.sts", isDirectory: true)

        XCTAssertThrowsError(try ProjectStore.swapIntoPlace(staged: missing, at: destination))
        XCTAssertEqual(try contents(of: destination, "project.json"), "old")
    }

    // MARK: - Staging

    /// The staging directory has to be obtainable for a bundle that doesn't
    /// exist yet (a first save), and has to be writable under the app sandbox —
    /// these tests are app-hosted, so this exercises the real sandbox.
    func testStagingDirectoryIsUsableForABundleThatDoesNotExistYet() throws {
        let destination = root.appendingPathComponent("Fresh.sts", isDirectory: true)

        let staging = try ProjectStore.stagingDirectory(for: destination)
        defer { try? FileManager.default.removeItem(at: staging) }

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.path,
                                                     isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertNoThrow(try Data("probe".utf8)
            .write(to: staging.appendingPathComponent("probe")))
    }

    /// The whole cycle the real save runs: stage a bundle beside the
    /// destination, fill it, swap it in. Proves staging and swapping agree
    /// about volumes — a cross-volume staging directory would fail here.
    func testStageThenSwapReplacesTheProjectInPlace() throws {
        let destination = try makeBundle("Song.sts", files: [
            "project.json": "old",
            "orphan.caf": "audio for a deleted clip",
        ])

        let staging = try ProjectStore.stagingDirectory(for: destination)
        defer { try? FileManager.default.removeItem(at: staging) }
        let staged = staging.appendingPathComponent(destination.lastPathComponent)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: staged.appendingPathComponent("project.json"))

        try ProjectStore.swapIntoPlace(staged: staged, at: destination)

        XCTAssertEqual(try contents(of: destination, "project.json"), "new")
        XCTAssertNil(try contents(of: destination, "orphan.caf"))
    }
}
