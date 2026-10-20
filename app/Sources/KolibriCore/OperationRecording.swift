import Foundation

/// 操作录制: the exact input stream Kolibri sent to the guest, with timestamps,
/// so it can be replayed, looped, sped up and merged. Stored as `.vprec` JSON.
public struct OperationRecording: Codable, Hashable, Sendable {
    public enum Event: Codable, Hashable, Sendable {
        case touch(id: Int32, x: Int32, y: Int32, down: Bool)
        case key(code: UInt16, down: Bool)
        /// Android navigation keys ("GoBack", "GoHome", …).
        case androidKey(String)
        case wheel(dx: Int32, dy: Int32)
    }

    public struct Stamped: Codable, Hashable, Sendable {
        /// Seconds from the start of the recording.
        public var t: Double
        public var e: Event
        public init(t: Double, e: Event) { self.t = t; self.e = e }
    }

    public var name: String
    public var package: String?
    /// Guest resolution while recording; replays scale to the current one.
    public var width: Int
    public var height: Int
    public var createdAt: Date
    public var duration: Double
    /// 0 = loop forever.
    public var repeatTimes: Int
    /// Pause between repeats, seconds.
    public var repeatDelay: Double
    public var speed: Double
    public var events: [Stamped]

    public init(name: String, package: String?, width: Int, height: Int, createdAt: Date = Date(),
                duration: Double, repeatTimes: Int = 1, repeatDelay: Double = 0, speed: Double = 1, events: [Stamped]) {
        self.name = name
        self.package = package
        self.width = width
        self.height = height
        self.createdAt = createdAt
        self.duration = duration
        self.repeatTimes = repeatTimes
        self.repeatDelay = repeatDelay
        self.speed = speed
        self.events = events
    }

    /// One recording that plays `parts` back to back, `gap` seconds apart.
    /// Touch ids are offset per part so fingers never collide.
    public static func merge(_ parts: [OperationRecording], name: String, gap: Double = 0.5) -> OperationRecording? {
        guard let first = parts.first else { return nil }
        var events: [Stamped] = []
        var offset = 0.0
        for (n, p) in parts.enumerated() {
            let sx = Double(first.width) / Double(max(p.width, 1)), sy = Double(first.height) / Double(max(p.height, 1))
            for s in p.events {
                var e = s.e
                if case let .touch(id, x, y, d) = e {
                    e = .touch(id: id + Int32(n) * 64, x: Int32(Double(x) * sx), y: Int32(Double(y) * sy), down: d)
                }
                events.append(Stamped(t: offset + s.t, e: e))
            }
            offset += p.duration + gap
        }
        return OperationRecording(name: name, package: first.package, width: first.width, height: first.height,
                                  duration: max(offset - gap, 0), events: events)
    }
}

/// Captures events while recording. Pausing leaves a hole that is cut out of
/// the timeline, like the floating bar pause.
public final class OperationRecorder {
    public private(set) var events: [OperationRecording.Stamped] = []
    public private(set) var paused = false
    private let start: TimeInterval
    private var pausedTotal: TimeInterval = 0
    private var pausedAt: TimeInterval?
    /// Fingers currently down, so pausing/stopping never leaves one stuck in the file.
    private var down: [Int32: (Int32, Int32)] = [:]

    public init(now: TimeInterval) { start = now }

    public func elapsed(now: TimeInterval) -> Double {
        (pausedAt ?? now) - start - pausedTotal
    }

    public func record(_ e: OperationRecording.Event, now: TimeInterval) {
        guard !paused else { return }
        if case let .touch(id, x, y, d) = e {
            if d { down[id] = (x, y) } else if down.removeValue(forKey: id) == nil { return }
        }
        events.append(.init(t: elapsed(now: now), e: e))
    }

    public func pause(now: TimeInterval) {
        guard !paused else { return }
        liftAll(now: now)
        paused = true
        pausedAt = now
    }

    public func resume(now: TimeInterval) {
        guard paused, let p = pausedAt else { return }
        pausedTotal += now - p
        pausedAt = nil
        paused = false
    }

    public func finish(name: String, package: String?, width: Int, height: Int, now: TimeInterval) -> OperationRecording {
        if paused { resume(now: now) }
        liftAll(now: now)
        return OperationRecording(name: name, package: package, width: width, height: height,
                                  duration: elapsed(now: now), events: events)
    }

    private func liftAll(now: TimeInterval) {
        for (id, p) in down.sorted(by: { $0.key < $1.key }) {
            events.append(.init(t: elapsed(now: now), e: .touch(id: id, x: p.0, y: p.1, down: false)))
        }
        down.removeAll()
    }
}

/// Replays a recording against the clock. Call `tick` every display frame.
public final class OperationPlayer {
    public let recording: OperationRecording
    public private(set) var finished = false
    public private(set) var paused = false
    /// 1-based repeat currently playing.
    public private(set) var round = 1
    private let sx: Double, sy: Double
    private var roundStart: TimeInterval
    private var next = 0
    private var pausedAt: TimeInterval?
    private var down: [Int32: (Int32, Int32)] = [:]
    /// Replayed fingers use ids above the live input's so both can coexist.
    public static let idOffset: Int32 = 2000

    public init(_ r: OperationRecording, screenWidth: Int, screenHeight: Int, now: TimeInterval) {
        recording = r
        sx = Double(screenWidth) / Double(max(r.width, 1))
        sy = Double(screenHeight) / Double(max(r.height, 1))
        roundStart = now
    }

    /// Progress of the current round, in recording seconds.
    public func position(now: TimeInterval) -> Double {
        min(((pausedAt ?? now) - roundStart) * recording.speed, recording.duration)
    }

    public func tick(now: TimeInterval) -> [OperationRecording.Event] {
        guard !finished, !paused else { return [] }
        let pos = (now - roundStart) * recording.speed
        var out: [OperationRecording.Event] = []
        while next < recording.events.count, recording.events[next].t <= pos {
            out.append(map(recording.events[next].e))
            next += 1
        }
        if next >= recording.events.count && pos >= recording.duration {
            out += liftAll()
            if recording.repeatTimes == 0 || round < recording.repeatTimes {
                round += 1
                next = 0
                roundStart = now + recording.repeatDelay
            } else {
                finished = true
            }
        }
        return out
    }

    public func pause(now: TimeInterval) -> [OperationRecording.Event] {
        guard !paused, !finished else { return [] }
        paused = true
        pausedAt = now
        return liftAll()
    }

    public func resume(now: TimeInterval) {
        guard paused, let p = pausedAt else { return }
        roundStart += now - p
        pausedAt = nil
        paused = false
    }

    public func stop() -> [OperationRecording.Event] {
        finished = true
        return liftAll()
    }

    private func map(_ e: OperationRecording.Event) -> OperationRecording.Event {
        guard case let .touch(id, x, y, d) = e else { return e }
        let m = OperationRecording.Event.touch(id: id + Self.idOffset, x: Int32(Double(x) * sx), y: Int32(Double(y) * sy), down: d)
        if case let .touch(mid, mx, my, _) = m { if d { down[mid] = (mx, my) } else { down[mid] = nil } }
        return m
    }

    private func liftAll() -> [OperationRecording.Event] {
        defer { down.removeAll() }
        return down.sorted { $0.key < $1.key }.map { .touch(id: $0.key, x: $0.value.0, y: $0.value.1, down: false) }
    }
}
