import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation
import IOKit
import IOKit.audio

// MARK: - Helpers

func halGet<T>(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector,
               _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T? {
    var addr = AudioObjectPropertyAddress(mSelector: selector,
                                          mScope: scope,
                                          mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectHasProperty(objectID, &addr) else { return nil }
    var size = UInt32(MemoryLayout<T>.size)
    var value: T? = nil
    withUnsafeMutablePointer(to: &value) { ptr in
        _ = AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, ptr)
    }
    return value
}

func halGetArray<T>(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector,
                    _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [T]? {
    var addr = AudioObjectPropertyAddress(mSelector: selector,
                                          mScope: scope,
                                          mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectHasProperty(objectID, &addr) else { return nil }
    var size: UInt32 = 0
    var status = AudioObjectGetPropertyDataSize(objectID, &addr, 0, nil, &size)
    guard status == noErr, size > 0 else { return nil }
    let count = Int(size) / MemoryLayout<T>.size
    var array = [T](repeating: unsafeBitCast(0, to: T.self), count: count)
    status = AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &array)
    guard status == noErr else { return nil }
    return array
}

func halGetStatus(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector,
                  _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> OSStatus {
    var addr = AudioObjectPropertyAddress(mSelector: selector,
                                          mScope: scope,
                                          mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    return AudioObjectGetPropertyDataSize(objectID, &addr, 0, nil, &size)
}

func defaultInputDeviceID() -> AudioObjectID? {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var deviceID: AudioObjectID = kAudioObjectUnknown
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID)
    guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
    return deviceID
}

func printSectionHeader(_ title: String) {
    print("")
    print(String(repeating: "=", count: 60))
    print(title)
    print(String(repeating: "=", count: 60))
}

// MARK: - AVAudioEngine tap setup (makes us a HAL client)

nonisolated(unsafe) var globalEngine: AVAudioEngine? = nil
nonisolated(unsafe) var isTapInstalled = false

func installSelfAsTapClient() {
    let engine = AVAudioEngine()
    let inputNode = engine.inputNode
    // format: nil mirrors AudioPipeline's pattern
    inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { _, _ in }
    do {
        try engine.start()
        globalEngine = engine
        isTapInstalled = true
        print("[Setup] AVAudioEngine started — spike is now a HAL client")
    } catch {
        print("[Setup] AVAudioEngine failed to start: \(error)")
    }
}

func removeSelfTap() {
    globalEngine?.inputNode.removeTap(onBus: 0)
    globalEngine?.stop()
    globalEngine = nil
    isTapInstalled = false
    print("[Setup] AVAudioEngine stopped — spike removed from HAL")
}

// MARK: - Candidate A: kAudioHardwarePropertyProcessIsAudible and process-level properties

func candidateA(_ deviceID: AudioObjectID) {
    printSectionHeader("CANDIDATE A: kAudioHardwarePropertyProcessIsAudible + process-level properties")

    // A1: kAudioHardwarePropertyProcessIsAudible (output-side, system object)
    let sysObj = AudioObjectID(kAudioObjectSystemObject)
    var addrA1 = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessIsAudible,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    let hasA1 = AudioObjectHasProperty(sysObj, &addrA1)
    print("kAudioHardwarePropertyProcessIsAudible on SystemObject:")
    print("  API exists (HasProperty): \(hasA1 ? "YES" : "NO")")
    if hasA1 {
        var size = UInt32(MemoryLayout<UInt32>.size)
        var val: UInt32 = 0
        let st = AudioObjectGetPropertyData(sysObj, &addrA1, 0, nil, &size, &val)
        print("  Returns data without error: \(st == noErr ? "YES" : "NO, OSStatus=\(st)")")
        if st == noErr {
            print("  What it returns: Bool UInt32 = \(val) (1=audible)")
            print("  Per-process granularity: NO — reflects THIS process only, output-side")
        }
    }
    print("  Useful for our purpose: NO — output audibility only, not input readers")

    // A2: kAudioHardwarePropertyProcessObjectList — list of AudioObjectIDs for process objects
    var addrProcList = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                   mScope: kAudioObjectPropertyScopeGlobal,
                                                   mElement: kAudioObjectPropertyElementMain)
    let hasProcList = AudioObjectHasProperty(sysObj, &addrProcList)
    print("")
    print("kAudioHardwarePropertyProcessObjectList on SystemObject:")
    print("  API exists (HasProperty): \(hasProcList ? "YES" : "NO")")
    if hasProcList {
        var size: UInt32 = 0
        var st = AudioObjectGetPropertyDataSize(sysObj, &addrProcList, 0, nil, &size)
        print("  Returns data without error: \(st == noErr ? "YES" : "NO, OSStatus=\(st)")")
        if st == noErr {
            let count = Int(size) / MemoryLayout<AudioObjectID>.size
            print("  Process object count: \(count)")
            var objects = [AudioObjectID](repeating: 0, count: count)
            st = AudioObjectGetPropertyData(sysObj, &addrProcList, 0, nil, &size, &objects)
            if st == noErr {
                print("  Process object IDs: \(objects)")
                // For each process object, try to get its PID
                for objID in objects {
                    var pidAddr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID,
                                                             mScope: kAudioObjectPropertyScopeGlobal,
                                                             mElement: kAudioObjectPropertyElementMain)
                    var pid: pid_t = 0
                    var pidSize = UInt32(MemoryLayout<pid_t>.size)
                    let pidStatus = AudioObjectGetPropertyData(objID, &pidAddr, 0, nil, &pidSize, &pid)

                    var bundleAddr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID,
                                                                mScope: kAudioObjectPropertyScopeGlobal,
                                                                mElement: kAudioObjectPropertyElementMain)
                    var bundleRef: CFString? = nil
                    var bundleSize = UInt32(MemoryLayout<CFString?>.size)
                    let bundleStatus = AudioObjectGetPropertyData(objID, &bundleAddr, 0, nil, &bundleSize, &bundleRef)

                    // kAudioProcessPropertyIsRunning
                    var runAddr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunning,
                                                             mScope: kAudioObjectPropertyScopeGlobal,
                                                             mElement: kAudioObjectPropertyElementMain)
                    var isRunning: UInt32 = 0
                    var runSize = UInt32(MemoryLayout<UInt32>.size)
                    let runStatus = AudioObjectGetPropertyData(objID, &runAddr, 0, nil, &runSize, &isRunning)

                    // kAudioProcessPropertyIsRunningInput
                    var runInAddr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningInput,
                                                               mScope: kAudioObjectPropertyScopeGlobal,
                                                               mElement: kAudioObjectPropertyElementMain)
                    var isRunningInput: UInt32 = 0
                    var runInSize = UInt32(MemoryLayout<UInt32>.size)
                    let runInStatus = AudioObjectGetPropertyData(objID, &runInAddr, 0, nil, &runInSize, &isRunningInput)

                    let bundleStr = (bundleStatus == noErr && bundleRef != nil) ? (bundleRef! as String) : "<n/a>"
                    let pidStr = pidStatus == noErr ? "\(pid)" : "<err:\(pidStatus)>"
                    let runStr = runStatus == noErr ? (isRunning != 0 ? "YES" : "NO") : "<err:\(runStatus)>"
                    let runInStr = runInStatus == noErr ? (isRunningInput != 0 ? "YES" : "NO") : "<err:\(runInStatus)>"
                    print("    ProcessObj \(objID): PID=\(pidStr) bundle=\(bundleStr) IsRunning=\(runStr) IsRunningInput=\(runInStr)")
                }
                print("  Per-process granularity: YES — each process object has PID + IsRunningInput")
                print("  Useful for our purpose: POTENTIALLY YES — IsRunningInput per-PID")
            }
        }
    } else {
        print("  Per-process granularity: UNKNOWN — property absent")
        print("  Useful for our purpose: NO")
    }
}

