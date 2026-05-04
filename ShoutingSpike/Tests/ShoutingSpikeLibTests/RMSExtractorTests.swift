import Testing
import AVFoundation
@testable import ShoutingSpikeLib

struct RMSExtractorTests {

    private func tempURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("shouting_spike_\(name).caf")
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func writeSine(
        url: URL,
        frequency: Double = 1000.0,
        amplitude: Float = 1.0,
        duration: Double = 1.0,
        sampleRate: Double = 48000.0
    ) throws {
        let frameCount = Int(duration * sampleRate)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))!
        buffer.frameLength = AVAudioFrameCount(frameCount)
        let data = buffer.floatChannelData![0]
        for i in 0..<frameCount {
            data[i] = amplitude * sin(Float(2.0 * .pi * frequency * Double(i) / sampleRate))
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    private func writeSilence(url: URL, duration: Double = 1.0, sampleRate: Double = 48000.0) throws {
        let frameCount = Int(duration * sampleRate)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))!
        buffer.frameLength = AVAudioFrameCount(frameCount)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    private func writeEmpty(url: URL, sampleRate: Double = 48000.0) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        _ = file
    }

    @Test func fullScaleSine_yieldsMinus3DBFS() throws {
        let url = tempURL("sine_48k")
        defer { cleanup(url) }
        try writeSine(url: url)
        let result = try RMSExtractor.extract(from: url.path, hopSeconds: 0.1)
        #expect(!result.dBFSSeries.isEmpty)
        #expect(abs(result.dBFSSeries[0] - (-3.01)) < 0.2)
    }

    @Test func silentBuffer_yieldsFloorDBFS() throws {
        let url = tempURL("silence")
        defer { cleanup(url) }
        try writeSilence(url: url)
        let result = try RMSExtractor.extract(from: url.path, hopSeconds: 0.1)
        #expect(!result.dBFSSeries.isEmpty)
        #expect(result.dBFSSeries[0] <= -120.0)
    }

    @Test func hopCount_matchesDuration() throws {
        let url = tempURL("2s")
        defer { cleanup(url) }
        try writeSine(url: url, duration: 2.0)
        let result = try RMSExtractor.extract(from: url.path, hopSeconds: 0.1)
        #expect(result.dBFSSeries.count == 20)
    }

    @Test func nonStandardSampleRate_correctDBFS() throws {
        let url = tempURL("sine_44k")
        defer { cleanup(url) }
        try writeSine(url: url, sampleRate: 44100.0)
        let result = try RMSExtractor.extract(from: url.path, hopSeconds: 0.1)
        #expect(result.dBFSSeries.count == 10)
        #expect(abs(result.dBFSSeries[0] - (-3.01)) < 0.5)
    }

    @Test func emptyFile_gracefulHandling() throws {
        let url = tempURL("empty")
        defer { cleanup(url) }
        try writeEmpty(url: url)
        let result = try RMSExtractor.extract(from: url.path, hopSeconds: 0.1)
        #expect(result.dBFSSeries.isEmpty)
        #expect(result.durationSeconds < 0.001)
    }
}
