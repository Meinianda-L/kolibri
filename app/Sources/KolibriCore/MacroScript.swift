import Foundation

/// Plain-text form of a macro, one action per line, so macros can be typed,
/// pasted and diffed` script).
///
///     tap 0.500 0.500 40        # x y [holdMs]
///     down 0.3 0.7 1            # x y finger
///     up 1                      # finger
///     swipe 200 0.2,0.5 0.8,0.5 # ms then points
///     sleep 30
///     keydown 49 / keyup 49     # macOS key code
///     loop / end                # repeat while held
public enum MacroScript {
    public struct ParseError: Error, Equatable, CustomStringConvertible {
        public var line: Int
        public var message: String
        public var description: String { L("第 \(line) 行：\(L(message))") }
    }

    public static func format(_ actions: [MacroAction]) -> String {
        actions.map { a in
            switch a {
            case let .tap(p, h): return "tap \(f(p.x)) \(f(p.y)) \(h)"
            case let .down(p, finger): return "down \(f(p.x)) \(f(p.y)) \(finger)"
            case let .up(finger): return "up \(finger)"
            case let .swipe(path, ms): return "swipe \(ms) " + path.map { "\(f($0.x)),\(f($0.y))" }.joined(separator: " ")
            case let .sleep(ms): return "sleep \(ms)"
            case let .key(k, down): return "\(down ? "keydown" : "keyup") \(k)"
            case .loopStart: return "loop"
            case .loopEnd: return "end"
            }
        }.joined(separator: "\n")
    }

    public static func parse(_ text: String) throws -> [MacroAction] {
        var out: [MacroAction] = []
        var depth = 0
        for (n, raw) in text.components(separatedBy: .newlines).enumerated() {
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let w = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let op = w.first?.lowercased() else { continue }
            let err = { (m: String) in ParseError(line: n + 1, message: m) }
            func num(_ i: Int) throws -> Double {
                guard i < w.count, let v = Double(w[i]) else { throw err("缺少数字") }
                return v
            }
            func point(_ i: Int) throws -> NPoint {
                let x = try num(i), y = try num(i + 1)
                guard (0...1).contains(x), (0...1).contains(y) else { throw err("坐标要在 0~1 之间") }
                return NPoint(x, y)
            }
            switch op {
            case "tap": out.append(.tap(try point(1), holdMs: w.count > 3 ? Int(try num(3)) : 40))
            case "down": out.append(.down(try point(1), finger: w.count > 3 ? Int(try num(3)) : 0))
            case "up": out.append(.up(finger: w.count > 1 ? Int(try num(1)) : 0))
            case "swipe":
                let ms = Int(try num(1))
                let pts = try w.dropFirst(2).map { s -> NPoint in
                    let c = s.split(separator: ",").compactMap { Double($0) }
                    guard c.count == 2, (0...1).contains(c[0]), (0...1).contains(c[1]) else { throw err("点要写成 x,y") }
                    return NPoint(c[0], c[1])
                }
                guard pts.count >= 2 else { throw err("滑动至少要 2 个点") }
                out.append(.swipe(pts, ms: ms))
            case "sleep", "wait": out.append(.sleep(ms: Int(try num(1))))
            case "keydown", "keyup": out.append(.key(UInt16(try num(1)), down: op == "keydown"))
            case "loop": depth += 1; out.append(.loopStart)
            case "end":
                guard depth > 0 else { throw err("end 前面没有 loop") }
                depth -= 1
                out.append(.loopEnd)
            default: throw err("不认识的指令 \(op)")
            }
        }
        if depth > 0 { throw ParseError(line: text.components(separatedBy: .newlines).count, message: "loop 缺少 end") }
        return out
    }

    private static func f(_ v: Double) -> String { String(format: "%.3f", v) }
}
