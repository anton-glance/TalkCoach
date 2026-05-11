import AVFAudio
import CoreAudio
import XCTest
@testable import TalkCoach

// MARK: - EventRecordingMicDelegate

@MainActor
private final class EventRecordingMicDelegate: MicMonitorDelegate {
    var activatedCount = 0
    var deactivatedCount = 0
    var events: [String] = []

    func micActivated() {
        activatedCount += 1
        events.append("activated@\(Date().timeIntervalSince1970)")
        print("[D] micActivated #\(activatedCount)")
    }

    func micDeactivated() {
        deactivatedCount += 1
        events.append("deactivated@\(Date().timeIntervalSince1970)")
        print("[D] micDeactivated #\(deactivatedCount)")
    }
}

// MARK: - MicMonitorCompositionDiagnostic

/// One-time diagnostic tests for Session 027.
/// Verifies the composition deadlock between MicMonitor and AudioPipeline:
/// once AudioPipeline.start() makes our process a HAL reader,
/// kAudioDevicePropertyDeviceIsRunningSomewhere stays true after an external
/// reader leaves, so micDeactivated never fires.
///
/// These tests are NOT part of the regular test suite — they exist to generate
/// empirical log evidence for the M3.7.1 architectural fix.
/// Run them manually with console open. AC-D2 requires QuickTime setup — see
/// individual test for instructions.
@MainActor
final class MicMonitorCompositionDiagnostic: XCTestCase {

    private var monitor: MicMonitor!
    private var delegate: EventRecordingMicDelegate!
    private let provider = SystemCoreAudioDeviceProvider()

    override func setUp() async throws {
        try await super.setUp()
        delegate = EventRecordingMicDelegate()
        monitor = MicMonitor(provider: provider)
        monitor.delegate = delegate
    }

    override func tearDown() async throws {
        monitor.stop()
        monitor = nil
        delegate = nil
        try await super.tearDown()
    }

    // AC-D1: Baseline — confirm that our own AVAudioEngine start/stop is visible to MicMonitor.
    // Expected: micActivated when engine starts (we become the reader), micDeactivated when engine stops.
    // This confirms the HAL listener works at all and that we ARE counted in IsRunningSomewhere.
    func testD1_OwnEngineIsVisibleToMicMonitor() async throws {
        guard let deviceID = provider.defaultInputDeviceID() else {
            throw XCTSkip("No default input device")
        }
        guard provider.isDeviceRunningSomewhere(deviceID) == false else {
            throw XCTSkip("Another process is already using the mic — baseline not clean")
        }

        monitor.start()
        printIsRunning(deviceID, label: "D1 before engine.start()")

        let engine = AVAudioEngine()
        // Accessing inputNode forces AVAudioSession to configure the input.
        _ = engine.inputNode
        try engine.start()
        printIsRunning(deviceID, label: "D1 after engine.start()")

        try await Task.sleep(nanoseconds: 1_000_000_000) // 1s

        engine.stop()
        printIsRunning(deviceID, label: "D1 after engine.stop()")

        try await Task.sleep(nanoseconds: 1_000_000_000) // 1s

        printIsRunning(deviceID, label: "D1 final")
        print("[D] D1 events: \(delegate.events)")
        // If micDeactivated fired → our engine.stop() IS detected (baseline confirmed).
        // If it did not → IsRunningSomewhere did not change (unexpected; environment issue).
        XCTAssertGreaterThan(delegate.activatedCount + delegate.deactivatedCount, 0,
                             "D1: Expected at least one MicMonitor event. Check console for IsRunningSomewhere values.")
    }

    // AC-D2: Core hypothesis test — deadlock when external reader is present.
    //
    // MANUAL SETUP REQUIRED:
    //   1. Open QuickTime Player.
    //   2. File → New Audio Recording. The recording indicator appears (mic is active).
    //   3. Do NOT click the Record button — the mic is already claimed by QuickTime.
    //   4. Run this test.
    //   5. When the test prints "Close QuickTime now...", close the QuickTime recording window.
    //   6. Observe console output.
    //
    // Expected with the current (broken) MicMonitor:
    //   micDeactivated does NOT fire after closing QuickTime — IsRunningSomewhere stays true.
    // Expected after the M3.7.1 fix:
    //   micDeactivated fires within ~100ms of closing QuickTime.
    func testD2_ExternalReaderDeadlock_RequiresManualQuickTimeSetup() async throws {
        guard let deviceID = provider.defaultInputDeviceID() else {
            throw XCTSkip("No default input device")
        }
        guard provider.isDeviceRunningSomewhere(deviceID) == true else {
            throw XCTSkip("No external reader active — open QuickTime New Audio Recording first")
        }

        monitor.start()
        printIsRunning(deviceID, label: "D2 external reader present, before our engine.start()")

        // Simulate what SessionCoordinator.runSession() does via AudioPipeline.start().
        let engine = AVAudioEngine()
        _ = engine.inputNode
        try engine.start()
        printIsRunning(deviceID, label: "D2 after our engine.start() — we are now also a reader")

        print("[D] D2: Close QuickTime recording window now. Waiting 10 seconds...")
        try await Task.sleep(nanoseconds: 10_000_000_000)

        printIsRunning(deviceID, label: "D2 after 10s (QuickTime should be closed)")
        print("[D] D2 events: \(delegate.events)")
        print("[D] D2 micDeactivated count: \(delegate.deactivatedCount)")
        print("[D] D2 HYPOTHESIS: micDeactivated should NOT have fired (broken) → \(delegate.deactivatedCount == 0 ? "CONFIRMED DEADLOCK" : "unexpected — fired \(delegate.deactivatedCount)x")")

        engine.stop()
        try await Task.sleep(nanoseconds: 500_000_000)
        printIsRunning(deviceID, label: "D2 after our engine.stop()")
        print("[D] D2 final events: \(delegate.events)")
    }

