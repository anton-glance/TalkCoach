import AVFAudio
import Foundation
import WPMCalculatorLib
import os

private let logger = Logger(subsystem: "com.speechcoach.app", category: "spike")

enum SimpleEnergyVAD {

    private static let frameDuration: TimeInterval = 0.05 // 50ms

    /// Analyze an audio file and produce VAD transition events.
    ///
    /// Returns transition events only (state changes). An empty result means
    /// the entire file is above or below threshold consistently.
    static func analyze(
        audioFileURL: URL,
        thresholdDBFS: Float = -40.0
    ) throws -> [VADEvent] {
        let audioFile = try AVAudioFile(forReading: audioFileURL)
        let format = audioFile.processingFormat
        let sampleRate = format.sampleRate
        let framesPerChunk = AVAudioFrameCount(sampleRate * frameDuration)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesPerChunk) else {
            logger.error("Failed to create audio buffer")
            return []
        }

        let linearThreshold = powf(10.0, thresholdDBFS / 20.0)

        var events: [VADEvent] = []
        var previouslySpeaking: Bool?
        var currentFrame: AVAudioFramePosition = 0

        while currentFrame < audioFile.length {
            audioFile.framePosition = currentFrame
            let framesToRead = min(framesPerChunk, AVAudioFrameCount(audioFile.length - currentFrame))

            try audioFile.read(into: buffer, frameCount: framesToRead)

            let rms = computeRMS(buffer: buffer, frameCount: framesToRead)
            let isSpeaking = rms > linearThreshold
            let timestamp = Double(currentFrame) / sampleRate

            if isSpeaking != previouslySpeaking {
                events.append(VADEvent(timestamp: timestamp, isSpeaking: isSpeaking))
                previouslySpeaking = isSpeaking
            }

            currentFrame += AVAudioFramePosition(framesToRead)
        }

        return events
    }

    private static func computeRMS(buffer: AVAudioPCMBuffer, frameCount: AVAudioFrameCount) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }

        let channelCount = Int(buffer.format.channelCount)
        let frames = Int(frameCount)
        var sumSquares: Float = 0

        for channel in 0..<channelCount {
            let samples = channelData[channel]
            for frame in 0..<frames {
                let sample = samples[frame]
                sumSquares += sample * sample
            }
        }

        let totalSamples = Float(frames * channelCount)
        guard totalSamples > 0 else { return 0 }

        return sqrtf(sumSquares / totalSamples)
    }
}
