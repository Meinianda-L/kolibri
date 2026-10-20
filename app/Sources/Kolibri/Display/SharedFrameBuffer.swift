import Foundation
import CoreGraphics
import Metal

/// A file-backed shared mapping the engine writes frames into (gRPC MMAP
/// transport). The same pages back an MTLBuffer and a linear texture view, so
/// a new guest frame reaches the GPU with zero CPU copies.
final class SharedFrameBuffer {
    let url: URL
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let length: Int
    private let base: UnsafeMutableRawPointer
    let buffer: MTLBuffer
    let texture: MTLTexture

    init(device: MTLDevice, directory: URL, width: Int, height: Int) throws {
        self.width = width
        self.height = height
        let align = max(device.minimumLinearTextureAlignment(for: .rgba8Unorm), 4)
        bytesPerRow = (width * 4 + align - 1) / align * align
        // The engine writes width*4 per row; keep rows tight unless Metal needs padding.
        precondition(bytesPerRow == width * 4, "row padding unsupported by engine MMAP transport")
        let page = Int(getpagesize())
        length = (bytesPerRow * height + page - 1) / page * page

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("frame-\(width)x\(height).rgba")
        let fd = open(url.path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        guard ftruncate(fd, off_t(length)) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        guard let p = mmap(nil, length, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0), p != MAP_FAILED else {
            throw POSIXError(.init(rawValue: errno) ?? .ENOMEM)
        }
        base = p
        memset(base, 0, length)
        guard let buf = device.makeBuffer(bytesNoCopy: base, length: length, options: .storageModeShared, deallocator: nil) else {
            throw POSIXError(.ENOMEM)
        }
        buffer = buf
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        desc.storageMode = .shared
        desc.usage = .shaderRead
        guard let tex = buf.makeTexture(descriptor: desc, offset: 0, bytesPerRow: bytesPerRow) else {
            throw POSIXError(.ENOMEM)
        }
        texture = tex
    }

    /// Snapshot of the current frame (one memcpy; no engine round trip).
    func cgImage() -> CGImage? {
        let data = Data(bytes: base, count: bytesPerRow * height) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Coarse luminance grid of the current frame (diagnostics: frame order checks).
    func lumaGrid(cols: Int, rows: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: cols * rows)
        let px = base.assumingMemoryBound(to: UInt8.self)
        for r in 0..<rows {
            let y = (r * height + height / 2) / rows
            for c in 0..<cols {
                let x = (c * width + width / 2) / cols
                let o = y * bytesPerRow + x * 4
                out[r * cols + c] = UInt8((Int(px[o]) * 3 + Int(px[o + 1]) * 6 + Int(px[o + 2])) / 10)
            }
        }
        return out
    }

    deinit {
        munmap(base, length)
        try? FileManager.default.removeItem(at: url)
    }
}
