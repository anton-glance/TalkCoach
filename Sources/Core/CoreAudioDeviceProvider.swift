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

    // MARK: External process tracking (M3.7.1)

    /// Returns all process objectIDs currently registered with the HAL.
    nonisolated func processObjects() -> [AudioObjectID]
    /// Returns the PID for a HAL process object, or nil on error.
    nonisolated func pid(of processObjectID: AudioObjectID) -> pid_t?
    /// Returns true if the given process object has an active input I/O proc.
    nonisolated func isProcessRunningInput(_ processObjectID: AudioObjectID) -> Bool
    /// Returns the PID of the current process (used to filter self from the list).
    nonisolated func selfPID() -> pid_t
    /// Registers a listener that fires whenever the HAL process list changes.
    nonisolated func addProcessObjectListListener(
        handler: @escaping @Sendable () -> Void
    ) -> AnyObject?
    nonisolated func removeProcessObjectListListener(token: AnyObject)
}

// MARK: - Default stubs for test fakes that don't exercise external process tracking

extension CoreAudioDeviceProvider {
    nonisolated func processObjects() -> [AudioObjectID] { [] }
    nonisolated func pid(of processObjectID: AudioObjectID) -> pid_t? { nil }
    nonisolated func isProcessRunningInput(_ processObjectID: AudioObjectID) -> Bool { false }
    nonisolated func selfPID() -> pid_t { ProcessInfo.processInfo.processIdentifier }
    nonisolated func addProcessObjectListListener(
        handler: @escaping @Sendable () -> Void
    ) -> AnyObject? { nil }
    nonisolated func removeProcessObjectListListener(token: AnyObject) {}
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

    // MARK: External process tracking (M3.7.1)

    nonisolated func processObjects() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        )
        guard sizeStatus == noErr, dataSize > 0 else { return [] }
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var objects = [AudioObjectID](repeating: 0, count: count)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &objects
        )
        guard status == noErr else { return [] }
        return objects
    }

    nonisolated func pid(of processObjectID: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var p: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        let status = AudioObjectGetPropertyData(processObjectID, &address, 0, nil, &size, &p)
        guard status == noErr else { return nil }
        return p
    }

    nonisolated func isProcessRunningInput(_ processObjectID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(processObjectID, &address, 0, nil, &size, &value)
        guard status == noErr else { return false }
        return value != 0
    }

    nonisolated func selfPID() -> pid_t {
        ProcessInfo.processInfo.processIdentifier
    }

    nonisolated func addProcessObjectListListener(
        handler: @escaping @Sendable () -> Void
    ) -> AnyObject? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let queue = DispatchQueue(label: "com.talkcoach.mic.processObjectList")
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, queue, block
        )
        guard status == noErr else {
            Self.log.error("Failed to add ProcessObjectList listener: OSStatus \(status)")
            return nil
        }
        return ListenerToken(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            address: address, queue: queue, block: block
        )
    }

    nonisolated func removeProcessObjectListListener(token: AnyObject) {
        guard let listenerToken = token as? ListenerToken else { return }
        var address = listenerToken.address
        AudioObjectRemovePropertyListenerBlock(
            listenerToken.objectID, &address, listenerToken.queue, listenerToken.block
        )
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
