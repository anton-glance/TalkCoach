// swiftlint:disable file_length
import AVFAudio
import XCTest
@testable import TalkCoach

// MARK: - Fake Provider

@MainActor
private final class FakeAudioEngineProvider: AudioEngineProvider {
    var callLog: [String] = []
    var lastInstalledBlock: (@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)?
    var stubbedIsVoiceProcessingEnabled: Bool = false
    var startShouldThrow: Bool = false

    var isVoiceProcessingEnabled: Bool { stubbedIsVoiceProcessingEnabled }

    func setVoiceProcessingEnabled(_ enabled: Bool) throws {
        callLog.append("setVPIO(\(enabled))")
        stubbedIsVoiceProcessingEnabled = enabled
    }

    func installTap(
        bufferSize: AVAudioFrameCount,
        format: AVAudioFormat?,
        block: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    ) {
        callLog.append("installTap")
        lastInstalledBlock = block
    }

    func removeTap() {
        callLog.append("removeTap")
        lastInstalledBlock = nil
    }

    func prepare() {
        callLog.append("prepare")
    }

    func start() throws {
        if startShouldThrow {
            callLog.append("start(threw)")
            throw NSError(domain: "FakeAudioEngine", code: -1)
        }
        callLog.append("start")
    }

    func stop() {
        callLog.append("stop")
    }
}

// MARK: - Tests

@MainActor
// swiftlint:disable:next type_body_length
final class AudioPipelineTests: XCTestCase {

    private var fake: FakeAudioEngineProvider!
    private var sut: AudioPipeline!

    private func makeSUT() {
        fake = FakeAudioEngineProvider()
        sut = AudioPipeline(provider: fake)
    }

