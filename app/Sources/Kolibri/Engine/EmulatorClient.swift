import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import SwiftProtobuf
import KolibriCore

typealias EC = Android_Emulation_Control_EmulatorController
typealias InputEvent = Android_Emulation_Control_InputEvent

/// gRPC connection to one engine instance.
///
/// Input goes through a single long-lived client stream (`streamInputEvent`)
/// instead of one unary call per event: no per-event HTTP/2 stream setup, so
/// key-to-touch latency stays sub-millisecond on loopback.
final class EmulatorClient: @unchecked Sendable {
    let port: Int
    private let grpc: GRPCClient<HTTP2ClientTransport.Posix>
    private let ec: EC.Client<HTTP2ClientTransport.Posix>
    private let input: AsyncStream<InputEvent>.Continuation
    private var tasks: [Task<Void, Never>] = []

    init(port: Int) throws {
        self.port = port
        let transport = try HTTP2ClientTransport.Posix(
            target: .ipv4(address: "127.0.0.1", port: port),
            transportSecurity: .plaintext
        )
        grpc = GRPCClient(transport: transport)
        ec = EC.Client(wrapping: grpc)
        let (stream, cont) = AsyncStream.makeStream(of: InputEvent.self, bufferingPolicy: .unbounded)
        input = cont

        let grpc = self.grpc
        tasks.append(Task.detached { try? await grpc.runConnections() })
        let ec = self.ec
        tasks.append(Task.detached {
            var it = stream.makeAsyncIterator()
            var pending: InputEvent?
            while !Task.isCancelled {
                do {
                    _ = try await ec.streamInputEvent(request: StreamingClientRequest { writer in
                        if let p = pending { try await writer.write(p); pending = nil }
                        while let ev = await it.next() {
                            pending = ev
                            try await writer.write(ev)
                            pending = nil
                        }
                    })
                    return // stream finished normally (client closed)
                } catch {
                    // Engine restarting / not up yet: retry, keeping the unsent event.
                    InputLog.write("input stream to :\(port) dropped (\(error)); reconnecting")
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
        })
    }

    func close() {
        input.finish()
        grpc.beginGracefulShutdown()
        tasks.forEach { $0.cancel() }
    }

    // MARK: Input

    func send(touches: [TouchPoint]) {
        guard !touches.isEmpty else { return }
        var te = Android_Emulation_Control_TouchEvent()
        te.touches = touches.map { t in
            var p = Android_Emulation_Control_Touch()
            p.x = t.x
            p.y = t.y
            p.identifier = t.id
            p.pressure = t.down ? 1 : 0
            return p
        }
        var ev = InputEvent()
        ev.touchEvent = te
        input.yield(ev)
    }

    func sendKey(macKeyCode: UInt16, down: Bool) {
        var k = Android_Emulation_Control_KeyboardEvent()
        k.codeType = .mac
        k.keyCode = Int32(macKeyCode)
        k.eventType = down ? .keydown : .keyup
        var ev = InputEvent()
        ev.keyEvent = k
        input.yield(ev)
    }

    func sendAndroidKey(_ key: String) {
        var k = Android_Emulation_Control_KeyboardEvent()
        k.key = key          // e.g. "AudioVolumeUp", "GoBack", "GoHome" (W3C key names)
        k.eventType = .keypress
        var ev = InputEvent()
        ev.keyEvent = k
        input.yield(ev)
    }

    func sendText(_ text: String) {
        var k = Android_Emulation_Control_KeyboardEvent()
        k.text = text
        var ev = InputEvent()
        ev.keyEvent = k
        input.yield(ev)
    }

    func sendWheel(dx: Int32, dy: Int32) {
        var w = Android_Emulation_Control_WheelEvent()
        w.dx = dx
        w.dy = dy
        var ev = InputEvent()
        ev.wheelEvent = w
        input.yield(ev)
    }

    // MARK: Frames

    /// Streams frames into a client-owned shared-memory file (MMAP transport):
    /// the engine writes pixels straight into memory our Metal texture aliases.
    func streamFrames(handle: URL, width: Int, height: Int, onFrame: @escaping @Sendable (Android_Emulation_Control_Image) -> Void) async throws {
        var fmt = Android_Emulation_Control_ImageFormat()
        fmt.format = .rgba8888
        fmt.width = UInt32(width)
        fmt.height = UInt32(height)
        fmt.transport.channel = .mmap
        fmt.transport.handle = handle.absoluteString   // file:///...
        try await ec.streamScreenshot(request: ClientRequest(message: fmt)) { response in
            for try await img in response.messages { onFrame(img) }
        }
    }

    func screenshotPNG() async throws -> Data {
        var fmt = Android_Emulation_Control_ImageFormat()
        fmt.format = .png
        return try await ec.getScreenshot(request: ClientRequest(message: fmt)) { try $0.message.image }
    }

    func setPaused(_ paused: Bool) async {
        var s = Android_Emulation_Control_VmRunState()
        s.state = paused ? .paused : .running
        _ = try? await ec.setVmState(request: ClientRequest(message: s)) { _ in () }
    }

    // MARK: Device

    /// 摇一摇: jiggle the virtual device so the accelerometer sees a shake.
    func shake() async {
        for i in 0..<12 {
            var v = Android_Emulation_Control_PhysicalModelValue()
            v.target = .position
            v.value.data = [i == 11 ? 0 : (i % 2 == 0 ? 0.04 : -0.04), 0, 0]
            _ = try? await ec.setPhysicalModel(request: ClientRequest(message: v)) { _ in () }
            try? await Task.sleep(for: .milliseconds(45))
        }
    }

    /// 重力感应: tilt the virtual device (degrees around x / y).
    func setTilt(pitch: Float, roll: Float) async {
        var v = Android_Emulation_Control_PhysicalModelValue()
        v.target = .rotation
        v.value.data = [pitch, roll, 0]
        _ = try? await ec.setPhysicalModel(request: ClientRequest(message: v)) { _ in () }
    }

    /// Guest audio as the engine mixes it (PCM s16, 48 kHz stereo), straight from the
    /// engine process: no OS capture permission involved. Runs until cancelled.
    func streamAudio(onPacket: @escaping @Sendable (Data, UInt64) -> Void) async throws {
        var f = Android_Emulation_Control_AudioFormat()
        f.samplingRate = 48_000
        f.channels = .stereo
        f.format = .audFmtS16
        f.mode = .modeRealTime
        try await ec.streamAudio(request: ClientRequest(message: f)) { response in
            for try await p in response.messages { onPacket(p.audio, p.timestamp) }
        }
    }

    func setClipboard(_ text: String) async {
        var c = Android_Emulation_Control_ClipData()
        c.text = text
        _ = try? await ec.setClipboard(request: ClientRequest(message: c)) { _ in () }
    }
}
