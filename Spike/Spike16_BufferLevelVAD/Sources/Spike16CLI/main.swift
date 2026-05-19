import Foundation
import AVFoundation
import Spike16

// MARK: - Stderr helper

func stderrPrint(_ msg: String) {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
}

// MARK: - Argument parsing

struct Args {
    let filePath: String
    let voiceOnCount: Int
    let voiceOffCount: Int
    let thresholdMargin: Float
}

func parseArgs() -> Args? {
    var args = CommandLine.arguments.dropFirst()
    guard let filePath = args.first else {
        stderrPrint("Usage: Spike16CLI <path.caf> [--voice-on-count N] [--voice-off-count N] [--threshold-margin F]")
        return nil
    }
    args = args.dropFirst()

    var voiceOnCount = 3
    var voiceOffCount = 30
    var thresholdMargin: Float = 15.0

    var iter = args.makeIterator()
    while let flag = iter.next() {
        switch flag {
        case "--voice-on-count":
            guard let val = iter.next(), let n = Int(val) else {
                stderrPrint("ERROR: --voice-on-count requires an integer argument"); return nil
            }
            voiceOnCount = n
        case "--voice-off-count":
            guard let val = iter.next(), let n = Int(val) else {
                stderrPrint("ERROR: --voice-off-count requires an integer argument"); return nil
            }
            voiceOffCount = n
        case "--threshold-margin":
            guard let val = iter.next(), let f = Float(val) else {
                stderrPrint("ERROR: --threshold-margin requires a float argument"); return nil
            }
            thresholdMargin = f
        default:
            stderrPrint("WARNING: unknown flag '\(flag)' ignored")
        }
    }
    return Args(filePath: filePath, voiceOnCount: voiceOnCount,
                voiceOffCount: voiceOffCount, thresholdMargin: thresholdMargin)
}

// MARK: - Main

guard let args = parseArgs() else { exit(1) }

let fileURL = URL(fileURLWithPath: args.filePath)
let audioFile: AVAudioFile
do {
    audioFile = try AVAudioFile(forReading: fileURL)
} catch {
    stderrPrint("ERROR: cannot open '\(args.filePath)': \(error)")
    exit(1)
}

let fmt = audioFile.processingFormat
let sampleRate = fmt.sampleRate
let channelCount = fmt.channelCount
let totalFrames = audioFile.length

guard sampleRate == 16000.0 && channelCount == 1 else {
    stderrPrint("ERROR: expected mono 16000 Hz, got sampleRate=\(sampleRate) channels=\(channelCount) in file: \(args.filePath)")
    exit(1)
}

let durationMS = Int((Double(totalFrames) / sampleRate) * 1000.0)
stderrPrint("INFO: sampleRate=\(sampleRate) channels=\(channelCount) totalFrames=\(totalFrames) duration_ms=\(durationMS)")

let vad = RMSVoiceActivityDetector(
    thresholdMarginDB: args.thresholdMargin,
    voiceOnHysteresisCount: args.voiceOnCount,
    voiceOffHysteresisCount: args.voiceOffCount
)

let bufferFrameCount: AVAudioFrameCount = 160
guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: bufferFrameCount) else {
    stderrPrint("ERROR: cannot allocate AVAudioPCMBuffer")
    exit(1)
}

print("timestamp_ms,rms_db,noise_floor_db,threshold_db,is_voice_active,calibration_state")

var samplesProcessed: Int64 = 0

while audioFile.framePosition < totalFrames {
    let remaining = totalFrames - audioFile.framePosition
    let toRead = AVAudioFrameCount(min(Int64(bufferFrameCount), remaining))
    do {
        try audioFile.read(into: pcmBuffer, frameCount: toRead)
    } catch {
        stderrPrint("ERROR: read failed at position \(audioFile.framePosition): \(error)")
        break
    }

    guard pcmBuffer.frameLength > 0,
          let floatData = pcmBuffer.floatChannelData else { break }

    let count = Int(pcmBuffer.frameLength)
    let samples = Array(UnsafeBufferPointer(start: floatData[0], count: count))

    vad.process(samples: samples, sampleRate: sampleRate)
    samplesProcessed += Int64(count)

    let timestampMS = Int((Double(samplesProcessed) / sampleRate) * 1000.0 + 0.5)
    let activeStr = vad.isVoiceActive ? "true" : "false"
    print("\(timestampMS),\(String(format: "%.1f", vad.lastRMSDB)),\(String(format: "%.1f", vad.noiseFloorDB)),\(String(format: "%.1f", vad.thresholdDB)),\(activeStr),\(vad.calibrationState.rawValue)")
}
