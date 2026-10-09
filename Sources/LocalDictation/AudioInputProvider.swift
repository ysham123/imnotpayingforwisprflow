import AudioToolbox
import CoreAudio
import Foundation

struct AudioInputDevice: Equatable, Sendable {
    let id: UInt32
    let uid: String
    let name: String
}

struct AudioInputResolution: Equatable, Sendable {
    let device: AudioInputDevice
    let fallbackNotice: String?
}

/// Reads the input inventory and resolves stable saved UIDs. Selecting an input
/// changes only our audio unit; it never changes the Mac's default microphone.
enum AudioInputProvider {
    static func devices() -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
              size >= MemoryLayout<AudioDeviceID>.size else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        let status = ids.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, $0.baseAddress!)
        }
        guard status == noErr else { return [] }
        return ids.compactMap { id in
            guard isAlive(id), hasInput(id),
                  let uid = string(id, selector: kAudioDevicePropertyDeviceUID),
                  let name = string(id, selector: kAudioObjectPropertyName) else { return nil }
            return AudioInputDevice(id: id, uid: uid, name: name)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func resolve(uid: String?) throws -> AudioInputResolution {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return try resolve(uid: uid, available: devices(), defaultID: status == noErr ? id : nil)
    }

    // Inventory injection keeps missing-device behavior independently testable.
    static func resolve(uid: String?, available: [AudioInputDevice], defaultID: UInt32?) throws -> AudioInputResolution {
        let selectedUID = uid.flatMap { $0.isEmpty ? nil : $0 }
        if let selectedUID, let device = available.first(where: { $0.uid == selectedUID }) {
            return AudioInputResolution(device: device, fallbackNotice: nil)
        }
        guard let device = available.first(where: { $0.id == defaultID }) else {
            throw AudioRecorder.RecordingError.unavailableInput
        }
        return AudioInputResolution(device: device,
            fallbackNotice: selectedUID == nil ? nil : "Your selected microphone is unavailable. Using \(device.name), the system default.")
    }

    static func isAlive(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsAlive,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &alive) == noErr && alive != 0
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                 mScope: kAudioDevicePropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func string(_ id: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        // CoreAudio transfers ownership of the name/UID CFObject to the caller.
        return value?.takeRetainedValue() as String?
    }
}

/// A removed device may not emit an engine-format notification. Listen to its
/// liveness and the hardware inventory as well, then finish the captured prefix.
final class AudioInputMonitor {
    private let deviceID: AudioDeviceID
    private let listener: AudioObjectPropertyListenerBlock
    private var aliveAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsAlive,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    private var inventoryAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)

    init(deviceID: AudioDeviceID, onDisconnect: @escaping @Sendable () -> Void) {
        self.deviceID = deviceID
        listener = { _, _ in
            if !AudioInputProvider.isAlive(deviceID) { onDisconnect() }
        }
        AudioObjectAddPropertyListenerBlock(deviceID, &aliveAddress, .main, listener)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &inventoryAddress, .main, listener)
        // Close the gap between resolving/starting an input and installing its
        // observers. A device removed during that gap cannot notify us later.
        if !AudioInputProvider.isAlive(deviceID) { onDisconnect() }
    }

    deinit {
        AudioObjectRemovePropertyListenerBlock(deviceID, &aliveAddress, .main, listener)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &inventoryAddress, .main, listener)
    }
}