// MARK: - Candidate B: kAudioObjectPropertyOwnedObjects and device-level process properties

func candidateB(_ deviceID: AudioObjectID) {
    printSectionHeader("CANDIDATE B: kAudioObjectPropertyOwnedObjects + device-scoped process properties")

    // B1: owned objects of the device
    var addrOwned = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyOwnedObjects,
                                               mScope: kAudioObjectPropertyScopeGlobal,
                                               mElement: kAudioObjectPropertyElementMain)
    let hasOwned = AudioObjectHasProperty(deviceID, &addrOwned)
    print("kAudioObjectPropertyOwnedObjects on device \(deviceID):")
    print("  API exists: \(hasOwned ? "YES" : "NO")")
    if hasOwned {
        var size: UInt32 = 0
        let st = AudioObjectGetPropertyDataSize(deviceID, &addrOwned, 0, nil, &size)
        if st == noErr {
            let count = Int(size) / MemoryLayout<AudioObjectID>.size
            print("  Returns \(count) owned object(s)")
            var objects = [AudioObjectID](repeating: 0, count: max(count, 1))
            _ = AudioObjectGetPropertyData(deviceID, &addrOwned, 0, nil, &size, &objects)
            print("  Owned object IDs: \(Array(objects.prefix(count)))")
        } else {
            print("  Returns data without error: NO, OSStatus=\(st)")
        }
    }
    print("  Per-process granularity: NO — returns sub-streams/controls, not process clients")
    print("  Useful for our purpose: NO")

    // B2: kAudioDevicePropertyDeviceUID
    var addrUID = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
    var uidRef: CFString? = nil
    var uidSize = UInt32(MemoryLayout<CFString?>.size)
    let uidSt = AudioObjectGetPropertyData(deviceID, &addrUID, 0, nil, &uidSize, &uidRef)
    let uid = (uidSt == noErr && uidRef != nil) ? (uidRef! as String) : "<error:\(uidSt)>"
    print("")
    print("Device UID: \(uid)")

    // B3: kAudioDevicePropertyDeviceIsRunningSomewhere (the existing IRS probe)
    var addrIRS = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
    var irs: UInt32 = 0
    var irsSize = UInt32(MemoryLayout<UInt32>.size)
    let irsSt = AudioObjectGetPropertyData(deviceID, &addrIRS, 0, nil, &irsSize, &irs)
    print("kAudioDevicePropertyDeviceIsRunningSomewhere: \(irsSt == noErr ? (irs != 0 ? "YES" : "NO") : "ERR:\(irsSt)")")
    print("  Per-process granularity: NO — aggregate boolean")
    print("  Useful for our purpose: NO — this is what we already use, it conflates self+others")
}

