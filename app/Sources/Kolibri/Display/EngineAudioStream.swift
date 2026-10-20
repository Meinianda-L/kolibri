import AudioToolbox
import Foundation

/// Guest audio for recordings, taken from the engine's gRPC audio stream: the PCM the
/// engine mixes, inside its own process, so no OS capture permission is needed and a
/// muted Mac still records. (Earlier engines had no audio backend in headless mode and
/// this stream stayed empty; with QEMU_AUDIO_DRV=coreaudio it runs in real time.)
///
/// While the guest is silent the engine sends almost nothing, so the stream keeps its
/// own sample clock and fills gaps with silence to stay aligned with the video.
final class EngineAudioStream: @unchecked Sendable {
    static let sampleRate = 48_000.0
    static let channels = 2
    /// Interleaved s16 stereo, as requested from the engine.
    static let format = AudioStreamBasicDescription(
        mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
        mBytesPerPacket: UInt32(2 * channels), mFramesPerPacket: 1, mBytesPerFrame: UInt32(2 * channels),
        mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 16, mReserved: 0)

    private var task: Task<Void, Never>?
    private let bytesPerFrame = 2 * channels

    /// `onAudio(pcm, frames, hostTime)`: hostTime is the mach time of the first frame.
    init(client: EmulatorClient, onAudio: @escaping @Sendable (UnsafeRawBufferPointer, Int, UInt64) -> Void) {
        let bpf = bytesPerFrame
        // Sample clock: frames delivered since `start` (packets arrive one at a time).
        final class Clock: @unchecked Sendable {
            let start = mach_absolute_time()
            var written = 0
            func host(atFrame f: Int) -> UInt64 {
                start + AudioConvertNanosToHostTime(UInt64(Double(f) / EngineAudioStream.sampleRate * 1e9))
            }
            var elapsedFrames: Int {
                Int(Double(AudioConvertHostTimeToNanos(mach_absolute_time() - start)) / 1e9 * EngineAudioStream.sampleRate)
            }
        }
        let clock = Clock()
        task = Task.detached {
            while !Task.isCancelled {
                do {
                    try await client.streamAudio { data, _ in
                        let frames = data.count / bpf
                        guard frames > 0 else { return }
                        // Behind the wall clock by more than 100 ms: the guest was silent.
                        let gap = clock.elapsedFrames - frames - clock.written
                        if gap > Int(Self.sampleRate / 10) {
                            let silence = [UInt8](repeating: 0, count: gap * bpf)
                            silence.withUnsafeBytes { onAudio($0, gap, clock.host(atFrame: clock.written)) }
                            clock.written += gap
                        }
                        data.withUnsafeBytes { onAudio($0, frames, clock.host(atFrame: clock.written)) }
                        clock.written += frames
                    }
                    return
                } catch {
                    // Engine restarting: retry while the recording lasts.
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}
