import Foundation
import Testing
@testable import KolibriCore

@Test func macroScriptRoundTrips() throws {
    let actions: [MacroAction] = [.key(49, down: true), .loopStart, .tap(NPoint(0.5, 0.25), holdMs: 30), .sleep(ms: 20),
                                  .swipe([NPoint(0.1, 0.2), NPoint(0.3, 0.4)], ms: 150), .loopEnd,
                                  .down(NPoint(0.9, 0.9), finger: 2), .up(finger: 2), .key(49, down: false)]
    #expect(try MacroScript.parse(MacroScript.format(actions)) == actions)
}

@Test func macroScriptReportsLineErrors() throws {
    #expect(throws: MacroScript.ParseError(line: 2, message: "坐标要在 0~1 之间")) {
        try MacroScript.parse("tap 0.1 0.1\ntap 2 0.1")
    }
    #expect(throws: MacroScript.ParseError.self) { try MacroScript.parse("loop\ntap 0.1 0.1") }
    #expect(try MacroScript.parse("# comment only\n\nsleep 5 # trailing").count == 1)
}

@Test func recorderCutsPausesAndLiftsFingers() {
    let r = OperationRecorder(now: 10)
    r.record(.touch(id: 1, x: 5, y: 5, down: true), now: 11)
    r.pause(now: 12)                                     // lifts finger 1 at t=2
    r.record(.key(code: 1, down: true), now: 13)         // ignored while paused
    r.resume(now: 20)
    r.record(.key(code: 2, down: true), now: 21)         // t = 21-10-8 = 3
    let rec = r.finish(name: "x", package: nil, width: 100, height: 100, now: 22)
    #expect(rec.events.map(\.t) == [1, 2, 3])
    #expect(rec.events[1].e == .touch(id: 1, x: 5, y: 5, down: false))
    #expect(rec.duration == 4)
}

@Test func playerScalesRepeatsAndHonoursSpeed() {
    let rec = OperationRecording(name: "r", package: nil, width: 100, height: 100, duration: 1, repeatTimes: 2,
                                 repeatDelay: 0.5, speed: 2, events: [
        .init(t: 0, e: .touch(id: 0, x: 50, y: 50, down: true)),
        .init(t: 0.8, e: .touch(id: 0, x: 50, y: 50, down: false)),
    ])
    let p = OperationPlayer(rec, screenWidth: 200, screenHeight: 200, now: 0)
    #expect(p.tick(now: 0) == [.touch(id: 2000, x: 100, y: 100, down: true)])
    #expect(p.tick(now: 0.3).isEmpty)                  // 0.6s at 2x
    #expect(p.tick(now: 0.45).count == 1)              // up at 0.8
    _ = p.tick(now: 0.5)                               // round 1 done → delay 0.5
    #expect(p.round == 2 && p.tick(now: 0.8).isEmpty)
    #expect(p.tick(now: 1.0).first == .touch(id: 2000, x: 100, y: 100, down: true))
    _ = p.tick(now: 1.5)
    #expect(p.finished)
}

@Test func playerPauseLiftsAndStopEnds() {
    let rec = OperationRecording(name: "r", package: nil, width: 10, height: 10, duration: 5, events: [
        .init(t: 0, e: .touch(id: 3, x: 1, y: 1, down: true)),
    ])
    let p = OperationPlayer(rec, screenWidth: 10, screenHeight: 10, now: 0)
    _ = p.tick(now: 0)
    #expect(p.pause(now: 1) == [.touch(id: 2003, x: 1, y: 1, down: false)])
    p.resume(now: 3)
    #expect(p.position(now: 4) == 2)
    _ = p.stop()
    #expect(p.finished && p.tick(now: 10).isEmpty)
}

@Test func mergeConcatenatesWithGap() {
    let a = OperationRecording(name: "a", package: "g", width: 100, height: 100, duration: 1,
                               events: [.init(t: 0.5, e: .key(code: 1, down: true))])
    let b = OperationRecording(name: "b", package: "g", width: 200, height: 200, duration: 2,
                               events: [.init(t: 0, e: .touch(id: 0, x: 200, y: 200, down: true))])
    let m = OperationRecording.merge([a, b], name: "m", gap: 0.5)!
    #expect(m.duration == 3.5)
    #expect(m.events.last == .init(t: 1.5, e: .touch(id: 64, x: 100, y: 100, down: true)))
}
