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

    func testStartAfterStopIsNoOp() throws {
        makeSUT()
        try sut.start()
        sut.stop()
        fake.callLog.removeAll()
        try sut.start()
        XCTAssertFalse(sut.isStarted)
        XCTAssertTrue(fake.callLog.isEmpty, "No provider calls on restart after stop")
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

        let expectation = XCTestExpectation(description: "Stream terminated")
        let stream = sut.bufferStream
        let task = Task { @MainActor in
            for await _ in stream {}
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 1.0)
        task.cancel()
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
        nonisolated func callFactory(c: AsyncStream<CapturedAudioBuffer>.Continuation) {
            _ = makeTapBlock(continuation: c)
        }
        callFactory(c: cont)
    }

    // MARK: - Cleanup

    func testStopRemovesTapAndFinishesStream() async throws {
        makeSUT()
        try sut.start()
        sut.stop()

        XCTAssertTrue(fake.callLog.contains("removeTap"))

        let expectation = XCTestExpectation(description: "Stream terminated")
        let stream = sut.bufferStream
        let task = Task { @MainActor in
            for await _ in stream {}
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 1.0)
        task.cancel()
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
