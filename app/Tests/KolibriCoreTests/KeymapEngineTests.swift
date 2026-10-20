import Foundation
import Testing
@testable import KolibriCore

private let W = 1600, H = 900
private let kW: UInt16 = 13, kA: UInt16 = 0, kS: UInt16 = 1, kD: UInt16 = 2, kSpace: UInt16 = 49, kQ: UInt16 = 12
private let kI: UInt16 = 34, kJ: UInt16 = 38, kK: UInt16 = 40, kL: UInt16 = 37

private func engine(_ controls: [Control], zoom: WheelZoom? = nil) -> KeymapEngine {
    KeymapEngine(keymap: Keymap(name: "t", controls: controls, wheelZoom: zoom), screenWidth: W, screenHeight: H)
}

private func run(_ e: KeymapEngine, from: Double, to: Double) -> [TouchPoint] {
    var out: [TouchPoint] = []
    for t in stride(from: from, through: to, by: 0.005) { out += e.tick(now: t) }
    return out
}

private let wasd = Control.joystick(up: .key(kW), down: .key(kS), left: .key(kA), right: .key(kD),
                                    center: NPoint(0.2, 0.7), radius: 0.05, stick: "left")

@Test func holdDownAndUp() {
    let e = engine([.button(binding: .key(kSpace), at: NPoint(0.5, 0.5), mode: .hold)])
    #expect(e.press(.key(kSpace), now: 0) == [TouchPoint(id: 0, x: 800, y: 450, down: true)])
    #expect(e.press(.key(kSpace), now: 0.01).isEmpty) // key repeat ignored
    #expect(e.release(.key(kSpace), now: 0.1) == [TouchPoint(id: 0, x: 800, y: 450, down: false)])
    #expect(e.activeTouches.isEmpty)
}

@Test func twoControlsHeldAtOnceUseDistinctFingers() {
    let e = engine([
        .button(binding: .key(kSpace), at: NPoint(0.9, 0.8), mode: .hold),
        .button(binding: .mouse(0), at: NPoint(0.8, 0.6), mode: .hold),
    ])
    _ = e.press(.key(kSpace), now: 0)
    _ = e.press(.mouse(0), now: 0)
    #expect(Set(e.activeTouches.map(\.id)).count == 2)
}

@Test func joystickLandsOnCenterThenSlidesOutAndStaysCircular() {
    let e = engine([wasd])
    let out = e.press(.key(kD), now: 0)
    #expect(out == [TouchPoint(id: 0, x: 320, y: 630, down: true)])   // only the centre
    #expect(e.tick(now: 0.004).isEmpty)                               // 8 ms settle first
    let slide = run(e, from: 0.008, to: 0.2)
    #expect(slide.count == 6)                                         // 6 steps, never a jump
    #expect(zip([320] + slide.dropLast().map(\.x), slide.map(\.x)).allSatisfy { $1 - $0 <= 14 && $1 > $0 })
    #expect(slide.last!.x == 400 && slide.last!.y == 630)
    _ = e.press(.key(kW), now: 0.3)
    let p = run(e, from: 0.3, to: 0.5).last!
    let dx = Double(p.x - 320), dy = Double(p.y - 630)
    #expect(abs((dx * dx + dy * dy).squareRoot() - 80) < 2)
    _ = e.release(.key(kD), now: 0.6)
    #expect(e.release(.key(kW), now: 0.7).last?.down == false)
}

@Test func joystickRetargetsMidSlideWithoutRestarting() {
    let e = engine([wasd])
    _ = e.press(.key(kD), now: 0)
    _ = run(e, from: 0.008, to: 0.03)                  // two steps toward the right
    _ = e.press(.key(kW), now: 0.035)                  // up-right before the slide ends
    let rest = run(e, from: 0.035, to: 0.3)
    #expect(rest.count <= 4)                           // remaining steps only
    let p = rest.last!
    #expect(p.x > 320 && p.y < 630)
}

@Test func oppositeMovementKeysUseTheLastPressed() {
    let e = engine([wasd])
    _ = e.press(.key(kA), now: 0)
    _ = run(e, from: 0, to: 0.2)
    _ = e.press(.key(kD), now: 0.3)                    // A still held: D wins, finger stays down
    let p = run(e, from: 0.3, to: 0.5).last!
    #expect(p.down && p.x == 400)
    let back = e.release(.key(kD), now: 0.6) + run(e, from: 0.6, to: 0.8)
    #expect(back.last!.down && back.last!.x == 240)    // back to A
}

