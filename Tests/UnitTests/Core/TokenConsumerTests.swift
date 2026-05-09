import XCTest
@testable import TalkCoach

// MARK: - FakeTokenConsumer

final class FakeTokenConsumer: TokenConsumer, @unchecked Sendable {
    nonisolated(unsafe) var receivedTokens: [TranscribedToken] = []
    nonisolated(unsafe) var sessionEndedCallCount = 0
    nonisolated(unsafe) var onReceiveToken: (() -> Void)?
    nonisolated(unsafe) var onSessionEnded: (() -> Void)?

    func consume(_ token: TranscribedToken) async {
        receivedTokens.append(token)
        onReceiveToken?()
    }

    func sessionEnded() async {
        sessionEndedCallCount += 1
        onSessionEnded?()
    }
}

// MARK: - TokenConsumerTests

@MainActor
final class TokenConsumerTests: XCTestCase {

    // AC-TC1: Protocol shape — FakeTokenConsumer: TokenConsumer compiles
    func testTokenConsumerProtocolHasConsumeAndSessionEnded() {
        let consumer: any TokenConsumer = FakeTokenConsumer()
        XCTAssertNotNil(consumer)
    }

    // AC-TC2: Serial fan-out — two consumers both receive same token in registration order
    func testSerialFanOutDeliversToAllConsumers() async {
        let c1 = FakeTokenConsumer()
        let c2 = FakeTokenConsumer()
        let token = TranscribedToken(token: "hello", startTime: 0.0, endTime: 0.5, isFinal: true)

        let consumers: [any TokenConsumer] = [c1, c2]
        for c in consumers { await c.consume(token) }

        XCTAssertEqual(c1.receivedTokens.count, 1)
        XCTAssertEqual(c2.receivedTokens.count, 1)
        XCTAssertEqual(c1.receivedTokens.first?.token, "hello")
        XCTAssertEqual(c2.receivedTokens.first?.token, "hello")
    }

    // AC-TC3: Zero consumers — no crash
    func testZeroConsumersIsNoOp() async {
        let token = TranscribedToken(token: "test", startTime: 0.0, endTime: 1.0, isFinal: false)
        let consumers: [any TokenConsumer] = []
        for c in consumers { await c.consume(token) }
    }

    // AC-TC4: sessionEnded reaches all registered consumers
    func testSessionEndedReachesAllConsumers() async {
        let c1 = FakeTokenConsumer()
        let c2 = FakeTokenConsumer()

        let consumers: [any TokenConsumer] = [c1, c2]
        for c in consumers { await c.sessionEnded() }

        XCTAssertEqual(c1.sessionEndedCallCount, 1)
        XCTAssertEqual(c2.sessionEndedCallCount, 1)
    }
}
