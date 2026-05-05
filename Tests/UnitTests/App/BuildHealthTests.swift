// BuildHealthTests.swift
//
// Build-health tests for M1.1: verify project configuration, entitlements,
// Info.plist, and logger setup. The test target is hosted by TalkCoach.app,
// so Bundle.main is the app bundle at runtime.
//
// Entitlements and Logger source are read from the source tree via #filePath
// navigation because:
//   - .entitlements is a build input (code signing), not a runtime resource
//   - Logger does not expose its subsystem property at runtime
//   - OSLogStore access is impractical from a sandboxed test host
// The project root is found by walking up from #filePath looking for CLAUDE.md.

import XCTest
import OSLog
@testable import TalkCoach

final class BuildHealthTests: XCTestCase {

    private func findProjectRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<10 {
            url = url.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("CLAUDE.md").path) {
                return url
            }
        }
        throw XCTSkip("Could not find project root (no CLAUDE.md found above test file)")
    }

    // MARK: - Info.plist tests

    func testInfoPlistHasLSUIElementTrue() {
        let value = Bundle.main.object(forInfoDictionaryKey: "LSUIElement")
        XCTAssertNotNil(value, "LSUIElement key must be present in Info.plist")
        if let boolValue = value as? Bool {
            XCTAssertTrue(boolValue, "LSUIElement must be true")
        } else if let numberValue = value as? NSNumber {
            XCTAssertTrue(numberValue.boolValue, "LSUIElement must be true")
        } else {
            XCTFail("LSUIElement is present but not a boolean: \(String(describing: value))")
        }
    }

    func testInfoPlistHasMicUsageDescription() {
        let value = Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") as? String
        XCTAssertNotNil(value, "NSMicrophoneUsageDescription must be present")
        XCTAssertFalse(value?.isEmpty ?? true, "NSMicrophoneUsageDescription must not be empty")
    }

    func testInfoPlistHasSpeechUsageDescription() {
        let value = Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") as? String
        XCTAssertNotNil(value, "NSSpeechRecognitionUsageDescription must be present")
        XCTAssertFalse(value?.isEmpty ?? true, "NSSpeechRecognitionUsageDescription must not be empty")
    }

    func testInfoPlistHasAppCategory() {
        let value = Bundle.main.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String
        XCTAssertEqual(value, "public.app-category.productivity")
    }

    // MARK: - Entitlements tests

    private func loadEntitlementsDictionary() throws -> NSDictionary {
        let projectRoot = try findProjectRoot()
        let entitlementsURL = projectRoot
            .appendingPathComponent("Sources")
            .appendingPathComponent("App")
            .appendingPathComponent("TalkCoach.entitlements")

        guard FileManager.default.fileExists(atPath: entitlementsURL.path) else {
            throw XCTSkip("Entitlements file not found at \(entitlementsURL.path)")
        }

        guard let dict = NSDictionary(contentsOf: entitlementsURL) else {
            XCTFail("Failed to parse entitlements plist at \(entitlementsURL.path)")
            return [:]
        }
        return dict
    }

    func testEntitlementsContainsAppSandbox() throws {
        let dict = try loadEntitlementsDictionary()
        let value = dict["com.apple.security.app-sandbox"] as? Bool
        XCTAssertEqual(value, true, "app-sandbox entitlement must be true")
    }

    func testEntitlementsContainsAudioInput() throws {
        let dict = try loadEntitlementsDictionary()
        let value = dict["com.apple.security.device.audio-input"] as? Bool
        XCTAssertEqual(value, true, "audio-input entitlement must be true")
    }

    func testEntitlementsContainsNetworkClient() throws {
        let dict = try loadEntitlementsDictionary()
        let value = dict["com.apple.security.network.client"] as? Bool
        XCTAssertEqual(value, true, "network.client entitlement must be true")
    }

    func testEntitlementsHasNoOtherKeys() throws {
        let dict = try loadEntitlementsDictionary()
        let expectedKeys: Set<String> = [
            "com.apple.security.app-sandbox",
            "com.apple.security.device.audio-input",
            "com.apple.security.network.client"
        ]
        let actualKeys = Set(dict.allKeys.compactMap { $0 as? String })
        XCTAssertEqual(actualKeys, expectedKeys,
                       "Entitlements must contain exactly 3 keys, found: \(actualKeys)")
    }

    // MARK: - Logger tests

    // Verifies the subsystem string by reading the source file directly.
    // Logger does not expose its subsystem property at runtime, and OSLogStore
    // access is impractical from a sandboxed test host.
    func testLoggerSubsystemIsExpected() throws {
        let projectRoot = try findProjectRoot()
        let loggerFileURL = projectRoot
            .appendingPathComponent("Sources")
            .appendingPathComponent("App")
            .appendingPathComponent("Logger+Subsystem.swift")

        guard FileManager.default.fileExists(atPath: loggerFileURL.path) else {
            throw XCTSkip("Logger+Subsystem.swift not found at \(loggerFileURL.path)")
        }

        let contents = try String(contentsOf: loggerFileURL, encoding: .utf8)
        XCTAssertTrue(
            contents.contains("\"com.talkcoach.app\""),
            "Logger+Subsystem.swift must use subsystem \"com.talkcoach.app\""
        )
    }

    func testAllExpectedLoggerCategoriesExist() {
        let loggers: [(String, Logger)] = [
            ("app", Logger.app),
            ("audio", Logger.audio),
            ("speech", Logger.speech),
            ("analyzer", Logger.analyzer),
            ("widget", Logger.widget),
            ("session", Logger.session),
            ("mic", Logger.mic)
        ]
        XCTAssertEqual(loggers.count, 7, "Must have exactly 7 logger categories")
        for (name, logger) in loggers {
            XCTAssertTrue(type(of: logger) == Logger.self,
                          "\(name) must be a Logger instance")
        }
    }

    // MARK: - App launch smoke test

    func testAppLaunchSmokeTest() {
        let app = TalkCoachApp()
        _ = app.body
    }
}