@Test func gamepadStickLandsOnCenterThenFollowsDirectly() {
    let e = engine([wasd])
    #expect(e.stick("left", x: 1, y: 0, dt: 0.016) == [TouchPoint(id: 0, x: 320, y: 630, down: true)])
    #expect(run(e, from: 0.01, to: 0.05).last!.x == 400)
    #expect(e.stick("left", x: 0, y: -1, dt: 0.016).last!.y == 550)   // no glide for analog input
}

@Test func aimRecentersWhenItRunsOutOfRoom() {
    let e = engine([.aim(center: NPoint(0.6, 0.5), radius: 0.1, sensitivity: 1, stick: nil)])
    let first = e.mouseMoved(dx: 50, dy: 0)
    #expect(first.first?.down == true && first.last!.x == 1010)
    let big = e.mouseMoved(dx: 200, dy: 0)
    #expect(big.contains { !$0.down })
    #expect(big.last!.down && big.last!.x == 1160)
}

@Test func mouseSkillCapturesMouseAndCastsOnRelease() {
    let e = engine([
        .aim(center: NPoint(0.6, 0.5), radius: 0.2, sensitivity: 1, stick: nil),
        .skill(binding: .key(kQ), at: NPoint(0.85, 0.7), radius: 0.05, options: SkillOptions()),
    ])
    _ = e.press(.key(kQ), now: 0)
    let moved = e.mouseMoved(dx: 1000, dy: 0)
    #expect(moved.count == 1 && moved[0].x == 1360 + 80)
    #expect(e.release(.key(kQ), now: 0.2).first?.down == false)
}

@Test func skillFollowsJoystickDirection() {
    let e = engine([wasd, .skill(binding: .key(kQ), at: NPoint(0.8, 0.7), radius: 0.05, options: SkillOptions(followJoystick: true))])
    _ = e.press(.key(kD), now: 0)
    _ = run(e, from: 0, to: 0.2)
    let cast = e.press(.key(kQ), now: 0.01)
    #expect(cast.last!.x == 1280 + 80)          // aimed right like the walk stick
    let turned = e.press(.key(kW), now: 0.02)   // walking up-right drags the skill too
    #expect(turned.contains { $0.id != 0 && $0.y < 630 })
}

@Test func turboTogglesOverTime() {
    let e = engine([.button(binding: .key(kSpace), at: NPoint(0.5, 0.5), mode: .turbo(hz: 10))])
    #expect(e.press(.key(kSpace), now: 0).first?.down == true)
    #expect(e.tick(now: 0.06).first?.down == false)
    #expect(e.tick(now: 0.11).first?.down == true)
    _ = e.release(.key(kSpace), now: 0.12)
    #expect(e.tick(now: 0.2).isEmpty)
}

@Test func clickTapsOnceEvenWhileHeld() {
    let e = engine([.button(binding: .key(kSpace), at: NPoint(0.5, 0.5), mode: .click(holdMs: 40))])
    #expect(e.press(.key(kSpace), now: 0).last?.down == true)
    #expect(e.tick(now: 0.05).contains { !$0.down })
    #expect(e.tick(now: 0.5).isEmpty)
    #expect(e.release(.key(kSpace), now: 0.6).isEmpty)
}

@Test func doubleClickAndBurstCountTaps() {
    let d = engine([.button(binding: .key(kSpace), at: NPoint(0.5, 0.5), mode: .doubleClick(holdMs: 40, gapMs: 60))])
    let dOut = d.press(.key(kSpace), now: 0) + run(d, from: 0.005, to: 0.5)
    #expect(dOut.filter(\.down).count == 2 && d.activeTouches.isEmpty)

    let b = engine([.button(binding: .key(kSpace), at: NPoint(0.5, 0.5), mode: .burst(count: 5, hz: 20))])
    let bOut = b.press(.key(kSpace), now: 0) + run(b, from: 0.005, to: 1)
    #expect(bOut.filter(\.down).count == 5 && b.activeTouches.isEmpty)
}

@Test func toggleLatchesUntilSecondPress() {
    let e = engine([.button(binding: .key(kQ), at: NPoint(0.5, 0.5), mode: .toggle)])
    #expect(e.press(.key(kQ), now: 0).first?.down == true)
    #expect(e.release(.key(kQ), now: 0.1).isEmpty)
    #expect(e.activeTouches.count == 1)
    #expect(e.press(.key(kQ), now: 1).first?.down == false)
}

@Test func longPressHoldsForDuration() {
    let e = engine([.button(binding: .key(kQ), at: NPoint(0.5, 0.5), mode: .longPress(ms: 600))])
    _ = e.press(.key(kQ), now: 0)
    _ = e.release(.key(kQ), now: 0.05)
    #expect(e.tick(now: 0.3).isEmpty && e.activeTouches.count == 1)
    #expect(e.tick(now: 0.7).contains { !$0.down })
}

