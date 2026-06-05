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

    func recreate() {
        callLog.append("recreate")
    }

    func inputNodeInputFormat() -> AVAudioFormat? {
        nil
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

    // MARK: - Buffer flow

    func testStartProducesBufferWithinTimeout() async throws {
        makeSUT()
        try sut.start()

        let expectation = XCTestExpectation(description: "Buffer received")
        let stream = sut.mediumStream
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
        let stream = sut.mediumStream
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
        let stream = sut.mediumStream
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

    // Each start() after stop() reinstalls the tap on a fresh AsyncStream.
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

    // MARK: - Frame size

    func testFrameLengthMatchesDeliveredBuffer() async throws {
        makeSUT()
        try sut.start()

        var receivedBuffer: CapturedAudioBuffer?
        let expectation = XCTestExpectation(description: "Buffer received")
        let stream = sut.mediumStream
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

    // stop() removes the tap and finishes the session-lifetime mediumStream.
    // The next start() provides a fresh mediumStream for the next session (SE-0314).
    func testStop_RemovesTapAndFinishesCurrentStream() async throws {
        makeSUT()
        try sut.start()
        let streamFromSession1 = sut.mediumStream
        sut.stop()

        XCTAssertTrue(fake.callLog.contains("removeTap"),
                      "stop() must remove the AVAudioEngine tap")

        let finishExpectation = XCTestExpectation(description: "Session-1 stream finishes after stop()")
        let drainTask = Task { @MainActor in
            for await _ in streamFromSession1 {}
            finishExpectation.fulfill()
        }
        await fulfillment(of: [finishExpectation], timeout: 2.0)
        drainTask.cancel()
    }

    // Each session gets a NEW iterator on a fresh mediumStream — mirroring production behavior
    // where backends create a new feedTask per session after AudioPipeline.start() recreates the stream.
    func testAudioPipeline_Restart_AfterStopProducesBuffers() async throws {
        makeSUT()

        // Session 1: subscribe, deliver, stop
        try sut.start()
        let stream1 = sut.mediumStream
        var received1: [Int64] = []
        let exp1 = XCTestExpectation(description: "Session 1 buffer received")
        let task1 = Task { @MainActor in
            for await buffer in stream1 {
                received1.append(buffer.sampleTime)
                exp1.fulfill()
                break
            }
        }
        deliverSyntheticBuffer(sampleTime: 100)
        await fulfillment(of: [exp1], timeout: 2.0)
        sut.stop()
        await task1.value  // drains cleanly: stop() finishes the continuation

        // Session 2: fresh stream from start() — new iterator, new session
        try sut.start()
        let stream2 = sut.mediumStream
        var received2: [Int64] = []
        let exp2 = XCTestExpectation(description: "Session 2 buffer received on fresh stream")
        let task2 = Task { @MainActor in
            for await buffer in stream2 {
                received2.append(buffer.sampleTime)
                exp2.fulfill()
                break
            }
        }
        deliverSyntheticBuffer(sampleTime: 200)
        await fulfillment(of: [exp2], timeout: 2.0)
        sut.stop()
        await task2.value

        XCTAssertEqual(received1, [100], "Session 1 iterator must receive its buffer")
        XCTAssertEqual(received2, [200], "Session 2 iterator must receive its buffer via the fresh stream")
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

    // MARK: - Device switch (M6.8 Path B)

    // switchDevice() stops the engine and restarts it without finishing mediumStream,
    // so existing stream consumers see a brief buffer gap but not a stream termination.
    func testSwitchDevice_RecyclesEngineWithoutFinishingMediumStream() async throws {
        makeSUT()
        try sut.start()
        fake.callLog.removeAll()

        let stream = sut.mediumStream
        var received: [Int64] = []
        let exp = XCTestExpectation(description: "Two buffers received across switch")
        exp.expectedFulfillmentCount = 2
        let task = Task { @MainActor in
            for await buffer in stream {
                received.append(buffer.sampleTime)
                exp.fulfill()
                if received.count >= 2 { break }
            }
        }

        deliverSyntheticBuffer(sampleTime: 100)
        try await Task.sleep(for: .milliseconds(50))

        try await sut.switchDevice()

        // Engine must have been stopped and re-tapped
        XCTAssertTrue(fake.callLog.contains("stop"),
                      "switchDevice must stop the engine; callLog=\(fake.callLog)")
        XCTAssertEqual(fake.callLog.filter { $0 == "installTap" }.count, 1,
                       "switchDevice must reinstall the tap; callLog=\(fake.callLog)")

        // Deliver buffer after switch — must arrive on the SAME mediumStream iterator
        deliverSyntheticBuffer(sampleTime: 200)
        await fulfillment(of: [exp], timeout: 2.0)
        task.cancel()

        XCTAssertEqual(received.count, 2, "mediumStream must survive the engine switch (AC-SW7)")
        XCTAssertTrue(received.contains(200), "Post-switch buffer must be delivered on same stream")
    }

    // switchDevice() must call recreate() to replace the AVAudioEngine instance.
    // ORT cannot reinitialize OrtSessions in-process (Spike #18 / Session 034).
    func testSwitchDevice_CallsRecreateOnProvider() async throws {
        makeSUT()
        try sut.start()
        fake.callLog.removeAll()

        try await sut.switchDevice()

        XCTAssertTrue(fake.callLog.contains("recreate"),
                      "switchDevice must recreate the AVAudioEngine (Spike #18); callLog=\(fake.callLog)")
    }
}
