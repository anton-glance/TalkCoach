import AVFAudio
import Foundation

enum NoiseFloorMeasurer {

    static func measureRMS(audioFileURL: URL) throws -> Float {
        let audioFile = try AVAudioFile(forReading: audioFileURL)
        let format = audioFile.processingFormat
        let sampleRate = format.sampleRate
        let chunkSize = AVAudioFrameCount(sampleRate * 0.05)

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: chunkSize
        ) else {
            return 0
        }

        var totalSumSquares: Double = 0
        var totalSamples: Int = 0
        var currentFrame: AVAudioFramePosition = 0

        while currentFrame < audioFile.length {
            audioFile.framePosition = currentFrame
            let framesToRead = min(
                chunkSize,
                AVAudioFrameCount(audioFile.length - currentFrame)
            )

            try audioFile.read(into: buffer, frameCount: framesToRead)

            guard let channelData = buffer.floatChannelData else { break }

            let channelCount = Int(buffer.format.channelCount)
            let frames = Int(framesToRead)

            for channel in 0..<channelCount {
                let samples = channelData[channel]
                for frame in 0..<frames {
                    let sample = Double(samples[frame])
                    totalSumSquares += sample * sample
                }
            }
            totalSamples += frames * channelCount
            currentFrame += AVAudioFramePosition(framesToRead)
        }

        guard totalSamples > 0 else { return 0 }
        return Float(sqrt(totalSumSquares / Double(totalSamples)))
    }
}