@Test func swipeFollowsPathThenLifts() {
    let e = engine([.swipe(binding: .key(kQ), path: [NPoint(0.2, 0.5), NPoint(0.8, 0.5)], durationMs: 200)])
    let out = e.press(.key(kQ), now: 0) + run(e, from: 0.005, to: 0.4)
    #expect(out.first?.x == 320 && out.first?.down == true)
    #expect(out.filter(\.down).last!.x == 1280)
    #expect(out.last?.down == false && e.activeTouches.isEmpty)
}

@Test func macroLoopsWhileHeldThenRunsReleaseScript() {
    var keys: [(UInt16, Bool)] = []
    let e = engine([.macro(binding: .key(kQ),
                           press: [.key(kSpace, down: true), .loopStart, .tap(NPoint(0.5, 0.5), holdMs: 20), .sleep(ms: 30), .loopEnd],
                           release: [.key(kSpace, down: false), .tap(NPoint(0.9, 0.9), holdMs: 20)])])
    e.onKey = { keys.append(($0, $1)) }
    let held = e.press(.key(kQ), now: 0) + run(e, from: 0.005, to: 0.5)
    #expect(held.filter(\.down).count >= 8)          // ~50ms per loop for 0.5s
    let rel = e.release(.key(kQ), now: 0.5) + run(e, from: 0.505, to: 0.8)
    #expect(rel.contains { $0.down && $0.x > 1400 })
    #expect(keys.first! == (kSpace, true) && keys.last! == (kSpace, false))
    #expect(e.activeTouches.isEmpty)
}

@Test func lookKeysPanCamera() {
    let e = engine([.lookKeys(up: .key(kI), down: .key(kK), left: .key(kJ), right: .key(kL),
                              center: NPoint(0.6, 0.4), radius: 0.2, speed: 0.5)])
    _ = e.press(.key(kL), now: 0)
    let out = run(e, from: 0.005, to: 0.2)
    #expect(out.first?.down == true && out.last!.x > 960 + 100)   // ~0.1 screen width in 0.2s
    #expect(e.release(.key(kL), now: 0.25).last?.down == false)
}

@Test func wheelPinchZoomUsesTwoFingersAndEnds() {
    let e = engine([], zoom: WheelZoom(center: NPoint(0.5, 0.5), stepDistance: 0.02))
    let a = e.wheel(notches: 1, now: 0)
    #expect(Set(a.map(\.id)).count == 2)
    let b = e.wheel(notches: 1, now: 0.05)
    #expect(b.contains { $0.x > a.filter { $0.down }.map(\.x).max()! })   // fingers spread
    #expect(e.tick(now: 0.5).filter { !$0.down }.count == 2)
}

@Test func gamepadStickDrivesJoystick() {
    let e = engine([wasd])
    #expect(e.stick("left", x: 0, y: -1, dt: 0.016).last!.y == 630)   // lands on the centre first
    #expect(e.tick(now: 0.02).last!.y < 630)
    #expect(e.stick("left", x: 0, y: 0, dt: 0.016).last?.down == false)
}

@Test func keymapRoundTripsThroughJSONAndOldFilesStillLoad() throws {
    let k = Keymap(name: "FPS", package: "com.example.game", controls: [
        wasd,
        .aim(center: NPoint(0.65, 0.45), radius: 0.15, sensitivity: 1.2, stick: "right"),
        .button(binding: .mouse(0), at: NPoint(0.85, 0.65), mode: .burst(count: 3, hz: 10)),
        .swipe(binding: .key(kQ), path: [NPoint(0.1, 0.1), NPoint(0.2, 0.2)], durationMs: 100),
        .macro(binding: .key(kSpace), press: [.loopStart, .tap(NPoint(0.5, 0.5), holdMs: 30), .loopEnd], release: []),
    ], wheelZoom: WheelZoom())
    let data = try JSONEncoder().encode(k)
    #expect(try JSONDecoder().decode(Keymap.self, from: data) == k)
    let old = #"{"name":"old","controls":[]}"#.data(using: .utf8)!
    #expect(try JSONDecoder().decode(Keymap.self, from: old).passthrough == Passthrough())
}

// MARK: control types added in round 2

