// TEMPORARY — diagnostic-only, delete after investigating Russian asset issue
import Foundation
import Speech
import os

private let logger = Logger(
    subsystem: "com.speechcoach.app",
    category: "diagnostics"
)

enum Diagnostics {

    static func run() async {
        fputs("=== S6 DIAGNOSTICS ===\n\n", stderr)

        await checkSupportedLocales()
        await checkInstalledLocales()
        await checkReservations()
        await checkRussianStatus()
        await attemptRussianDownload()

        fputs("\n=== END DIAGNOSTICS ===\n", stderr)
    }

    // MARK: - Checks

    private static func checkSupportedLocales() async {
        fputs("1. SpeechTranscriber.supportedLocales:\n", stderr)
        let supported = await SpeechTranscriber.supportedLocales
        for locale in supported {
            fputs("   - \(locale.identifier)\n", stderr)
        }
        let hasRu = supported.contains { $0.identifier.hasPrefix("ru") }
        let hasEn = supported.contains { $0.identifier.hasPrefix("en") }
        fputs("   ru present: \(hasRu), en present: \(hasEn)\n\n", stderr)
    }

    private static func checkInstalledLocales() async {
        fputs("2. SpeechTranscriber.installedLocales:\n", stderr)
        let installed = await SpeechTranscriber.installedLocales
        if installed.isEmpty {
            fputs("   (none)\n", stderr)
        } else {
            for locale in installed {
                fputs("   - \(locale.identifier)\n", stderr)
            }
        }
        let hasRu = installed.contains { $0.identifier.hasPrefix("ru") }
        let hasEn = installed.contains { $0.identifier.hasPrefix("en") }
        fputs("   ru installed: \(hasRu), en installed: \(hasEn)\n\n", stderr)
    }

    private static func checkReservations() async {
        fputs("3. AssetInventory reservations:\n", stderr)
        let max = AssetInventory.maximumReservedLocales
        let reserved = await AssetInventory.reservedLocales
        fputs("   maximumReservedLocales: \(max)\n", stderr)
        fputs("   current reservedLocales (\(reserved.count)):\n", stderr)
        for locale in reserved {
            fputs("   - \(locale.identifier)\n", stderr)
        }
        fputs("\n", stderr)
    }

    private static func checkRussianStatus() async {
        fputs("4. AssetInventory.status for Russian transcriber:\n", stderr)
        let ruLocale = Locale(identifier: "ru")
        guard let supported = await SpeechTranscriber
            .supportedLocale(equivalentTo: ruLocale) else {
            fputs("   supportedLocale(equivalentTo: ru) returned nil\n\n", stderr)
            return
        }
        fputs("   supportedLocale(equivalentTo: ru) = \(supported.identifier)\n", stderr)

        let transcriber = SpeechTranscriber(
            locale: supported,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )
        let status = await AssetInventory.status(forModules: [transcriber])
        fputs("   status: \(status)\n\n", stderr)
    }

    private static func attemptRussianDownload() async {
        fputs("5. Attempting Russian asset download:\n", stderr)
        let ruLocale = Locale(identifier: "ru")
        guard let supported = await SpeechTranscriber
            .supportedLocale(equivalentTo: ruLocale) else {
            fputs("   Cannot proceed — no supported locale for ru\n", stderr)
            return
        }

        let transcriber = SpeechTranscriber(
            locale: supported,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )

        let startTime = Date()
        fputs("   Started at: \(startTime)\n", stderr)

        do {
            if let req = try await AssetInventory
                .assetInstallationRequest(supporting: [transcriber]) {
                fputs("   Got installation request, calling downloadAndInstall()...\n", stderr)
                try await req.downloadAndInstall()
                let elapsed = Date().timeIntervalSince(startTime)
                fputs("   Download succeeded in \(String(format: "%.1f", elapsed))s\n", stderr)
            } else {
                fputs("   assetInstallationRequest returned nil (already installed)\n", stderr)
            }
        } catch {
            let elapsed = Date().timeIntervalSince(startTime)
            fputs("   FAILED after \(String(format: "%.1f", elapsed))s\n", stderr)
            fputs("   error.localizedDescription: \(error.localizedDescription)\n", stderr)
            let nsError = error as NSError
            fputs("   NSError domain: \(nsError.domain)\n", stderr)
            fputs("   NSError code: \(nsError.code)\n", stderr)
            fputs("   NSError userInfo: \(nsError.userInfo)\n", stderr)
            if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
                fputs("   underlyingError domain: \(underlying.domain)\n", stderr)
                fputs("   underlyingError code: \(underlying.code)\n", stderr)
                fputs("   underlyingError userInfo: \(underlying.userInfo)\n", stderr)
            }
        }

        let postStatus = await AssetInventory.status(forModules: [transcriber])
        fputs("   Post-attempt status: \(postStatus)\n", stderr)
    }
}