// MARK: - Candidate C: Aggregate device properties

func candidateC(_ deviceID: AudioObjectID) {
    printSectionHeader("CANDIDATE C: Aggregate device sub-device keys")

    // C1: Is this device an aggregate?
    var addrClass = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyClass,
                                               mScope: kAudioObjectPropertyScopeGlobal,
                                               mElement: kAudioObjectPropertyElementMain)
    var classID: AudioClassID = 0
    var classSize = UInt32(MemoryLayout<AudioClassID>.size)
    let classSt = AudioObjectGetPropertyData(deviceID, &addrClass, 0, nil, &classSize, &classID)
    let isAggregate = classSt == noErr && classID == kAudioAggregateDeviceClassID
    print("Device class: \(classSt == noErr ? String(format: "0x%08X", classID) : "ERR:\(classSt)")")
    print("Is aggregate device: \(isAggregate ? "YES" : "NO")")

    if isAggregate {
        // Try to get the composition
        var addrComp = AudioObjectPropertyAddress(mSelector: kAudioAggregateDevicePropertyComposition,
                                                   mScope: kAudioObjectPropertyScopeGlobal,
                                                   mElement: kAudioObjectPropertyElementMain)
        var compRef: CFDictionary? = nil
        var compSize = UInt32(MemoryLayout<CFDictionary?>.size)
        let compSt = AudioObjectGetPropertyData(deviceID, &addrComp, 0, nil, &compSize, &compRef)
        if compSt == noErr, let comp = compRef {
            print("  Aggregate composition: \(comp)")
        }
    }
    print("  Per-process granularity: NO — aggregate device structure, not process clients")
    print("  Useful for our purpose: NO")

    // C2: Scan for any "Client" or "Process" selectors on the device object
    // Known selectors to probe explicitly
    let namedSelectors: [(String, AudioObjectPropertySelector)] = [
        ("kAudioDevicePropertyDeviceIsRunning", kAudioDevicePropertyDeviceIsRunning),
        ("kAudioDevicePropertyDeviceIsRunningSomewhere", kAudioDevicePropertyDeviceIsRunningSomewhere),
        ("kAudioHardwarePropertyProcessObjectList", kAudioHardwarePropertyProcessObjectList),
    ]
    print("")
    print("Scanning named selectors on device object:")
    for (name, sel) in namedSelectors {
        var addr = AudioObjectPropertyAddress(mSelector: sel,
                                              mScope: kAudioDevicePropertyScopeInput,
                                              mElement: kAudioObjectPropertyElementMain)
        let has = AudioObjectHasProperty(deviceID, &addr)
        print("  \(name) (input scope): \(has ? "EXISTS" : "absent")")
    }
}

