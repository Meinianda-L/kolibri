import Foundation
import IOSurface
import Metal

/// Zero-copy guest frames: the self-built engine blits every posted frame on
/// the GPU into one of four IOSurfaces and records the newest one in a small shared header
/// (`<avd>/frame-iosurface.bin`, written by gfxstream's kolibri_iosurface_export.cpp).
/// The same IOSurfaces back MTLTextures here, so a frame reaches the screen without any CPU
/// readback, gRPC message or upload. Layout: see the engine file's header comment.
final class IOSurfaceFrames {
    static let fileName = "frame-iosurface.bin"
    private static let magic: UInt32 = 0x534F_494B  // 'KIOS'
    private static let none: UInt32 = 0xFFFF_FFFF

    let width: Int
    let height: Int
    private let base: UnsafeMutableRawPointer
    private let length = 128
    private var textures: [MTLTexture] = []
    private var lastSeq: UInt64 = 0

    /// Nil unless the engine is exporting (header present and valid).
    init?(url: URL, device: MTLDevice) {
        let fd = open(url.path, O_RDWR)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard let p = mmap(nil, length, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0), p != MAP_FAILED else { return nil }
        base = p
        guard base.load(fromByteOffset: 0, as: UInt32.self) == Self.magic,
              base.load(fromByteOffset: 4, as: UInt32.self) == 1 else { munmap(p, length); return nil }
        width = Int(base.load(fromByteOffset: 8, as: UInt32.self))
        height = Int(base.load(fromByteOffset: 12, as: UInt32.self))
        let count = Int(base.load(fromByteOffset: 20, as: UInt32.self))
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        desc.usage = .shaderRead
        desc.storageMode = .shared
        for i in 0..<count {
            let id = base.load(fromByteOffset: 24 + 4 * i, as: UInt32.self)
            guard let surface = IOSurfaceLookup(id),
                  let tex = device.makeTexture(descriptor: desc, iosurface: surface, plane: 0) else { munmap(p, length); return nil }
            textures.append(tex)
        }
        heartbeat()
    }

    deinit {
        base.storeBytes(of: Self.none, toByteOffset: 52, as: UInt32.self)
        munmap(base, length)
    }

    /// Tell the engine a reader is attached (it stops copying after 1 s without one).
    func heartbeat() {
        base.storeBytes(of: clock_gettime_nsec_np(CLOCK_UPTIME_RAW), toByteOffset: 56, as: UInt64.self)
    }

    /// The newest finished frame if it is new since the last call. The engine never writes
    /// the newest two surfaces nor the one marked as being read, so the returned texture
    /// stays intact while it is sampled (until two more frames have been published).
    func poll() -> (texture: MTLTexture, seq: UInt64)? {
        heartbeat()
        let seq = base.load(fromByteOffset: 40, as: UInt64.self)
        guard seq != lastSeq, seq != 0 else { return nil }
        OSMemoryBarrier()
        let idx = base.load(fromByteOffset: 48, as: UInt32.self)
        guard Int(idx) < textures.count else { return nil }
        base.storeBytes(of: idx, toByteOffset: 52, as: UInt32.self)
        lastSeq = seq
        return (textures[Int(idx)], seq)
    }
}
