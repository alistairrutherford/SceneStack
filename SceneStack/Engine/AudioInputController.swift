import AVFoundation
import AudioToolbox

/// Brings the microphone input online and keeps it healthy.
///
/// macOS input bring-up is finicky: the engine's input and output can share
/// one HAL I/O unit, a device change needs a full stop/reset/prepare cycle,
/// and the capture tap must exist before `start()` or the input unit comes up
/// uninitialised. This type encapsulates that sequence — with a fallback to
/// the system default input — so the coordinator only sees a simple outcome.
@MainActor
final class AudioInputController {

    enum ConfigureOutcome {
        case success
        case successUsingDefault
        case permissionDenied
        case failed(String)
    }

    let devices = DeviceManager()
    private(set) var isConfigured = false

    private let graph: AudioGraph
    private let recorder: RecordingService

    init(graph: AudioGraph, recorder: RecordingService) {
        self.graph = graph
        self.recorder = recorder
    }

    /// Requests permission (if needed) and brings the input online, falling
    /// back to the system default device if the selected one won't start.
    func configure() async -> ConfigureOutcome {
        guard await AVAudioApplication.requestRecordPermission() else {
            return .permissionDenied
        }
        log("=== configure; permission=\(AVAudioApplication.shared.recordPermission.rawValue) selected=\(devices.selectedDevice?.name ?? "nil") isDefault=\(devices.isSelectedDeviceSystemDefault)")

        // Only touch the I/O unit's device for a non-default input; on macOS
        // input/output can share one HAL unit and re-pointing it at a mic
        // device can fail output init (-10875).
        let needsExplicitDevice = !devices.isSelectedDeviceSystemDefault
        do {
            try bringUp(setDevice: needsExplicitDevice)
            isConfigured = true
            log("configure OK (explicitDevice=\(needsExplicitDevice))")
            return .success
        } catch {
            log("attempt 1 failed: \(error)")
            // Retry without touching the device — captures the system default.
            do {
                try bringUp(setDevice: false)
                devices.markSelectionAsSystemDefault()
                isConfigured = true
                log("attempt 2 (no device set) OK")
                return .successUsingDefault
            } catch {
                log("attempt 2 failed: \(error)")
                recorder.removeTap(from: graph.inputNode)
                isConfigured = false
                return .failed("Could not configure input: \(error.localizedDescription) — if this app was rebuilt recently, macOS may hold a stale microphone grant; run `tccutil reset Microphone com.example.SceneStack` in Terminal and try again.")
            }
        }
    }

    /// Marks the input as needing reconfiguration (e.g. the device changed
    /// while the transport was rolling — applied on the next stopped bring-up).
    func invalidate() { isConfigured = false }

    /// Removes the capture tap and marks the input unconfigured (e.g. the
    /// active device was unplugged).
    func teardown() {
        recorder.removeTap(from: graph.inputNode)
        isConfigured = false
    }

    // MARK: - Bring-up

    /// Ordering matters: reset tears down the previous render state so a
    /// device change takes; prepare initialises I/O so the input bus reports
    /// real formats; the tap must be in place before start so the input unit
    /// comes up connected.
    private func bringUp(setDevice: Bool) throws {
        let input = graph.inputNode
        graph.stop()
        recorder.removeTap(from: input)
        graph.reset()
        if setDevice {
            try devices.applySelectedDevice(to: input)
        }
        graph.prepare()

        let hardware = input.inputFormat(forBus: 0)
        let bus = input.outputFormat(forBus: 0)
        log("bring-up setDevice=\(setDevice) sharedIOUnit=\(graph.sharesIOUnit) hw=\(Int(hardware.sampleRate))Hz/\(hardware.channelCount)ch bus=\(Int(bus.sampleRate))Hz/\(bus.channelCount)ch")

        guard hardware.sampleRate > 0, hardware.channelCount > 0 else {
            throw NSError(domain: "SceneStack", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "Input device reports no usable channels (\(Int(hardware.sampleRate)) Hz, \(hardware.channelCount) ch)",
            ])
        }
        recorder.installTap(on: input)
        try graph.startThrowing()
    }

    // MARK: - Logging

    /// Appends a diagnostic line to Application Support/input-debug.log so
    /// input bring-up failures can be diagnosed after the fact.
    private func log(_ line: String) {
        guard let directory = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true) else { return }
        let url = directory.appendingPathComponent("input-debug.log")
        let stamped = "\(Date().formatted(date: .omitted, time: .standard)) \(line)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(stamped.utf8))
            try? handle.close()
        } else {
            try? Data(stamped.utf8).write(to: url)
        }
    }
}
