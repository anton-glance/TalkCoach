import CoreAudio
import OSLog

/// Abstracts Core Audio HAL device queries and property listener registration.
/// Production wraps real C APIs; test fakes drive callbacks synchronously.
///
/// All methods are `nonisolated` — they are called from `MicMonitor.deinit`
/// (nonisolated) and from Core Audio dispatch queues.
protocol CoreAudioDeviceProvider: Sendable {
    nonisolated func defaultInputDeviceID() -> AudioObjectID?
    nonisolated func isDeviceRunningSomewhere(_ deviceID: AudioObjectID) -> Bool?
    nonisolated func addIsRunningListener(
        device: AudioObjectID,
        handler: @escaping @Sendable () -> Void
    ) -> AnyObject?
    nonisolated func removeIsRunningListener(device: AudioObjectID, token: AnyObject)
    nonisolated func addDefaultDeviceListener(
        handler: @escaping @Sendable () -> Void
    ) -> AnyObject?
    nonisolated func removeDefaultDeviceListener(token: AnyObject)
}

// MARK: - Production Implementation

struct SystemCoreAudioDeviceProvider: CoreAudioDeviceProvider {

    private nonisolated static let log = Logger(subsystem: "com.talkcoach.app", category: "mic")

    nonisolated func defaultInputDeviceID() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioObjectID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else {
            Self.log.warning("Failed to read default input device: OSStatus \(status)")
            return nil
        }
        return deviceID
    }

    nonisolated func isDeviceRunningSomewhere(_ deviceID: AudioObjectID) -> Bool? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &running
        )
        guard status == noErr else {
            Self.log.warning(
                "Failed to read IsRunningSomewhere on device \(deviceID): OSStatus \(status)"
            )
            return nil
        }
        return running != 0
    }

    nonisolated func addIsRunningListener(
        device: AudioObjectID,
        handler: @escaping @Sendable () -> Void
    ) -> AnyObject? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let queue = DispatchQueue(label: "com.talkcoach.mic.isRunning")
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            handler()
        }
        let status = AudioObjectAddPropertyListenerBlock(device, &address, queue, block)
        guard status == noErr else {
            Self.log.error(
                "Failed to add IsRunning listener on device \(device): OSStatus \(status)"
            )
            return nil
        }
        return ListenerToken(objectID: device, address: address, queue: queue, block: block)
    }

    nonisolated func removeIsRunningListener(device: AudioObjectID, token: AnyObject) {
        guard let listenerToken = token as? ListenerToken else { return }
        var address = listenerToken.address
        let status = AudioObjectRemovePropertyListenerBlock(
            listenerToken.objectID,
            &address,
            listenerToken.queue,
            listenerToken.block
        )
        if status != noErr {
            Self.log.warning("Failed to remove IsRunning listener: OSStatus \(status)")
        }
    }

    nonisolated func addDefaultDeviceListener(
        handler: @escaping @Sendable () -> Void
    ) -> AnyObject? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let queue = DispatchQueue(label: "com.talkcoach.mic.defaultDevice")
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            handler()
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            queue,
            block
        )
        guard status == noErr else {
            Self.log.error("Failed to add default-device listener: OSStatus \(status)")
            return nil
        }
        return ListenerToken(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            address: address,
            queue: queue,
            block: block
        )
    }

    nonisolated func removeDefaultDeviceListener(token: AnyObject) {
        guard let listenerToken = token as? ListenerToken else { return }
        var address = listenerToken.address
        let status = AudioObjectRemovePropertyListenerBlock(
            listenerToken.objectID,
            &address,
            listenerToken.queue,
            listenerToken.block
        )
        if status != noErr {
            Self.log.warning("Failed to remove default-device listener: OSStatus \(status)")
        }
    }
}

// MARK: - Listener Token

private final class ListenerToken: @unchecked Sendable {
    nonisolated let objectID: AudioObjectID
    nonisolated let address: AudioObjectPropertyAddress
    nonisolated let queue: DispatchQueue
    nonisolated(unsafe) let block: AudioObjectPropertyListenerBlock

    nonisolated init(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress,
        queue: DispatchQueue,
        block: @escaping AudioObjectPropertyListenerBlock
    ) {
        self.objectID = objectID
        self.address = address
        self.queue = queue
        self.block = block
    }
}
