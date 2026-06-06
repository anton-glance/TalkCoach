import AVFAudio
import XCTest
@testable import TalkCoach

// MARK: - SwitchTestEngineProvider (local duplicate — original in DeviceSwitchTests.swift is private)

@MainActor
private final class SwitchTestEngineProvider: AudioEngineProvider {
    var callLog: [String] = []
    var lastInstalledBlock: (@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)?
    var lastInstalledFormat: AVAudioFormat?
    var startShouldThrow = false
    var stubbedInputFormat: AVAudioFormat? = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)
    var isVoiceProcessingEnabled: Bool { false }

    func setVoiceProcessingEnabled(_ enabled: Bool) throws {}
    func installTap(
        bufferSize: AVAudioFrameCount,
        format: AVAudioFormat?,
        block: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    ) {
        callLog.append("installTap")
        lastInstalledBlock = block
        lastInstalledFormat = format
    }
    func removeTap() { callLog.append("removeTap"); lastInstalledBlock = nil }
    func prepare() {}
    func start() throws {
        if startShouldThrow { throw NSError(domain: "SwitchTestEngine", code: -1) }
        callLog.append("start")
    }
    func stop() { callLog.append("stop") }
    func recreate() { callLog.append("recreate") }
    func inputNodeInputFormat() -> AVAudioFormat? { stubbedInputFormat }
}

// MARK: - AudioPipelineSwitchTests

@MainActor
final class AudioPipelineSwitchTests: XCTestCase {

    private func makePipeline() -> (AudioPipeline, SwitchTestEngineProvider) {
        let provider = SwitchTestEngineProvider()
        let pipeline = AudioPipeline(provider: provider)
        return (pipeline, provider)
    }

    private func deliverBuffer(via provider: SwitchTestEngineProvider, sampleTime: Int64 = 0) {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160) else {
            XCTFail("Failed to create synthetic buffer")
            return
        }
        buffer.frameLength = 160
        let time = AVAudioTime(sampleTime: sampleTime, atRate: 16000)
        provider.lastInstalledBlock?(buffer, time)
    }

    // MARK: - Test C: pump continues delivering buffers across a device switch

    func testAudioPipeline_PumpSurvivesEngineRestart() async throws {
        let (pipeline, provider) = makePipeline()
        try pipeline.start()

        let stream = pipeline.mediumStream
        var collected: [CapturedAudioBuffer] = []
        var finished = false
        let consumerTask = Task { @MainActor in
            for await buf in stream {
                collected.append(buf)
            }
            finished = true
        }

        deliverBuffer(via: provider, sampleTime: 1)
        deliverBuffer(via: provider, sampleTime: 2)
        deliverBuffer(via: provider, sampleTime: 3)
        try await Task.sleep(for: .milliseconds(10))

        XCTAssertEqual(collected.count, 3,
                       "Three buffers must arrive before the switch")
        XCTAssertFalse(finished,
                       "mediumStream must not finish before stop() (AC-SW7)")

        try await pipeline.switchDevice()

        deliverBuffer(via: provider, sampleTime: 4)
        deliverBuffer(via: provider, sampleTime: 5)
        deliverBuffer(via: provider, sampleTime: 6)
        try await Task.sleep(for: .milliseconds(10))

        XCTAssertEqual(collected.count, 6,
                       "Six total buffers must arrive across the switch (AC-SW7)")
        XCTAssertFalse(finished,
                       "mediumStream must not finish on switchDevice() — invariant of Path B (AC-SW7)")

        pipeline.stop()
        try await Task.sleep(for: .milliseconds(10))

        XCTAssertTrue(finished,
                      "mediumStream must finish after stop()")
        consumerTask.cancel()
    }

    // MARK: - Test G: tap is installed with the HW-bound format when the provider reports a valid format

    func testAudioPipeline_TapInstalledWithHWBoundFormat_WhenAvailable() throws {
        let (pipeline, provider) = makePipeline()
        provider.stubbedInputFormat = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)
        try pipeline.start()
        XCTAssertEqual(provider.lastInstalledFormat?.sampleRate, 16000,
                       "Tap must be installed with HW-bound sample rate when provider reports a valid format (FIX 1)")
        XCTAssertEqual(provider.lastInstalledFormat?.channelCount, 1,
                       "Tap must be installed with HW-bound channel count when provider reports a valid format (FIX 1)")
    }

    // MARK: - Test G2: tap falls back to nil format when the provider never returns a valid format

    func testAudioPipeline_TapInstalledWithNilFormat_OnPollTimeout() throws {
        let (pipeline, provider) = makePipeline()
        provider.stubbedInputFormat = nil
        XCTAssertNoThrow(try pipeline.start(),
                         "start() must not throw when poll timeout occurs — fallback to nil format (FIX 1)")
        XCTAssertNil(provider.lastInstalledFormat,
                     "Tap must be installed with nil format when provider returns nil (fallback path, FIX 1)")
        XCTAssertTrue(provider.callLog.contains("start"),
                      "Engine must have started successfully even when format poll yields no result")
    }

    // MARK: - Test D: mediumStream only finishes on stop(), not on switchDevice()

    func testAudioPipeline_MediumStreamFinishesOnlyOnStop() async throws {
        let (pipeline, _) = makePipeline()
        try pipeline.start()

        let stream = pipeline.mediumStream
        var finished = false
        let consumerTask = Task { @MainActor in
            for await _ in stream {}
            finished = true
        }

        try await pipeline.switchDevice()
        XCTAssertFalse(finished,
                       "mediumStream must not finish after first switchDevice() (AC-SW7)")

        try await pipeline.switchDevice()
        XCTAssertFalse(finished,
                       "mediumStream must not finish after second switchDevice() (AC-SW7)")

        try await pipeline.switchDevice()
        XCTAssertFalse(finished,
                       "mediumStream must not finish after third switchDevice() (AC-SW7)")

        pipeline.stop()
        try await Task.sleep(for: .milliseconds(10))

        XCTAssertTrue(finished,
                      "mediumStream must finish only after stop()")
        consumerTask.cancel()
    }
}