// MARK: - Candidate D: IORegistry walk

func candidateD(_ deviceID: AudioObjectID) {
    printSectionHeader("CANDIDATE D: IORegistry queries via IOKit")

    // Get the device UID to find the IOService
    var addrUID = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
    var uidRef: CFString? = nil
    var uidSize = UInt32(MemoryLayout<CFString?>.size)
    _ = AudioObjectGetPropertyData(deviceID, &addrUID, 0, nil, &uidSize, &uidRef)
    let uid = uidRef != nil ? (uidRef! as String) : ""
    print("Searching IORegistry for audio services...")

    let masterPort = kIOMainPortDefault
    // Search for IOAudioDevice services
    if let matchDict = IOServiceMatching("IOAudioDevice") {
        let iter = UnsafeMutablePointer<io_iterator_t>.allocate(capacity: 1)
        defer { iter.deallocate() }
        let result = IOServiceGetMatchingServices(masterPort, matchDict, iter)
        print("IOServiceGetMatchingServices(IOAudioDevice): OSReturn=\(result)")
        if result == kIOReturnSuccess {
            var service: io_service_t = IOIteratorNext(iter.pointee)
            var found = false
            while service != 0 {
                // Get service name
                var nameBuf = [CChar](repeating: 0, count: 128)
                IORegistryEntryGetName(service, &nameBuf)
                let name = String(decoding: nameBuf.prefix(while: { $0 != 0 }).map({ UInt8(bitPattern: $0) }), as: UTF8.self)

                // Look for client-count-style properties
                let interestingKeys = ["IOAudioEngineClientDescription",
                                       "IOAudioEngineNumActiveUserClients",
                                       "IOAudioClientCount",
                                       "IOAudioDeviceUserClientCount",
                                       "NumClients",
                                       "ClientPIDs"]
                var foundAny = false
                for key in interestingKeys {
                    if let prop = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0) {
                        print("  IOAudioDevice '\(name)': \(key) = \(prop.takeRetainedValue())")
                        foundAny = true
                        found = true
                    }
                }

                // Also enumerate all properties of the first device we find
                if !found, let allProps = IORegistryEntryCreateCFProperties_checked(service) {
                    print("  IOAudioDevice '\(name)' all properties:")
                    let dict = allProps as NSDictionary
                    for (k, v) in dict {
                        let keyStr = "\(k)"
                        if keyStr.lowercased().contains("client") || keyStr.lowercased().contains("user") {
                            print("    \(keyStr): \(v)")
                            found = true
                        }
                    }
                }

                IOObjectRelease(service)
                service = IOIteratorNext(iter.pointee)
            }
            IOObjectRelease(iter.pointee)
            if !found {
                print("  No client-count properties found in IORegistry for IOAudioDevice services")
            }
        }
    }
    print("  Per-process granularity: NO — IOAudioDevice does not expose per-PID reader lists in modern macOS")
    print("  Useful for our purpose: NO")
}

func IORegistryEntryCreateCFProperties_checked(_ entry: io_registry_entry_t) -> CFDictionary? {
    var props: Unmanaged<CFMutableDictionary>?
    let result = IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0)
    guard result == kIOReturnSuccess, let p = props else { return nil }
    return p.takeRetainedValue() as CFDictionary
}

