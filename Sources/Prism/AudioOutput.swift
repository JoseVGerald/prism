import Foundation
import CoreAudio
import Observation

struct OutputDevice: Identifiable, Hashable {
    var id: AudioDeviceID
    var name: String
    var transport: String
    var isBluetooth: Bool
}

/// Lists the Mac's audio outputs and switches the system default between them.
///
/// This is the "room controls" piece: the speakers you have paired show up here
/// as soon as macOS has them connected, and picking one moves all system audio
/// — including Prism's — without a trip to Sound settings.
@MainActor
@Observable
final class AudioOutput {

    private(set) var devices: [OutputDevice] = []
    private(set) var currentId: AudioDeviceID = 0

    private var listenerInstalled = false

    init() {
        refresh()
        installListener()
    }

    var current: OutputDevice? { devices.first { $0.id == currentId } }

    func refresh() {
        devices = Self.outputDevices()
        currentId = Self.defaultOutput() ?? 0
    }

    /// Moves system audio to `device`. Returns false if CoreAudio refused.
    @discardableResult
    func select(_ device: OutputDevice) -> Bool {
        var id = device.id
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &id)
        if status == noErr { currentId = device.id }
        return status == noErr
    }

    // MARK: CoreAudio

    /// Rebuilds the list when a device appears, disappears, or becomes default —
    /// which is what happens the moment a Bluetooth speaker connects.
    private func installListener() {
        guard !listenerInstalled else { return }
        listenerInstalled = true
        for selector in [kAudioHardwarePropertyDevices,
                         kAudioHardwarePropertyDefaultOutputDevice] {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main
            ) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
    }

    private static func defaultOutput() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return status == noErr ? id : nil
    }

    private static func outputDevices() -> [OutputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.compactMap { id -> OutputDevice? in
            // A device with no output streams is an input — a microphone should
            // not appear in a speaker picker.
            guard outputStreamCount(id) > 0 else { return nil }
            guard let name = stringProperty(id, kAudioObjectPropertyName) else { return nil }
            let transport = transportName(id)
            return OutputDevice(id: id, name: name, transport: transport,
                                isBluetooth: transport == "Bluetooth")
        }
        // Bluetooth first: those are the ones worth switching between.
        .sorted { ($0.isBluetooth ? 0 : 1, $0.name) < ($1.isBluetooth ? 0 : 1, $1.name) }
    }

    private static func outputStreamCount(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0
        else { return 0 }

        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }

        let list = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(_ id: AudioDeviceID,
                                       _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }

    private static func transportName(_ id: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var type: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &type) == noErr
        else { return "Unknown" }

        switch type {
        case kAudioDeviceTransportTypeBluetooth,
             kAudioDeviceTransportTypeBluetoothLE: return "Bluetooth"
        case kAudioDeviceTransportTypeBuiltIn:     return "Built-in"
        case kAudioDeviceTransportTypeAirPlay:     return "AirPlay"
        case kAudioDeviceTransportTypeUSB:         return "USB"
        case kAudioDeviceTransportTypeHDMI:        return "HDMI"
        case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
        case kAudioDeviceTransportTypeVirtual,
             kAudioDeviceTransportTypeAggregate:   return "Virtual"
        default:                                   return "Other"
        }
    }
}
