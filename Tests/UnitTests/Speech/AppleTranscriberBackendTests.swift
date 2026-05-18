import XCTest
import Speech
@testable import TalkCoach

// MARK: - Fakes

final class FakeSpeechTranscriberInstalledLocalesProvider: InstalledLocalesProvider, @unchecked Sendable {
    var locales: [Locale] = []
    func installedLocales() async -> [Locale] { locales }
}

final class FakeAssetInventoryStatusProvider: AssetInventoryStatusProvider, @unchecked Sendable {
    nonisolated(unsafe) var installedResult: Bool = true
    nonisolated(unsafe) var callCount = 0

    func isInstalled(locale: Locale) async throws -> Bool {
        callCount += 1
        return installedResult
    }
}

// MARK: - AppleTranscriberBackendTests

@MainActor
final class AppleTranscriberBackendTests: XCTestCase {

    private func makeBackend(
        appleLocales: [String] = ["en-US"],
        installed: Bool = true
    ) -> (AppleTranscriberBackend, FakeAssetInventoryStatusProvider) {
        let localesProvider = FakeSupportedLocalesProvider()
        localesProvider.locales = appleLocales.map { Locale(identifier: $0) }
        let assetProvider = FakeAssetInventoryStatusProvider()
        assetProvider.installedResult = installed
        let backend = AppleTranscriberBackend(
            audioBufferProvider: FakeAudioBufferProvider(),
            localesProvider: localesProvider,
            assetStatusProvider: assetProvider
        )
        return (backend, assetProvider)
    }

    // MARK: AC5 — reportingOptions contains .volatileResults

    func testReportingOptionsContainsVolatileResults() {
        XCTAssertTrue(
            AppleTranscriberBackend.reportingOptions.contains(.volatileResults),
            "Must request volatile results for low-latency token streaming"
        )
    }

    // MARK: AC7 — attributeOptions contains .audioTimeRange

    func testAttributeOptionsContainsAudioTimeRange() {
        XCTAssertTrue(
            AppleTranscriberBackend.attributeOptions.contains(.audioTimeRange),
            "Must request audioTimeRange attribute for per-token timestamps"
        )
    }

    // MARK: AC6 — start() throws .modelUnavailable when model not installed

    func testStartThrowsModelUnavailableWhenNotInstalled() async throws {
        let (backend, _) = makeBackend(installed: false)

        do {
            try await backend.start(locale: Locale(identifier: "en-US"))
            XCTFail("Expected TranscriberBackendError.modelUnavailable")
        } catch TranscriberBackendError.modelUnavailable {
            // expected
        }
    }

    // AC6 detail — isInstalled is called exactly once per start()
    func testIsInstalledCalledOncePerStart() async throws {
        let (backend, assetProvider) = makeBackend(installed: false)
        _ = try? await backend.start(locale: Locale(identifier: "en-US"))
        XCTAssertEqual(assetProvider.callCount, 1)
    }

    // AC6b — start() throws .unsupportedLocale for a locale not in Apple's list
    func testStartThrowsUnsupportedLocaleWhenNotInAppleList() async throws {
        let (backend, _) = makeBackend(appleLocales: ["en-US"])

        do {
            try await backend.start(locale: Locale(identifier: "ru-RU"))
            XCTFail("Expected TranscriberBackendError.unsupportedLocale")
        } catch TranscriberBackendError.unsupportedLocale {
            // expected
        }
    }

    // MARK: AC8 — stop() without prior start() finishes tokenStream

    func testStopBeforeStartFinishesTokenStream() async {
        let (backend, _) = makeBackend()
        await backend.stop()

        let expectation = XCTestExpectation(description: "tokenStream finishes after stop")
        Task {
            for await _ in backend.tokenStream {}
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 2.0)
    }

    // AC8 detail — calling stop() twice is safe (no crash, no hang)
    func testStopTwiceIsSafe() async {
        let (backend, _) = makeBackend()
        await backend.stop()
        await backend.stop()
    }

    // MARK: - Bug A: engine-ready fires after first buffer, not at analyzer.start

    // Creates a minimal CapturedAudioBuffer for injection into FakeAudioBufferProvider.
    private func makeSyntheticCapturedBuffer() -> CapturedAudioBuffer {
        let frameCount: AVAudioFrameCount = 480
        return CapturedAudioBuffer(
            frameLength: frameCount,
            sampleRate: 48_000,
            channelCount: 1,
            sampleTime: 0,
            hostTime: 0,
            samples: [Array(repeating: 0.0, count: Int(frameCount))]
        )
    }

    func testEngineReady_FiresAfterFirstBufferDeliveredToAnalyzerInput() async throws {
        // Plan v4 §1: engine-ready = first audio buffer flowing into SpeechAnalyzer.
        // testOnly_skipAnalyzerStart bypasses the real SpeechAnalyzer (requires Speech
        // framework) so we can verify the signal fires at the buffer-yield callsite.
        // afterInputYieldHook fires synchronously BEFORE engineReadyContinuation.yield(),
        // confirming the code-level ordering guarantee.
        let localesProvider = FakeSupportedLocalesProvider()
        localesProvider.locales = [Locale(identifier: "en-US")]
        let assetProvider = FakeAssetInventoryStatusProvider()
        assetProvider.installedResult = true

        let bufferProvider = FakeAudioBufferProvider()
        bufferProvider.scriptedBuffers = [makeSyntheticCapturedBuffer()]

        let backend = AppleTranscriberBackend(
            audioBufferProvider: bufferProvider,
            localesProvider: localesProvider,
            assetStatusProvider: assetProvider
        )
        backend.testOnlySkipAnalyzerStart = true

        // afterInputYieldHook fires BEFORE engineReadyContinuation.yield().
        // When we observe engine-ready, hookFiredBeforeEngineReady must already be true.
        nonisolated(unsafe) var hookFiredBeforeEngineReady = false
        backend.afterInputYieldHook = { hookFiredBeforeEngineReady = true }

        try await backend.start(locale: Locale(identifier: "en-US"))

        let exp = XCTestExpectation(description: "engineReadyStream fires after first buffer")
        nonisolated(unsafe) var hookStateAtObservation = false
        let engineReadyTask = Task {
            for await _ in backend.engineReadyStream {
                hookStateAtObservation = hookFiredBeforeEngineReady
                exp.fulfill()
                break
            }
        }

        await fulfillment(of: [exp], timeout: 2.0)
        engineReadyTask.cancel()
        await backend.stop()

        XCTAssertTrue(hookStateAtObservation,
                      "afterInputYieldHook must fire before engineReadyContinuation.yield() — " +
                      "confirming engine-ready fires AFTER the first buffer is yielded to the analyzer")
    }

    // MARK: InstalledLocalesProvider seam

    func testIsInstalledTrustsInstalledLocalesSet() async throws {
        // Convention-6 seam: FakeSpeechTranscriberInstalledLocalesProvider controls the
        // installed set without real OS state, making the test machine-independent.
        let fakeProvider = FakeSpeechTranscriberInstalledLocalesProvider()
        fakeProvider.locales = [Locale(identifier: "en_US")]
        let sut = SystemAssetInventoryStatusProvider(installedLocalesProvider: fakeProvider)

        let enUSInstalled = try await sut.isInstalled(locale: Locale(identifier: "en_US"))
        let deDEInstalled = try await sut.isInstalled(locale: Locale(identifier: "de_DE"))

        XCTAssertTrue(enUSInstalled, "en_US in fakeInstalledLocales → should be installed")
        XCTAssertFalse(deDEInstalled, "de_DE not in fakeInstalledLocales → should not be installed")
    }
}
