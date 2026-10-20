import Foundation
import QuartzCore

/// Frame pacing as the player sees it, one line per second in
/// ~/.kolibri/logs/perf-<instance>.log: when guest frames arrive, how long the
/// copy-out takes, when each new frame actually reached the glass (Metal
/// presentedTime) and how regular the display callbacks are. Cheap enough to
/// leave on; it is the ground truth for "it stutters" reports.
final class FramePerf: @unchecked Sendable {
    private let lock = NSLock()
    private var arrivals: [Double] = []
    private var copyMs: [Double] = []
    private var onGlass: [Double] = []
    private var lastOnGlass: Double?
    private var dropped = 0
    private var callbacks: [Double] = []
    private var lastCallback: Double?

    func arrival(_ t: Double) { lock.withLock { arrivals.append(t) } }
    func copied(ms: Double) { lock.withLock { copyMs.append(ms) } }

    /// A new guest frame's drawable was shown at `t` (0: dropped, never on screen).
    func presented(_ t: Double) {
        lock.withLock {
            if t <= 0 { dropped += 1 } else { onGlass.append(t) }
        }
    }

    func callback(_ t: Double) {
        lock.withLock {
            if let l = lastCallback { callbacks.append((t - l) * 1000) }
            lastCallback = t
        }
    }

    /// One summary line for the last interval; resets the counters.
    func line(context: String) -> String {
        lock.withLock {
            func gaps(_ ts: [Double], prev: Double?) -> [Double] {
                var out: [Double] = []
                var p = prev
                for t in ts.sorted() { if let p { out.append((t - p) * 1000) }; p = t }
                return out
            }
            func q(_ v: [Double], _ p: Double) -> Double {
                let s = v.sorted(); return s.isEmpty ? 0 : s[min(s.count - 1, Int(Double(s.count) * p))]
            }
            let arrive = gaps(arrivals, prev: nil)
            let glass = gaps(onGlass, prev: lastOnGlass)
            let s = String(format: "%@ arrive=%d gapMax=%.0f | shown=%d gap p50=%.1f p95=%.1f max=%.1f >34ms=%d dropped=%d | copyMax=%.1f | callbacks=%d cbMax=%.1f",
                           context, arrivals.count, arrive.max() ?? 0,
                           onGlass.count, q(glass, 0.5), q(glass, 0.95), glass.max() ?? 0, glass.filter { $0 > 34 }.count, dropped,
                           copyMs.max() ?? 0, callbacks.count + 1, callbacks.max() ?? 0)
            if let last = onGlass.max() { lastOnGlass = last }
            arrivals.removeAll(); copyMs.removeAll(); onGlass.removeAll(); callbacks.removeAll(); dropped = 0
            return s
        }
    }
}