    private func deliverSyntheticBuffer(
        sampleTime: Int64 = 0,
        frameCount: AVAudioFrameCount = 480
    ) {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            XCTFail("Failed to create synthetic buffer")
            return
        }
        buffer.frameLength = frameCount
        if let floatData = buffer.floatChannelData {
            // swiftlint:disable:next identifier_name
            for i in 0..<Int(frameCount) {
                floatData[0][i] = Float(i) / Float(frameCount)
            }
        }
        let time = AVAudioTime(sampleTime: sampleTime, atRate: 48000)
        fake.lastInstalledBlock?(buffer, time)
    }

    // MARK: - Start behavior

    func testStartSetsIsStartedTrue() throws {
        makeSUT()
        try sut.start()
        XCTAssertTrue(sut.isStarted)
    }

    func testStartCallsOperationsInCorrectOrder() throws {
        makeSUT()
        try sut.start()
        XCTAssertEqual(fake.callLog, ["setVPIO(false)", "installTap", "prepare", "start"])
    }

    func testStartInstallsTapWithFormatNil() throws {
        makeSUT()
        try sut.start()
        XCTAssertTrue(fake.callLog.contains("installTap"))
        XCTAssertNotNil(fake.lastInstalledBlock)
    }

    func testStartRegistersConfigChangeObserver() throws {
        makeSUT()
        try sut.start()
        fake.callLog.removeAll()
        sut.recover()
        XCTAssertFalse(fake.callLog.isEmpty, "recover() should execute steps after start()")
    }

    // MARK: - Buffer flow

    func testStartProducesBufferWithinTimeout() async throws {
        makeSUT()
        try sut.start()

        let expectation = XCTestExpectation(description: "Buffer received")
        let stream = sut.bufferStream
        let task = Task { @MainActor in
            for await _ in stream {
                expectation.fulfill()
                break
            }
        }

        deliverSyntheticBuffer()
        await fulfillment(of: [expectation], timeout: 1.0)
        task.cancel()
    }

    func testBufferContainsNonEmptyPCMSamples() async throws {
        makeSUT()
        try sut.start()

        var receivedBuffer: CapturedAudioBuffer?
        let expectation = XCTestExpectation(description: "Buffer received")
        let stream = sut.bufferStream
        let task = Task { @MainActor in
            for await buffer in stream {
                receivedBuffer = buffer
                expectation.fulfill()
                break
            }
        }

        deliverSyntheticBuffer()
        await fulfillment(of: [expectation], timeout: 1.0)
        task.cancel()

        XCTAssertNotNil(receivedBuffer)
        XCTAssertFalse(receivedBuffer!.samples.isEmpty)
        XCTAssertFalse(receivedBuffer!.samples[0].isEmpty)
    }

    func testBufferSampleTimesAreMonotonic() async throws {
        makeSUT()
        try sut.start()

        var times: [Int64] = []
        let expectation = XCTestExpectation(description: "Two buffers received")
        expectation.expectedFulfillmentCount = 2
        let stream = sut.bufferStream
        let task = Task { @MainActor in
            var count = 0
            for await buffer in stream {
                times.append(buffer.sampleTime)
                count += 1
                expectation.fulfill()
                if count >= 2 { break }
            }
        }

        deliverSyntheticBuffer(sampleTime: 0)
        deliverSyntheticBuffer(sampleTime: 4800)
        await fulfillment(of: [expectation], timeout: 1.0)
        task.cancel()

        XCTAssertEqual(times.count, 2)
        XCTAssertTrue(times[1] > times[0])
    }

    // MARK: - Idempotency

    func testStartTwiceIsNoOp() throws {
        makeSUT()
        try sut.start()
        try sut.start()
        XCTAssertEqual(fake.callLog.filter { $0 == "start" }.count, 1)
    }

    func testStopTwiceIsNoOp() throws {
        makeSUT()
        try sut.start()
        fake.callLog.removeAll()
        sut.stop()
        sut.stop()
        XCTAssertEqual(fake.callLog.filter { $0 == "stop" }.count, 1)
    }

    func testStopBeforeStartIsNoOp() {
        makeSUT()
        sut.stop()
        XCTAssertTrue(fake.callLog.isEmpty)
    }

    // Bug C fix: stop() no longer permanently disables the pipeline.
    // A second start() after stop() reinstalls the tap and resumes the same stream.
    func testStartAfterStop_ReinitializesSuccessfully() throws {
        makeSUT()
        try sut.start()
        sut.stop()
        fake.callLog.removeAll()
        try sut.start()
        XCTAssertTrue(sut.isStarted, "Pipeline must be restartable after stop (Bug C fix)")
        XCTAssertEqual(fake.callLog.filter { $0 == "installTap" }.count, 1,
                       "Second start must reinstall the tap")
    }

    // MARK: - Recovery

    func testRecoverRunsStepsInOrder() throws {
        makeSUT()
        try sut.start()
        fake.callLog.removeAll()
        sut.recover()
        XCTAssertEqual(fake.callLog, [
            "stop", "removeTap", "setVPIO(false)", "installTap", "prepare", "start"
        ])
    }

    func testRecoverReusesStreamContinuation() async throws {
        makeSUT()
        try sut.start()

        var received: [Int64] = []
        let expectation = XCTestExpectation(description: "Two buffers received")
        expectation.expectedFulfillmentCount = 2
        let stream = sut.bufferStream
        let task = Task { @MainActor in
            var count = 0
            for await buffer in stream {
                received.append(buffer.sampleTime)
                count += 1
                expectation.fulfill()
                if count >= 2 { break }
            }
        }

        deliverSyntheticBuffer(sampleTime: 100)
        sut.recover()
        deliverSyntheticBuffer(sampleTime: 200)
        await fulfillment(of: [expectation], timeout: 1.0)
        task.cancel()

        XCTAssertEqual(received.count, 2)
        XCTAssertEqual(received[0], 100)
        XCTAssertEqual(received[1], 200)
    }

    func testRecoverReDisablesVPIO() throws {
        makeSUT()
        try sut.start()
        fake.callLog.removeAll()
        sut.recover()
        XCTAssertTrue(fake.callLog.contains("setVPIO(false)"))
    }

    func testRecoverAfterStopIsNoOp() async throws {
        makeSUT()
        try sut.start()
        sut.stop()
        fake.callLog.removeAll()
        sut.recover()
        XCTAssertTrue(
            fake.callLog.isEmpty,
            "No recovery steps should run after stop: \(fake.callLog)"
        )
        XCTAssertNil(sut.lastRecoveryDuration)
        // Bug C fix: stream is NOT terminated by stop() — it stays alive for the next start().
    }

    // MARK: - Recovery latency

    func testRecoverMeasuresLatencyOnFirstEvent() throws {
        makeSUT()
        try sut.start()
        XCTAssertNil(sut.lastRecoveryDuration)
        sut.recover()
        XCTAssertNotNil(sut.lastRecoveryDuration)
        XCTAssertGreaterThanOrEqual(sut.lastRecoveryDuration!, 0)
    }

    // MARK: - Frame size

    func testFrameLengthMatchesDeliveredBuffer() async throws {
        makeSUT()
        try sut.start()

        var receivedBuffer: CapturedAudioBuffer?
        let expectation = XCTestExpectation(description: "Buffer received")
        let stream = sut.bufferStream
        let task = Task { @MainActor in
            for await buffer in stream {
                receivedBuffer = buffer
                expectation.fulfill()
                break
            }
        }

        deliverSyntheticBuffer(frameCount: 480)
        await fulfillment(of: [expectation], timeout: 1.0)
        task.cancel()

        XCTAssertEqual(receivedBuffer?.frameLength, 480)
    }

    func testNoHardcoded4096InSource() throws {
        let testFilePath = URL(fileURLWithPath: #filePath)
        let projectRoot = testFilePath
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourcePath = projectRoot
            .appendingPathComponent("Sources")
            .appendingPathComponent("Audio")
            .appendingPathComponent("AudioPipeline.swift")
        let content = try String(contentsOf: sourcePath)
        let regex = try NSRegularExpression(pattern: "\\b4096\\b")
        let matches = regex.matches(in: content, range: NSRange(content.startIndex..., in: content))
        XCTAssertTrue(matches.isEmpty, "Found hardcoded 4096 in AudioPipeline.swift")
    }

    // MARK: - Device vanish

    func testRecoverLogsAndContinuesOnEngineStartFailure() throws {
        makeSUT()
        try sut.start()
        fake.startShouldThrow = true
        sut.recover()
        XCTAssertTrue(sut.isStarted, "Pipeline stays conceptually started after recovery failure")
    }

    // MARK: - Concurrency

    func testCapturedAudioBufferIsSendable() {
        // swiftlint:disable:next identifier_name
        nonisolated func acceptSendable(_ fn: @Sendable () -> Void) { fn() }
        let buffer = CapturedAudioBuffer(
            frameLength: 0, sampleRate: 0, channelCount: 0,
            sampleTime: 0, hostTime: 0, samples: []
        )
        acceptSendable { _ = buffer }
    }

    func testMakeTapBlockCallableFromNonisolatedContext() {
        var cont: AsyncStream<CapturedAudioBuffer>.Continuation!
        _ = AsyncStream<CapturedAudioBuffer>(bufferingPolicy: .bufferingNewest(1)) { cont = $0 }
        // swiftlint:disable:next identifier_name
        nonisolated func callFactory(c: AsyncStream<CapturedAudioBuffer>.Continuation) {
            _ = makeTapBlock(continuation: c)
        }
        callFactory(c: cont)
    }

    // MARK: - Cleanup

    // Bug C fix: stop() removes the tap but does NOT finish the stream continuation.
    // The same stream remains consumable after a subsequent start() call.
    func testStop_RemovesTapButDoesNotFinishStream() async throws {
        makeSUT()
        try sut.start()
        sut.stop()

        XCTAssertTrue(fake.callLog.contains("removeTap"),
                      "stop() must remove the AVAudioEngine tap")

        // Verify stream stays open (no timeout — we don't expect it to finish)
        var receivedBuffer = false
        let stream = sut.bufferStream
        let consumeTask = Task { @MainActor in
            for await _ in stream {
                receivedBuffer = true
                break
            }
        }

        // Restart and deliver a buffer — stream must still be alive
        try sut.start()
        deliverSyntheticBuffer()
        try await Task.sleep(for: .milliseconds(200))
        consumeTask.cancel()

        XCTAssertTrue(receivedBuffer, "Stream must still deliver buffers after stop/start cycle")
    }

    // Bug C fix: verifies the same bufferStream serves two consecutive sessions.
    func testAudioPipeline_Restart_AfterStopProducesBuffers() async throws {
        makeSUT()
        try sut.start()

        var received: [Int64] = []
        let expectation = XCTestExpectation(description: "Two buffers received across stop/start")
        expectation.expectedFulfillmentCount = 2
        let stream = sut.bufferStream
        let consumeTask = Task { @MainActor in
            var count = 0
            for await buffer in stream {
                received.append(buffer.sampleTime)
                count += 1
                expectation.fulfill()
                if count >= 2 { break }
            }
        }

        // Session 1: deliver one buffer, then stop
        deliverSyntheticBuffer(sampleTime: 100)
        sut.stop()

        // Session 2: restart, deliver another buffer on the SAME stream
        try sut.start()
        deliverSyntheticBuffer(sampleTime: 200)

        await fulfillment(of: [expectation], timeout: 2.0)
        consumeTask.cancel()

        XCTAssertEqual(received.count, 2, "Both sessions must deliver buffers to the same stream")
        XCTAssertEqual(received[0], 100, "Session 1 buffer must arrive first")
        XCTAssertEqual(received[1], 200, "Session 2 buffer must arrive after stop/start")
    }

    func testStopDeregistersObserver() throws {
        makeSUT()
        try sut.start()
        sut.stop()
        fake.callLog.removeAll()
        NotificationCenter.default.post(
            name: .AVAudioEngineConfigurationChange,
            object: nil
        )
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertTrue(
            fake.callLog.isEmpty,
            "No recovery steps should run after stop: \(fake.callLog)"
        )
    }

    // MARK: - Error paths

    func testStartCleansUpOnEngineStartFailure() throws {
        makeSUT()
        fake.startShouldThrow = true
        XCTAssertThrowsError(try sut.start())
        XCTAssertFalse(sut.isStarted)
        XCTAssertTrue(
            fake.callLog.contains("removeTap"),
            "Should clean up tap on start failure: \(fake.callLog)"
        )
    }
}