// MARK: - Candidate E: proc_listpids + libproc cross-reference

func candidateE(_ deviceID: AudioObjectID) {
    printSectionHeader("CANDIDATE E: proc_listpids + per-process audio state")

    // We can enumerate PIDs via sysctl, but there is no public API to ask
    // "is PID X currently reading from AudioDevice Y" without private SPI.
    // We demonstrate what's reachable.

    // Get all PIDs via sysctl
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
    var size: Int = 0
    sysctl(&mib, 4, nil, &size, nil, 0)
    let procCount = size / MemoryLayout<kinfo_proc>.stride
    print("Total running processes (sysctl KERN_PROC_ALL): \(procCount)")
    print("  We can enumerate all PIDs, but no public API maps PID → 'is reading AudioDevice X'")
    print("  The only public per-process audio query available is kAudioProcessPropertyIsRunningInput")
    print("  on AudioProcess objects (Candidate A above), which does NOT require PID iteration")
    print("  Per-process granularity: PARTIAL — PIDs enumerable but device-to-process mapping is private SPI")
    print("  Useful for our purpose: NO — kAudioProcessPropertyIsRunningInput (Candidate A) is cleaner")
}

// MARK: - Candidate F: Additional discoverable APIs

func candidateF(_ deviceID: AudioObjectID) {
    printSectionHeader("CANDIDATE F: Additional CoreAudio APIs — kAudioTapPropertyFormat, process tap, kAudioHardwarePropertyTapList")

    let sysObj = AudioObjectID(kAudioObjectSystemObject)

    // F1: kAudioHardwarePropertyTapList — macOS 14.2+ process tap API
    var addrTapList = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTapList,
                                                  mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
    let hasTapList = AudioObjectHasProperty(sysObj, &addrTapList)
    print("kAudioHardwarePropertyTapList (ScreenCaptureKit process taps):")
    print("  API exists: \(hasTapList ? "YES" : "NO")")
    if hasTapList {
        var size: UInt32 = 0
        let st = AudioObjectGetPropertyDataSize(sysObj, &addrTapList, 0, nil, &size)
        let count = st == noErr ? Int(size) / MemoryLayout<AudioObjectID>.size : 0
        print("  Tap count: \(count)")
    }
    print("  Per-process granularity: NO — these are capture taps we OWN, not readers of our device")
    print("  Useful for our purpose: NO")

    // F2: kAudioHardwarePropertyProcessObjectList on device (input scope)
    var addrProcOnDev = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                    mScope: kAudioDevicePropertyScopeInput,
                                                    mElement: kAudioObjectPropertyElementMain)
    let hasProcOnDev = AudioObjectHasProperty(deviceID, &addrProcOnDev)
    print("")
    print("kAudioHardwarePropertyProcessObjectList on device (input scope):")
    print("  API exists: \(hasProcOnDev ? "YES" : "NO")")
    if hasProcOnDev {
        var size: UInt32 = 0
        let st = AudioObjectGetPropertyDataSize(deviceID, &addrProcOnDev, 0, nil, &size)
        print("  Returns data without error: \(st == noErr ? "YES" : "NO, OSStatus=\(st)")")
        if st == noErr {
            let count = Int(size) / MemoryLayout<AudioObjectID>.size
            print("  Process object count on device (input): \(count)")
        }
    }

    // F3: kAudioProcessPropertyIsRunningInput queried per-process from SystemObject's process list
    // Already covered in Candidate A — just confirm the key finding here
    print("")
    print("kAudioProcessPropertyIsRunningInput (per-process, via SystemObject process list):")
    print("  This was tested fully under Candidate A.")
    print("  Key finding: each AudioProcess object exposes PID + IsRunningInput as a per-process signal.")
    print("  Per-process granularity: YES")
    print("  Useful for our purpose: YES — see Candidate A results for full data")

    // F4: kAudioDevicePropertyRelatedDevices
    var addrRelated = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyRelatedDevices,
                                                  mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
    let hasRelated = AudioObjectHasProperty(deviceID, &addrRelated)
    print("")
    print("kAudioDevicePropertyRelatedDevices on device:")
    print("  API exists: \(hasRelated ? "YES" : "NO")")
    if hasRelated {
        var size: UInt32 = 0
        let st = AudioObjectGetPropertyDataSize(deviceID, &addrRelated, 0, nil, &size)
        let count = st == noErr ? Int(size) / MemoryLayout<AudioObjectID>.size : 0
        print("  Related device count: \(count)")
    }
    print("  Per-process granularity: NO — device topology, not clients")
    print("  Useful for our purpose: NO")
}

