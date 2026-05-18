import CoreAudio
import Foundation
import OSLog

protocol AudioProcessProber: Sendable {
    /// Returns PIDs of processes (other than `ourPID` and system daemons) that currently
    /// have the default audio input device running.
    func externalReaders(excluding ourPID: pid_t) async -> [pid_t]
}

// MARK: - Filter helper

/// Returns true when the given audio process should count as an external reader competing
/// for the mic. Excludes the calling process itself and all com.apple.* system daemons
/// (CoreSpeech is permanently `IsRunningInput=true` on macOS 26).
nonisolated func isExternalReader(
    pid: pid_t,
    bundle: String,
    isRunningInput: Bool,
    ourPID: pid_t
) -> Bool {
    guard isRunningInput else { return false }
    guard pid != ourPID else { return false }
    guard !bundle.hasPrefix("com.apple.") else { return false }
    return true
}

// MARK: - Production implementation

private struct AudioProcessInfo {
    let pid: pid_t
    let bundle: String
    let isRunningInput: Bool
}

struct SystemAudioProcessProber: AudioProcessProber {
    func externalReaders(excluding ourPID: pid_t) async -> [pid_t] {
        var listAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var listSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &listAddr, 0, nil, &listSize
        ) == noErr, listSize > 0 else {
            Logger.audio.debug("AudioProcessProber: no process objects")
            return []
        }

        let count = Int(listSize) / MemoryLayout<AudioObjectID>.stride
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &listAddr, 0, nil, &listSize, &ids
        ) == noErr else {
            Logger.audio.warning("AudioProcessProber: failed to read process list")
            return []
        }

        var result: [pid_t] = []
        for objID in ids {
            guard let info = readProcess(objID: objID) else { continue }
            if isExternalReader(
                pid: info.pid,
                bundle: info.bundle,
                isRunningInput: info.isRunningInput,
                ourPID: ourPID
            ) {
                result.append(info.pid)
            }
        }
        Logger.audio.debug("AudioProcessProber: \(result.count) external reader(s)")
        return result
    }

    private func readProcess(objID: AudioObjectID) -> AudioProcessInfo? {
        var pidSize = UInt32(MemoryLayout<pid_t>.size)
        var pid: pid_t = 0
        var pidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(objID, &pidAddr, 0, nil, &pidSize, &pid) == noErr else {
            return nil
        }

        var runInSize = UInt32(MemoryLayout<UInt32>.size)
        var isRunningInput: UInt32 = 0
        var runInAddr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            objID, &runInAddr, 0, nil, &runInSize, &isRunningInput
        ) == noErr else { return nil }

        var bundle = ""
        var bundleAddr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var bundleSize: UInt32 = 0
        if AudioObjectGetPropertyDataSize(objID, &bundleAddr, 0, nil, &bundleSize) == noErr,
           bundleSize > 0 {
            var cfStr: CFString = "" as CFString
            if AudioObjectGetPropertyData(
                objID, &bundleAddr, 0, nil, &bundleSize, &cfStr
            ) == noErr {
                bundle = cfStr as String
            }
        }

        return AudioProcessInfo(pid: pid, bundle: bundle, isRunningInput: isRunningInput != 0)
    }
}
