import XCTest
@testable import TalkCoach

@MainActor
final class AudioBufferBroadcasterTests: XCTestCase {

    // MARK: - RED: testBroadcasterDeliversToBothConsumers
    //
    // Fails in red phase because AudioBufferBroadcaster.drive(from:) is not yet
    // implemented — consumer streams never receive items, counts stay 0 ≠ 10.

    func testBroadcasterDeliversToBothConsumers() async {
        let broadcaster = AudioBufferBroadcaster()

        let stream1 = await broadcaster.makeStream()
        let stream2 = await broadcaster.makeStream()

        var sourceCont: AsyncStream<CapturedAudioBuffer>.Continuation!
        let source = AsyncStream<CapturedAudioBuffer>(bufferingPolicy: .bufferingNewest(128)) {
            sourceCont = $0
        }

        await broadcaster.drive(from: source)

        let bufferCount = 10
        for idx in 0..<bufferCount {
            sourceCont.yield(makeBuffer(sampleTime: Int64(idx)))
        }
        sourceCont.finish()

        let task1 = Task {
            var count = 0
            for await _ in stream1 { count += 1 }
            return count
        }
        let task2 = Task {
            var count = 0
            for await _ in stream2 { count += 1 }
            return count
        }

        await broadcaster.stop()

        let received1 = await task1.value
        let received2 = await task2.value

        XCTAssertEqual(received1, bufferCount, "stream1 should receive all \(bufferCount) buffers")
        XCTAssertEqual(received2, bufferCount, "stream2 should receive all \(bufferCount) buffers")
    }

    // MARK: - testBroadcasterStopFinishesBothStreams
    //
    // Both RED and GREEN: stop() finishes streams even with no source content.

    func testBroadcasterStopFinishesBothStreams() async {
        let broadcaster = AudioBufferBroadcaster()
        let stream1 = await broadcaster.makeStream()
        let stream2 = await broadcaster.makeStream()

        var sourceCont: AsyncStream<CapturedAudioBuffer>.Continuation!
        let source = AsyncStream<CapturedAudioBuffer>(bufferingPolicy: .bufferingNewest(128)) {
            sourceCont = $0
        }

        await broadcaster.drive(from: source)
        sourceCont.finish()
        await broadcaster.stop()

        var count1 = 0
        for await _ in stream1 { count1 += 1 }
        var count2 = 0
        for await _ in stream2 { count2 += 1 }

        XCTAssertEqual(count1, 0)
        XCTAssertEqual(count2, 0)
    }

    // MARK: - testBroadcasterNoConsumers

    func testBroadcasterNoConsumersDoesNotCrash() async {
        let broadcaster = AudioBufferBroadcaster()

        var sourceCont: AsyncStream<CapturedAudioBuffer>.Continuation!
        let source = AsyncStream<CapturedAudioBuffer>(bufferingPolicy: .bufferingNewest(128)) {
            sourceCont = $0
        }

        await broadcaster.drive(from: source)
        sourceCont.finish()
        await broadcaster.stop()
    }

    // MARK: - testBroadcasterStopWithoutDriveDoesNotCrash

    func testBroadcasterStopWithoutDriveDoesNotCrash() async {
        let broadcaster = AudioBufferBroadcaster()
        _ = await broadcaster.makeStream()
        await broadcaster.stop()
    }

    // MARK: - Helpers

    private func makeBuffer(sampleTime: Int64 = 0) -> CapturedAudioBuffer {
        CapturedAudioBuffer(
            frameLength: 512,
            sampleRate: 16_000,
            channelCount: 1,
            sampleTime: sampleTime,
            hostTime: 0,
            samples: [Array(repeating: 0.0, count: 512)]
        )
    }
}
