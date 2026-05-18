import CoreAudio
import Foundation
import OSLog

// Filter design: Locto excludes only its own PID and a hardcoded Set of known always-on
// Apple system daemons (currently just `com.apple.CoreSpeech`). User-facing Apple apps
// under the `com.apple.*` prefix (Voice Memo, FaceTime, Music, QuickTime) are deliberately
// NOT filtered — they are the apps Locto is designed to coach the user during. Future macOS
// daemons added to the always-on set should be appended to `baselineBundleIDs` as smoke
// surfaces them.

protocol AudioProcessProber: Sendable {
    /// Returns PIDs of processes (other than `ourPID` and baseline system daemons) that
    /// currently have the default audio input device running.
    func externalReaders(excluding ourPID: pid_t) async -> [pid_t]
}

// MARK: - Filter helper

/// Bundle identifiers of always-on Apple system daemons that hold IsRunningInput=true
/// permanently. Spike #15 identified com.apple.CoreSpeech (system dictation, PID stable).
/// Add additional bundles here as future smoke testing surfaces them.
///
/// IMPORTANT: This is intentionally a hardcoded Set, not a prefix match. Many user-facing
/// Apple apps share the com.apple.* prefix (Voice Memos, FaceTime, Music, QuickTime),
/// and those MUST count as external readers — they are exactly the apps Locto is
/// designed to coach the user during.
nonisolated let baselineBundleIDs: Set<String> = [
    "com.apple.CoreSpeech"
]

/// Returns true when the given audio process should count as an external reader.
/// Excludes the calling process itself and known always-on system daemons in `baselineBundleIDs`.
/// User-facing Apple apps (Voice Memo, FaceTime, Music, QuickTime) are NOT excluded.
nonisolated func isExternalReader(
    pid: pid_t,
    bundle: String,
    isRunningInput: Bool,
    ourPID: pid_t
) -> Bool {
    guard isRunningInput else { return false }
    guard pid != ourPID else { return false }
    guard !baselineBundleIDs.contains(bundle) else { return false }
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