@Test func fireAndTurnSteersTheFireFinger() {
    let e = engine([.aim(center: NPoint(0.6, 0.5), radius: 0.2, sensitivity: 1, stick: nil),
                    .fire(binding: .mouse(0), at: NPoint(0.85, 0.6), radius: 0.1, dragAim: true)])
    _ = e.press(.mouse(0), now: 0)
    #expect(e.capturesMouse)
    let moved = e.mouseMoved(dx: 80, dy: 0)
    #expect(moved.count == 1 && moved[0].x == 1360 + 80)   // fire finger moved, aim untouched
    #expect(e.release(.mouse(0), now: 0.1).first?.down == false)
    #expect(!e.capturesMouse)
}

@Test func spellCancelDragsHeldSkillAway() {
    let e = engine([.skill(binding: .key(kQ), at: NPoint(0.8, 0.7), radius: 0.05, options: SkillOptions()),
                    .spellCancel(binding: .key(kSpace), at: NPoint(0.9, 0.2))])
    _ = e.press(.key(kQ), now: 0)
    let out = e.press(.key(kSpace), now: 0.1)
    #expect(out.map(\.down) == [true, false] && out[0].x == 1440 && out[0].y == 180)
    #expect(e.release(.key(kQ), now: 0.2).isEmpty)   // already cancelled
}

@Test func rightWalkPointsTowardCursor() {
    let e = engine([.rightWalk(binding: .mouse(1), center: NPoint(0.15, 0.7), radius: 0.06)])
    _ = e.pointerMoved(to: NPoint(0.9, 0.5))           // cursor right of the hero
    let out = e.press(.mouse(1), now: 0)
    #expect(out.last!.x == 240 + 96 && out.last!.y == 630)
    let up = e.pointerMoved(to: NPoint(0.5, 0.1))      // now straight up
    #expect(up.last!.x == 240 && up.last!.y < 630)
    #expect(e.release(.mouse(1), now: 0.1).first?.down == false)
}

@Test func observeKeyDragsCameraInsideItsArea() {
    let e = engine([.observe(binding: .key(kSpace), at: NPoint(0.7, 0.4), radius: 0.05, sensitivity: 1)])
    #expect(e.press(.key(kSpace), now: 0).first?.x == 1120)
    #expect(e.capturesMouse)
    #expect(e.mouseMoved(dx: 1000, dy: 0).last!.x == 1120 + 80)   // clamped to radius
    #expect(e.release(.key(kSpace), now: 0.1).first?.down == false)
}

@Test func zoomKeysPinchBothWays() {
    let e = engine([.zoomKeys(zoomIn: .key(kI), zoomOut: .key(kK), center: NPoint(0.5, 0.5))])
    let a = e.press(.key(kI), now: 0)
    let wide = a.filter { $0.id == 1001 }.last!.x
    _ = e.release(.key(kI), now: 0.01)
    let b = e.press(.key(kK), now: 0.05)
    #expect(b.filter { $0.id == 1001 }.last!.x < wide)
}

@Test func gravityKeysTilt() {
    var tilts: [(Double, Double)] = []
    let e = engine([.gravity(up: .key(kI), down: .key(kK), left: .key(kJ), right: .key(kL))])
    e.onTilt = { tilts.append(($0, $1)) }
    _ = e.press(.key(kL), now: 0)
    _ = e.press(.key(kI), now: 0)
    _ = e.release(.key(kL), now: 0)
    _ = e.release(.key(kI), now: 0)
    #expect(tilts.map(\.0) == [1, 1, 0, 0] && tilts.map(\.1) == [0, -1, -1, 0])
}

@Test func extrasStayAlignedWhenRemoving() {
    var k = Keymap(name: "x", controls: [wasd, .button(binding: .key(kQ), at: NPoint(0.5, 0.5), mode: .hold)])
    k.setExtra(1, ControlExtra(note: "跳", showHint: false))
    k.removeControl(at: 0)
    #expect(k.extra(0).note == "跳" && !k.extra(0).showHint && k.extra(5) == ControlExtra())
}

// MARK: 断触 regressions

@Test func reloadingTheSameSchemeKeepsFingersDown() {
    let k = Keymap(name: "t", controls: [wasd])
    let e = KeymapEngine(keymap: k, screenWidth: W, screenHeight: H)
    _ = e.press(.key(kW), now: 0)
    #expect(e.load(k).isEmpty && e.activeTouches.count == 1)
}

@Test func unlockingPointerOnlyLiftsMouseLook() {
    let e = engine([wasd, .aim(center: NPoint(0.6, 0.5), radius: 0.2, sensitivity: 1, stick: nil)])
    _ = e.press(.key(kW), now: 0)
    _ = e.mouseMoved(dx: 30, dy: 0)
    #expect(e.activeTouches.count == 2)
    let lifted = e.releaseMouseControls()
    #expect(lifted.count == 1 && e.activeTouches.count == 1)   // still walking
}
