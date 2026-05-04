import AVFoundation
import Foundation

/// Extracts a dBFS time series from an audio file using RMS per hop.
public enum RMSExtractor {

    /// Amplitude floor: values below this are clamped to prevent log10(0).
    /// Produces a silence floor of 20 * log10(1e-7) = -140 dBFS.
    private static let amplitudeFloor: Double = 1e-7

    public static func extract(
        from filePath: String,
        hopSeconds: Double = 0.1
    ) throws -> (dBFSSeries: [Double], sampleRate: Double, durationSeconds: Double) {
        let url = URL(fileURLWithPath: filePath)
        let file = try AVAudioFile(forReading: url)

        let format = file.processingFormat
        let sampleRate = format.sampleRate
        let totalFrames = Int(file.length)
        let durationSeconds = Double(totalFrames) / sampleRate

        guard totalFrames > 0 else {
            return (dBFSSeries: [], sampleRate: sampleRate, durationSeconds: 0.0)
        }

        let framesPerHop = Int(hopSeconds * sampleRate)
        guard framesPerHop > 0 else {
            return (dBFSSeries: [], sampleRate: sampleRate, durationSeconds: durationSeconds)
        }

        let hopCount = totalFrames / framesPerHop
        guard hopCount > 0 else {
            return (dBFSSeries: [], sampleRate: sampleRate, durationSeconds: durationSeconds)
        }

        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(totalFrames)
        )!
        try file.read(into: buffer)

        let channelCount = Int(format.channelCount)
        var dBFSSeries: [Double] = []
        dBFSSeries.reserveCapacity(hopCount)

        for hop in 0..<hopCount {
            let startFrame = hop * framesPerHop
            var sumSquares: Double = 0.0

            for frame in startFrame..<(startFrame + framesPerHop) {
                var monoSample: Double = 0.0
                for ch in 0..<channelCount {
                    monoSample += Double(buffer.floatChannelData![ch][frame])
                }
                monoSample /= Double(channelCount)
                sumSquares += monoSample * monoSample
            }

            let rms = max(sqrt(sumSquares / Double(framesPerHop)), amplitudeFloor)
            dBFSSeries.append(20.0 * log10(rms))
        }

        return (dBFSSeries: dBFSSeries, sampleRate: sampleRate, durationSeconds: durationSeconds)
    }
}
