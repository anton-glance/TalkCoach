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

    func isInstalled(transcriber: SpeechTranscriber) async throws -> Bool {
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

    // MARK: InstalledLocalesProvider seam

    func testIsInstalledTrustsInstalledLocalesSet() async throws {
        // Convention-6 seam: FakeSpeechTranscriberInstalledLocalesProvider controls the
        // installed set without real OS state, making the test machine-independent.
        // Locale is extracted from SpeechTranscriber via Mirror since .locale is not
        // a public property on SpeechTranscriber (verified Session 026 diagnostic).
        let fakeProvider = FakeSpeechTranscriberInstalledLocalesProvider()
        fakeProvider.locales = [Locale(identifier: "en_US")]
        let sut = SystemAssetInventoryStatusProvider(installedLocalesProvider: fakeProvider)

        let enUS = SpeechTranscriber(
            locale: Locale(identifier: "en_US"),
            transcriptionOptions: [],
            reportingOptions: AppleTranscriberBackend.reportingOptions,
            attributeOptions: AppleTranscriberBackend.attributeOptions
        )
        let deDE = SpeechTranscriber(
            locale: Locale(identifier: "de_DE"),
            transcriptionOptions: [],
            reportingOptions: AppleTranscriberBackend.reportingOptions,
            attributeOptions: AppleTranscriberBackend.attributeOptions
        )

        let enUSInstalled = try await sut.isInstalled(transcriber: enUS)
        let deDEInstalled = try await sut.isInstalled(transcriber: deDE)

        XCTAssertTrue(enUSInstalled, "en_US in fakeInstalledLocales → should be installed")
        XCTAssertFalse(deDEInstalled, "de_DE not in fakeInstalledLocales → should not be installed")
    }
}