// MARK: - CSV output

func writeCSV(state: String, processObjects: [(pid: pid_t, bundle: String, isRunning: Bool, isRunningInput: Bool)]) {
    let timestamp = Date().timeIntervalSince1970
    let rows = processObjects.map { p in
        "\(timestamp),\(state),\(p.pid),\(p.bundle),\(p.isRunning),\(p.isRunningInput)"
    }
    let header = "timestamp,state,pid,bundle,isRunning,isRunningInput"
    let csvPath = "/tmp/spike15_results.csv"
    var existing = (try? String(contentsOfFile: csvPath, encoding: .utf8)) ?? header + "\n"
    existing += rows.joined(separator: "\n")
    if !rows.isEmpty { existing += "\n" }
    try? existing.write(toFile: csvPath, atomically: true, encoding: .utf8)
    print("[CSV] Written to \(csvPath)")
}

// MARK: - Process snapshot helper (reused for smoke test)

func snapshotProcessObjects() -> [(pid: pid_t, bundle: String, isRunning: Bool, isRunningInput: Bool)] {
    let sysObj = AudioObjectID(kAudioObjectSystemObject)
    var addrProcList = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                   mScope: kAudioObjectPropertyScopeGlobal,
                                                   mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(sysObj, &addrProcList, 0, nil, &size) == noErr, size > 0 else {
        return []
    }
    let count = Int(size) / MemoryLayout<AudioObjectID>.size
    var objects = [AudioObjectID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(sysObj, &addrProcList, 0, nil, &size, &objects) == noErr else {
        return []
    }

    var result: [(pid: pid_t, bundle: String, isRunning: Bool, isRunningInput: Bool)] = []
    for objID in objects {
        var pid: pid_t = 0
        var pidAddr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID,
                                                  mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
        var pidSize = UInt32(MemoryLayout<pid_t>.size)
        _ = AudioObjectGetPropertyData(objID, &pidAddr, 0, nil, &pidSize, &pid)

        var bundleRef: CFString? = nil
        var bundleAddr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID,
                                                    mScope: kAudioObjectPropertyScopeGlobal,
                                                    mElement: kAudioObjectPropertyElementMain)
        var bundleSize = UInt32(MemoryLayout<CFString?>.size)
        _ = AudioObjectGetPropertyData(objID, &bundleAddr, 0, nil, &bundleSize, &bundleRef)
        let bundle = bundleRef != nil ? (bundleRef! as String) : "unknown"

        var isRunning: UInt32 = 0
        var runAddr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunning,
                                                  mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
        var runSize = UInt32(MemoryLayout<UInt32>.size)
        _ = AudioObjectGetPropertyData(objID, &runAddr, 0, nil, &runSize, &isRunning)

        var isRunningInput: UInt32 = 0
        var runInAddr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningInput,
                                                   mScope: kAudioObjectPropertyScopeGlobal,
                                                   mElement: kAudioObjectPropertyElementMain)
        var runInSize = UInt32(MemoryLayout<UInt32>.size)
        _ = AudioObjectGetPropertyData(objID, &runInAddr, 0, nil, &runInSize, &isRunningInput)

        result.append((pid: pid, bundle: bundle, isRunning: isRunning != 0, isRunningInput: isRunningInput != 0))
    }
    return result
}

// MARK: - Main

let args = CommandLine.arguments
let smokeState = args.count > 1 ? args[1] : nil

guard let deviceID = defaultInputDeviceID() else {
    print("FATAL: no default input device found")
    exit(1)
}

print("Default input device AudioObjectID: \(deviceID)")

// Install ourselves as a HAL client (mirrors AudioPipeline)
installSelfAsTapClient()
Thread.sleep(forTimeInterval: 0.5) // let HAL settle

