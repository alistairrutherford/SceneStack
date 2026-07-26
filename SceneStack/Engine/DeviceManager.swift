import AudioToolbox
import CoreAudio
import AVFoundation
import Observation

/// Enumerates Core Audio input devices, tracks hot-plug changes, and applies
/// the selected device to the engine's input node.
///
/// Defaults to the built-in microphone; external interfaces are selectable
/// from the input picker.
@MainActor
@Observable
final class DeviceManager {

    struct InputDevice: Identifiable, Hashable {
        let id: AudioDeviceID
        let name: String
        let isBuiltIn: Bool
    }

    private(set) var inputDevices: [InputDevice] = []
    var selectedDeviceID: AudioDeviceID?
    @ObservationIgnored var onDeviceListChanged: (() -> Void)?

    var selectedDevice: InputDevice? {
        inputDevices.first { $0.id == selectedDeviceID }
    }

    init() {
        refresh()
        installHotPlugListener()
    }

    // MARK: - Enumeration

    func refresh() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size) == noErr else { return }

        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &ids) == noErr else { return }

        inputDevices = ids.compactMap { id in
            guard inputStreamCount(of: id) > 0 else { return nil }
            return InputDevice(id: id, name: name(of: id) ?? "Unknown device", isBuiltIn: isBuiltIn(id))
        }

        // Default to the built-in mic; fall back to the system default input.
        if selectedDeviceID == nil || !inputDevices.contains(where: { $0.id == selectedDeviceID }) {
            selectedDeviceID = inputDevices.first(where: \.isBuiltIn)?.id
                ?? systemDefaultInputID()
                ?? inputDevices.first?.id
        }
    }

    /// Points the engine's input node at the selected device.
    /// The engine must be stopped when this is called. `setDeviceID` (unlike
    /// raw `AudioUnitSetProperty`) manages the HAL unit's initialisation
    /// state, avoiding kAudioUnitErr_Uninitialized (-10867) on restart.
    func applySelectedDevice(to inputNode: AVAudioInputNode) throws {
        guard let deviceID = selectedDeviceID else { return }
        try inputNode.auAudioUnit.setDeviceID(deviceID)
    }

    /// True when the user's selection is already the system default input —
    /// in that case the engine needs no explicit device set at all, which
    /// avoids touching the I/O unit (on macOS the engine's input and output
    /// can share one HAL unit; re-pointing it at a mic can break output
    /// initialisation with kAudioUnitErr_FailedInitialization).
    var isSelectedDeviceSystemDefault: Bool {
        selectedDeviceID == systemDefaultInputID()
    }

    func markSelectionAsSystemDefault() {
        if let id = systemDefaultInputID() { selectedDeviceID = id }
    }

    // MARK: - Hot-plug

    private func installHotPlugListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main
        ) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refresh()
                self.onDeviceListChanged?()
            }
        }
    }

    // MARK: - Property helpers

    private func inputStreamCount(of id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr else { return 0 }
        return Int(size) / MemoryLayout<AudioStreamID>.size
    }

    private func name(of id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceName: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &deviceName) { pointer in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else { return nil }
        return deviceName as String?
    }

    private func isBuiltIn(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var transportType: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &transportType) == noErr else {
            return false
        }
        return transportType == kAudioDeviceTransportTypeBuiltIn
    }

    func systemDefaultInputID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &deviceID) == noErr,
              deviceID != 0 else { return nil }
        return deviceID
    }
}
