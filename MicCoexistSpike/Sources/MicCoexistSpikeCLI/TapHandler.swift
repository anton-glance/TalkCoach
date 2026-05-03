import AVFoundation

func makeTapHandler(state: MicState) -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
    { buffer, _ in
        state.recordBuffer(
            frameCount: Int(buffer.frameLength),
            sampleRate: buffer.format.sampleRate,
            channels: buffer.format.channelCount
        )
    }
}