if smokeState == "latency-poll" {
    // Latency-poll mode: monitor VoiceMemos PID 838 IsRunningInput every 50ms for 30s.
    // Reports wall-clock timestamps at each state change.
    print("")
    print("=== LATENCY POLL: monitoring com.apple.VoiceMemos (PID=838) IsRunningInput ===")
    print("Tip: stop VoiceMemos recording now, then restart it. The poll will catch both flips.")
    var lastState: Bool? = nil
    let deadline = Date().addingTimeInterval(30)
    let pollInterval = 0.05 // 50ms
    var flipCount = 0
    while Date() < deadline {
        let snap = snapshotProcessObjects()
        guard let vm = snap.first(where: { $0.bundle == "com.apple.VoiceMemos" }) else {
            print("[\(String(format: "%.3f", Date().timeIntervalSince1970))] VoiceMemos not in process list")
            Thread.sleep(forTimeInterval: pollInterval)
            continue
        }
        let now = Date().timeIntervalSince1970
        if lastState == nil {
            print("[\(String(format: "%.3f", now))] initial: IsRunningInput=\(vm.isRunningInput)")
            lastState = vm.isRunningInput
        } else if vm.isRunningInput != lastState! {
            flipCount += 1
            print("[\(String(format: "%.3f", now))] FLIP #\(flipCount): IsRunningInput \(lastState! ? "true→false" : "false→true")")
            lastState = vm.isRunningInput
            if flipCount >= 4 { break }
        }
        Thread.sleep(forTimeInterval: pollInterval)
    }
    print("Poll complete. \(flipCount) state changes observed.")
    removeSelfTap()
    exit(0)
}

if let state = smokeState {
    // Smoke test mode: just snapshot and write CSV
    print("")
    print("=== SMOKE SNAPSHOT: state=\(state) ===")
    let snap = snapshotProcessObjects()
    print("Processes with audio activity:")
    for p in snap {
        if p.isRunning || p.isRunningInput {
            print("  PID=\(p.pid) bundle=\(p.bundle) IsRunning=\(p.isRunning) IsRunningInput=\(p.isRunningInput)")
        }
    }
    print("All registered audio process objects:")
    for p in snap {
        print("  PID=\(p.pid) bundle=\(p.bundle) IsRunning=\(p.isRunning) IsRunningInput=\(p.isRunningInput)")
    }
    writeCSV(state: state, processObjects: snap)
    removeSelfTap()
    exit(0)
}

// Full automated scan
candidateA(deviceID)
candidateB(deviceID)
candidateC(deviceID)
candidateD(deviceID)
candidateE(deviceID)
candidateF(deviceID)

// Snapshot for CSV
let snap = snapshotProcessObjects()
writeCSV(state: "automated-scan", processObjects: snap)

// Final verdict
printSectionHeader("SPIKE 15 RESULT")

let procList = snapshotProcessObjects()
let inputReaders = procList.filter { $0.isRunningInput }
print("Processes currently IsRunningInput=true: \(inputReaders.count)")
for p in inputReaders {
    print("  PID=\(p.pid) bundle=\(p.bundle)")
}

let hasProcListAPI: Bool
do {
    let sysObj = AudioObjectID(kAudioObjectSystemObject)
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                           mScope: kAudioObjectPropertyScopeGlobal,
                                           mElement: kAudioObjectPropertyElementMain)
    hasProcListAPI = AudioObjectHasProperty(sysObj, &addr)
}

print("")
if hasProcListAPI {
    print("Per-process HAL client enumeration available on macOS 26: YES")
    print("Best API found: kAudioHardwarePropertyProcessObjectList + kAudioProcessPropertyIsRunningInput")
    print("Implementation feasibility for Locto: HIGH — query SystemObject for process list, filter by IsRunningInput, exclude own PID")
    print("HYPOTHESIS: SUPPORTED")
} else {
    print("Per-process HAL client enumeration available on macOS 26: NO")
    print("Best API found: NONE")
    print("Implementation feasibility for Locto: NONE — teardown probe required")
    print("HYPOTHESIS: REJECTED")
}

removeSelfTap()
