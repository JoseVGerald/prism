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
        // Never leave the Mac pointed at a device that goes away with Prism.
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("NSApplicationWillTerminateNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.leaveSeveral() }
        }
    }

    var current: OutputDevice? { devices.first { $0.id == currentId } }

    /// The outputs playing now: one, or several joined by Prism.
    private(set) var playing: [OutputDevice] = []
    /// Prism's own multi-output device while several are playing.
    private var joined: AudioDeviceID?
    static let joinedUID = "com.gerald.prism.several-outputs"

    /// A name for what is playing: "AirPods + MacBook Air Speakers".
    var playingName: String {
        playing.count > 1 ? playing.map(\.name).joined(separator: " + ") : (current?.name ?? "Output")
    }

    func refresh() {
        // Prism's own joined device is shown as its parts, never as itself.
        devices = Self.outputDevices().filter { Self.uid($0.id) != Self.joinedUID }
        currentId = Self.defaultOutput() ?? 0
        if joined == nil || currentId != joined {
            playing = current.map { [$0] } ?? []
        }
    }

    /// Plays on every one of `devices` at once.
    ///
    /// A stacked aggregate — what Audio MIDI Setup calls a Multi-Output
    /// Device — made here and set as the system output, so everything goes to
    /// all of them. The clock is taken from a wired or built-in output where
    /// there is one, and the rest are drift-corrected to it, since two
    /// Bluetooth clocks left alone slide apart over a song. What drift
    /// correction cannot fix is latency: Bluetooth runs a few hundred
    /// milliseconds behind a wired speaker, so two outputs in one room echo;
    /// two pairs of headphones do not.
    @discardableResult
    func playOnSeveral(_ chosen: [OutputDevice]) -> Bool {
        guard chosen.count > 1 else {
            if let one = chosen.first { return select(one) }
            return false
        }
        let ordered = chosen.sorted { ($0.isBluetooth ? 1 : 0) < ($1.isBluetooth ? 1 : 0) }
        let uids = ordered.compactMap { Self.uid($0.id) }
        guard uids.count == ordered.count else { return false }
        tearDownJoined()

        let subs: [[String: Any]] = uids.enumerated().map { i, uid in
            [kAudioSubDeviceUIDKey: uid, kAudioSubDeviceDriftCompensationKey: i == 0 ? 0 : 1]
        }
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Prism — " + ordered.map(\.name).joined(separator: " + "),
            kAudioAggregateDeviceUIDKey: Self.joinedUID,
            kAudioAggregateDeviceSubDeviceListKey: subs,
            kAudioAggregateDeviceMainSubDeviceKey: uids[0],
            kAudioAggregateDeviceIsStackedKey: 1,
            kAudioAggregateDeviceIsPrivateKey: 0,
        ]
        var id = AudioDeviceID(0)
        guard AudioHardwareCreateAggregateDevice(description as CFDictionary, &id) == noErr, id != 0
        else { return false }
        joined = id
        guard setDefault(id) else { tearDownJoined(); return false }
        currentId = id
        playing = ordered
        return true
    }

    /// Back to one output: the first of the joined ones that still exists.
    func leaveSeveral() {
        guard joined != nil else { return }
        let back = playing.first { d in devices.contains { $0.id == d.id } }
        if let back { _ = setDefault(back.id) }
        tearDownJoined()
        refresh()
    }

    private func tearDownJoined() {
        if let id = joined { AudioHardwareDestroyAggregateDevice(id) }
        joined = nil
        // One left behind by a run that ended without tidying up.
        if let stale = Self.devices(withUID: Self.joinedUID) {
            AudioHardwareDestroyAggregateDevice(stale)
        }
    }

    private func setDefault(_ id: AudioDeviceID) -> Bool {
        var id = id
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        return AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &id) == noErr
    }

    private static func uid(_ id: AudioDeviceID) -> String? {
        stringProperty(id, kAudioDevicePropertyDeviceUID)
    }

    private static func devices(withUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return nil }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return nil }
        return ids.first { Self.uid($0) == uid }
    }

    /// Moves system audio to `device`. Returns false if CoreAudio refused.
    @discardableResult
    func select(_ device: OutputDevice) -> Bool {
        if joined != nil {
            _ = setDefault(device.id)
            tearDownJoined()
            refresh()
            return currentId == device.id
        }
        var id = device.id
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &id)
        if status == noErr { currentId = device.id; playing = [device] }
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