    // AC-D3: Probe kAudioHardwarePropertyProcessObjectList API availability and notification behavior.
    // This verifies the proposed fix surface is available in the current SDK.
    // Expected: dataSize status == noErr; each process object has a readable PID.
    func testD3_ProcessObjectListAPIAvailability() async throws {
        guard let deviceID = provider.defaultInputDeviceID() else {
            throw XCTSkip("No default input device")
        }

        // Query the system-level process object list.
        var sysAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &sysAddress, 0, nil, &dataSize
        )
        print("[D] D3: kAudioHardwarePropertyProcessObjectList dataSize status: \(sizeStatus), bytes: \(dataSize)")

        if sizeStatus == noErr && dataSize > 0 {
            let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
            var objectIDs = [AudioObjectID](repeating: kAudioObjectUnknown, count: count)
            let listStatus = AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &sysAddress, 0, nil, &dataSize, &objectIDs
            )
            print("[D] D3: Process object list status: \(listStatus), count: \(count)")

            let ourPID = ProcessInfo.processInfo.processIdentifier
            for objectID in objectIDs {
                var pidAddr = AudioObjectPropertyAddress(
                    mSelector: kAudioProcessPropertyPID,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                var pid: pid_t = -1
                var pidSize = UInt32(MemoryLayout<pid_t>.size)
                let pidStatus = AudioObjectGetPropertyData(objectID, &pidAddr, 0, nil, &pidSize, &pid)

                var inputAddr = AudioObjectPropertyAddress(
                    mSelector: kAudioProcessPropertyIsRunningInput,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                var isRunningInput: UInt32 = 0
                var inputSize = UInt32(MemoryLayout<UInt32>.size)
                let inputStatus = AudioObjectGetPropertyData(
                    objectID, &inputAddr, 0, nil, &inputSize, &isRunningInput
                )

                let selfTag = pid == ourPID ? " ← OUR PROCESS" : ""
                print("[D] D3:   objectID=\(objectID) pid=\(pid) (pidStatus=\(pidStatus)) isRunningInput=\(isRunningInput) (inputStatus=\(inputStatus))\(selfTag)")
            }

            // Attempt to listen on process object list changes — verify kAudioHardwarePropertyProcessObjectList is observable.
            var listenerFired = false
            let queue = DispatchQueue(label: "com.talkcoach.diagnostic.d3")
            let listenerBlock: AudioObjectPropertyListenerBlock = { _, _ in listenerFired = true }
            let addStatus = AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &sysAddress, queue, listenerBlock
            )
            print("[D] D3: Listener registration status: \(addStatus) (noErr=\(noErr)) — \(addStatus == noErr ? "OBSERVABLE" : "NOT OBSERVABLE")")

            if addStatus == noErr {
                // Start our own engine to trigger a process-list change.
                let engine = AVAudioEngine()
                _ = engine.inputNode
                try? engine.start()
                try await Task.sleep(nanoseconds: 500_000_000)
                engine.stop()
                try await Task.sleep(nanoseconds: 500_000_000)
                AudioObjectRemovePropertyListenerBlock(
                    AudioObjectID(kAudioObjectSystemObject), &sysAddress, queue, listenerBlock
                )
                print("[D] D3: Listener fired during engine start/stop: \(listenerFired)")
                print("[D] D3: kAudioHardwarePropertyProcessObjectList IS OBSERVABLE: \(listenerFired ? "YES — fix approach A is viable" : "NO — need per-process listeners or polling")")
            }
        }

        // Also query IsRunningSomewhere for comparison baseline.
        printIsRunning(deviceID, label: "D3 baseline")
    }

    // MARK: - Helpers

    private func printIsRunning(_ deviceID: AudioObjectID, label: String) {
        let running = provider.isDeviceRunningSomewhere(deviceID) ?? false
        print("[D] \(label): IsRunningSomewhere=\(running)")
    }
}
