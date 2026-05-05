import CoreAudio

/// Abstracts Core Audio HAL device queries and property listener registration.
/// Production wraps real C APIs; test fakes drive callbacks synchronously.
protocol CoreAudioDeviceProvider: Sendable {
    func defaultInputDeviceID() -> AudioObjectID?
    func isDeviceRunningSomewhere(_ deviceID: AudioObjectID) -> Bool?
    func addIsRunningListener(
        device: AudioObjectID,
        handler: @escaping @Sendable () -> Void
    ) -> AnyObject?
    func removeIsRunningListener(device: AudioObjectID, token: AnyObject)
    func addDefaultDeviceListener(
        handler: @escaping @Sendable () -> Void
    ) -> AnyObject?
    func removeDefaultDeviceListener(token: AnyObject)
}
