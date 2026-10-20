import AVFoundation
import KolibriCore
import AudioToolbox
import CoreVideo
import Metal
import QuartzCore

/// 录屏: guest frames go GPU → pixel buffer → hardware encoder with no CPU
/// copy (the renderer blits the shared-memory texture into an IOSurface-backed
/// CVPixelBuffer). Game audio comes from the engine's own audio stream
/// (`EngineAudioStream`) and is encoded to AAC alongside.
final class ScreenRecorder: @unchecked Sendable {
    enum Codec: String, CaseIterable, Identifiable {
        case hevc, h264
        var id: String { rawValue }
        var title: String { self == .hevc ? "HEVC (H.265)" : "H.264" }
    }

    let url: URL
    let width: Int
    let height: Int
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var audio: AVAssetWriterInput?
    private var audioFormat: CMAudioFormatDescription?
    private let textureCache: CVMetalTextureCache
    private let lock = NSLock()
    private var started = false
    private var startHost: CFTimeInterval = 0
    private var lastVideoPTS = CMTime.negativeInfinity
    private(set) var frames = 0
    private(set) var audioPackets = 0

    init(url: URL, width: Int, height: Int, codec: Codec, fps: Int, device: MTLDevice,
         audio pcm: AudioStreamBasicDescription?) throws {
        self.url = url
        self.width = width
        self.height = height
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let pixels = Double(width * height)
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                // ~0.1 bit/pixel/frame for HEVC is visually lossless for games.
                AVVideoAverageBitRateKey: Int(pixels * Double(fps) * (codec == .hevc ? 0.1 : 0.16)),
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
            ],
        ])
        video.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ])
        writer.add(video)
        if var asbd = pcm {
            CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                           magicCookie: nil, extensions: nil, formatDescriptionOut: &audioFormat)
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: asbd.mSampleRate,
                AVNumberOfChannelsKey: min(Int(asbd.mChannelsPerFrame), 2),
                AVEncoderBitRateKey: 192_000,
            ])
            a.expectsMediaDataInRealTime = true
            if writer.canAdd(a) { writer.add(a); audio = a }
        }
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        guard let cache else { throw KolibriCtl.Failure(message: L("无法创建 Metal 纹理缓存")) }
        textureCache = cache
        guard writer.startWriting() else { throw writer.error ?? KolibriCtl.Failure(message: L("无法开始写入视频")) }
    }

    var elapsed: Double {
        lock.lock(); defer { lock.unlock() }
        return started ? CACurrentMediaTime() - startHost : 0
    }

    private func pts(_ host: CFTimeInterval) -> CMTime {
        CMTime(seconds: host - startHost, preferredTimescale: 600_000)
    }

    /// A pixel buffer plus a Metal view of it for the renderer to draw into.
    func nextTarget() -> (CVPixelBuffer, CVMetalTexture, MTLTexture)? {
        guard video.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else { return nil }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        guard let pb else { return nil }
        var cvTex: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, pb, nil, .bgra8Unorm, width, height, 0, &cvTex)
        guard let cvTex, let tex = CVMetalTextureGetTexture(cvTex) else { return nil }
        return (pb, cvTex, tex)
    }

    /// Called from the GPU completion handler once the frame is in `pb`.
    func append(_ pb: CVPixelBuffer, host: CFTimeInterval) {
        lock.lock(); defer { lock.unlock() }
        if !started {
            started = true
            startHost = host
            writer.startSession(atSourceTime: .zero)
        }
        let t = pts(host)
        guard t > lastVideoPTS, video.isReadyForMoreMediaData else { return }
        if adaptor.append(pb, withPresentationTime: t) {
            lastVideoPTS = t
            frames += 1
        }
    }

    /// Interleaved PCM in the format given at init; `hostTime` is the mach time of the first frame.
    func appendAudio(_ pcm: UnsafeRawBufferPointer, frames: Int, hostTime: UInt64) {
        lock.lock(); defer { lock.unlock() }
        audioPackets += 1
        guard started, let audio, let fmt = audioFormat, audio.isReadyForMoreMediaData, frames > 0, let base = pcm.baseAddress else { return }
        let t = pts(Double(AudioConvertHostTimeToNanos(hostTime)) / 1e9)
        guard t >= .zero else { return }
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: pcm.count, blockAllocator: nil,
                                           customBlockSource: nil, offsetToData: 0, dataLength: pcm.count, flags: 0, blockBufferOut: &block)
        guard let block else { return }
        CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: pcm.count)
        var sb: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: fmt,
                                                            sampleCount: frames, presentationTimeStamp: t,
                                                            packetDescriptions: nil, sampleBufferOut: &sb)
        if let sb { audio.append(sb) }
    }

    func finish() async -> URL? {
        let hadFrames = lock.withLock {
            video.markAsFinished()
            audio?.markAsFinished()
            return started
        }
        guard hadFrames else {
            writer.cancelWriting()
            return nil
        }
        await writer.finishWriting()
        return writer.status == .completed ? url : nil
    }
}
