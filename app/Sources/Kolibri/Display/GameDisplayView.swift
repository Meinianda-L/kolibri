import AppKit
import CoreGraphics
import MetalKit
import SwiftUI
import KolibriCore

/// Metal surface that also owns raw input. Mapped keys/buttons go to the
/// keymap engine; everything else passes through as real touch/keyboard input.
final class GameDisplayView: MTKView {
    weak var session: GameSession?
    private static let directTouchID: Int32 = 900
    private var directTouchDown = false

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var windowObservers: [NSObjectProtocol] = []

    // MARK: Drag & drop (the Metal view is what the cursor is over, so it must accept files itself)

    private func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let kind = GameSession.DropKind(fileURLs(sender))
        MainActor.assumeIsolated { session?.dropKind = kind }
        return kind == nil ? [] : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        MainActor.assumeIsolated { session?.dropKind == nil } ? [] : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        MainActor.assumeIsolated { session?.dropKind = nil }
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(sender)
        MainActor.assumeIsolated {
            session?.dropKind = nil
            if !urls.isEmpty { session?.handleDrop(urls) }
        }
        return !urls.isEmpty
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        MainActor.assumeIsolated { session?.dropKind = nil }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerForDraggedTypes([.fileURL])
        window?.makeFirstResponder(self)
        applyFrameRate()
        updateHiddenPump()
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers = []
        if let w = window {
            let nc = NotificationCenter.default
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.didChangeScreenNotification] {
                windowObservers.append(nc.addObserver(forName: name, object: w, queue: .main) { [weak self] _ in self?.applyFrameRate() })
            }
            windowObservers.append(nc.addObserver(forName: NSWindow.didMiniaturizeNotification, object: w, queue: .main) { [weak self] _ in
                if Pref.d.bool(forKey: Pref.pauseWhenMinimized) { MainActor.assumeIsolated { self?.session?.setVMPaused(true) } }
            })
            windowObservers.append(nc.addObserver(forName: NSWindow.didDeminiaturizeNotification, object: w, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.session?.setVMPaused(false) }
            })
            // Switching to another app is the real focus loss: lift everything.
            windowObservers.append(nc.addObserver(forName: NSWindow.didResignKeyNotification, object: w, queue: .main) { [weak self] _ in
                self?.unlockPointer()
                MainActor.assumeIsolated { self?.session?.focusLost("window resigned key") }
            })
            windowObservers.append(nc.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: w, queue: .main) { [weak self] _ in
                self?.updateHiddenPump()
            })
            windowObservers.append(nc.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.applyFrameRate()
            })
            // Full-screen animation: the view changes size every frame. Keep the drawable
            // (the layer scales it meanwhile) and resize once at the end, instead of
            // reallocating 2560x1440 surfaces per animation frame (a 200+ ms hitch).
            for name in [NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification] {
                windowObservers.append(nc.addObserver(forName: name, object: w, queue: .main) { [weak self] _ in self?.transitioning = true })
            }
            for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
                windowObservers.append(nc.addObserver(forName: name, object: w, queue: .main) { [weak self] _ in
                    self?.transitioning = false
                    self?.updateDrawableSize()
                })
            }
        }
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved], owner: self))
    }

    /// MTKView stops drawing while the window is not visible; keep keymap timers,
    /// operation replay and screen recording running at 60 Hz without it.
    private var hiddenPump: Timer?

    private func updateHiddenPump() {
        let visible = window?.occlusionState.contains(.visible) ?? false
        if visible {
            hiddenPump?.invalidate()
            hiddenPump = nil
        } else if hiddenPump == nil, let r = session?.renderer {
            let t = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in r.pumpOffscreen() }
            RunLoop.main.add(t, forMode: .common)
            hiddenPump = t
        }
    }

    /// Inside a full-screen transition or a live window resize (see updateDrawableSize).
    private var transitioning = false

    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        transitioning = true
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        transitioning = false
        updateDrawableSize()
    }

    override func layout() {
        super.layout()
        updateDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    /// Never draw more pixels than the guest has. When the window is larger than the
    /// guest picture, we draw at the guest's own resolution and the system compositor
    /// does the (same bilinear) upscale it would otherwise be us doing: identical
    /// image, but a 6K full screen writes 2560×1440 instead of 6016×3384 per frame,
    /// which measurably freed memory bandwidth for the game (60.9 → 64.4 fps).
    func updateDrawableSize() {
        guard let s = session, !transitioning else { return }
        let scale = window?.backingScaleFactor ?? layer?.contentsScale ?? 2
        let px = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        guard px.width > 0, px.height > 0 else { return }
        let fit = min(px.width / CGFloat(s.instance.width), px.height / CGFloat(s.instance.height))
        let k = fit > 1 ? 1 / fit : 1
        let size = CGSize(width: (px.width * k).rounded(), height: (px.height * k).rounded())
        if drawableSize != size { drawableSize = size }
    }

    /// Screen refresh (ProMotion 120) capped by settings; 后台自动降帧 when unfocused.
    func applyFrameRate() {
        let screenMax = window?.screen?.maximumFramesPerSecond ?? 120
        let cap = Pref.d.integer(forKey: Pref.maxFPS)
        var fps = cap > 0 ? min(cap, screenMax) : screenMax
        let bg = Pref.d.integer(forKey: Pref.backgroundFPS)
        if bg > 0, let w = window, !w.isKeyWindow { fps = min(fps, bg) }
        if preferredFramesPerSecond != fps { preferredFramesPerSecond = fps }
    }

    override func resignFirstResponder() -> Bool {
        let editing = MainActor.assumeIsolated { session?.editing != nil }
        if !editing, let w = window, w.isKeyWindow {
            // Something else in this window grabbed focus (SwiftUI overlay refresh,
            // toolbar): keep every finger down and take focus straight back.
            InputLog.write("focus taken inside window; reclaimed")
            DispatchQueue.main.async { [weak self] in
                guard let self, let w = self.window, w.isKeyWindow,
                      MainActor.assumeIsolated({ self.session?.editing == nil }) else { return }
                if !(w.firstResponder is NSTextView) { w.makeFirstResponder(self) }
            }
            return super.resignFirstResponder()
        }
        unlockPointer()
        MainActor.assumeIsolated { session?.focusLost("lost first responder") }
        return super.resignFirstResponder()
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        guard let s = session else { return }
        if event.isARepeat { return }
        let b = KolibriCore.Binding.key(event.keyCode)
        if s.inputActive, s.keymap.aimToggle == b {
            s.pointerLocked ? unlockPointer() : lockPointer()
            return
        }
        if s.isMapped(b) { s.handle(binding: b, down: true) }
        else if s.passKeyboard { s.sendKey(event.keyCode, down: true) }
    }

    override func keyUp(with event: NSEvent) {
        guard let s = session else { return }
        let b = KolibriCore.Binding.key(event.keyCode)
        if s.keymap.aimToggle == b { return }
        if s.isMapped(b) { s.handle(binding: b, down: false) }
        else if s.passKeyboard { s.sendKey(event.keyCode, down: false) }
    }

    override func flagsChanged(with event: NSEvent) {
        // Modifier keys can be bound too (e.g. Shift = sprint).
        guard let s = session else { return }
        let b = KolibriCore.Binding.key(event.keyCode)
        let down = Self.isModifierDown(event)
        if s.isMapped(b) { s.handle(binding: b, down: down) }
    }

    private static func isModifierDown(_ e: NSEvent) -> Bool {
        switch Int(e.keyCode) {
        case 56, 60: return e.modifierFlags.contains(.shift)
        case 59, 62: return e.modifierFlags.contains(.control)
        case 58, 61: return e.modifierFlags.contains(.option)
        case 55, 54: return e.modifierFlags.contains(.command)
        default: return false
        }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) { button(0, down: true, event) }
    override func mouseUp(with event: NSEvent) { button(0, down: false, event) }
    override func rightMouseDown(with event: NSEvent) { button(1, down: true, event) }
    override func rightMouseUp(with event: NSEvent) { button(1, down: false, event) }
    override func otherMouseDown(with event: NSEvent) { button(event.buttonNumber, down: true, event) }
    override func otherMouseUp(with event: NSEvent) { button(event.buttonNumber, down: false, event) }

    private func button(_ n: Int, down: Bool, _ event: NSEvent) {
        guard let s = session else { return }
        let b = KolibriCore.Binding.mouse(n)
        if s.isMapped(b) && (s.pointerLocked || n != 0) {
            s.handle(binding: b, down: down)
        } else if n == 0, s.passMouse || !down {
            directTouch(event, down: down)
        }
    }

    override func mouseDragged(with event: NSEvent) { moved(event) }
    override func rightMouseDragged(with event: NSEvent) { moved(event) }
    override func otherMouseDragged(with event: NSEvent) { moved(event) }
    override func mouseMoved(with event: NSEvent) { moved(event) }

    private func moved(_ event: NSEvent) {
        guard let s = session else { return }
        if s.pointerLocked {
            s.mouseDelta(dx: Double(event.deltaX), dy: Double(event.deltaY))
            return
        }
        if let g = guestPoint(event) {
            s.pointerMoved(NPoint(Double(g.0) / Double(s.instance.width), Double(g.1) / Double(s.instance.height)))
        }
        if s.keymaps.capturesMouse {
            // 观察键 / fire-and-turn / skill steering work without pointer lock too.
            s.mouseDelta(dx: Double(event.deltaX), dy: Double(event.deltaY))
        } else if directTouchDown {
            directTouch(event, down: true)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard let s = session else { return }
        // 滚轮上 / 滚轮下 bound to a key: one notch = one press.
        if !event.hasPreciseScrollingDeltas, event.scrollingDeltaY != 0 {
            let b = KolibriCore.Binding.mouse(event.scrollingDeltaY > 0 ? KeyNames.wheelUp : KeyNames.wheelDown)
            if s.isMapped(b) {
                s.handle(binding: b, down: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { s.handle(binding: b, down: false) }
                return
            }
        }
        if event.hasPreciseScrollingDeltas {
            trackpadScroll(event, s)
        } else {
            // Classic wheel: one notch = 120 units in the emulator's wheel protocol.
            if event.scrollingDeltaX != 0 { s.sendWheel(dx: Int32(event.scrollingDeltaX * 120), dy: 0) }
            if event.scrollingDeltaY != 0 { s.wheel(notches: Double(event.scrollingDeltaY)) }
        }
    }

    override func magnify(with event: NSEvent) {
        guard let s = session, s.magnify(Double(event.magnification)) else { return super.magnify(with: event) }
    }

    /// Two-finger trackpad scroll becomes a one-finger drag, which every Android
    /// surface understands (lists, launcher pages, games). Momentum events are
    /// ignored: Android computes its own fling from the release velocity.
    private static let scrollTouchID: Int32 = 901
    private var scrollFinger: CGPoint?

    private func trackpadScroll(_ event: NSEvent, _ s: GameSession) {
        if !event.momentumPhase.isEmpty { return }
        if s.inputActive, s.keymap.wheelZoom != nil {
            // Scheme uses wheel zoom: a two-finger swipe zooms like a wheel would.
            if event.phase.contains(.changed) { s.wheel(notches: Double(event.scrollingDeltaY) / 12) }
            return
        }
        let r = s.renderer.contentRect
        guard r.width > 0 else { return }
        let scale = CGFloat(s.instance.width) / r.width            // guest px per view point
        // With natural scrolling the delta already follows the fingers.
        let sign: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1

        if event.phase.contains(.began) || (scrollFinger == nil && event.phase.contains(.changed)) {
            let start = guestPoint(event).map { CGPoint(x: CGFloat($0.0), y: CGFloat($0.1)) }
                ?? CGPoint(x: CGFloat(s.instance.width) / 2, y: CGFloat(s.instance.height) / 2)
            scrollFinger = start
            s.send( [TouchPoint(id: Self.scrollTouchID, x: Int32(start.x), y: Int32(start.y), down: true)])
        }
        guard var f = scrollFinger else { return }
        if event.phase.contains(.changed) {
            f.x = min(max(f.x + sign * event.scrollingDeltaX * scale, 0), CGFloat(s.instance.width - 1))
            f.y = min(max(f.y + sign * event.scrollingDeltaY * scale, 0), CGFloat(s.instance.height - 1))
            scrollFinger = f
            s.send( [TouchPoint(id: Self.scrollTouchID, x: Int32(f.x), y: Int32(f.y), down: true)])
        }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            s.send( [TouchPoint(id: Self.scrollTouchID, x: Int32(f.x), y: Int32(f.y), down: false)])
            scrollFinger = nil
        }
    }

    /// Plain clicking/dragging = a real finger at the cursor (menus, launcher, UI).
    private func directTouch(_ event: NSEvent, down: Bool) {
        guard let s = session, let g = guestPoint(event) else { return }
        directTouchDown = down
        s.send( [TouchPoint(id: Self.directTouchID, x: g.0, y: g.1, down: down)])
    }

    private func guestPoint(_ event: NSEvent) -> (Int32, Int32)? {
        guard let s = session else { return nil }
        let p = convert(event.locationInWindow, from: nil)
        let r = s.renderer.contentRect
        guard r.width > 0 else { return nil }
        let nx = (p.x - r.minX) / r.width
        let ny = 1 - (p.y - r.minY) / r.height     // AppKit y is up, guest y is down
        guard (0...1).contains(nx), (0...1).contains(ny) else { return nil }
        return (Int32(nx * CGFloat(s.instance.width)), Int32(ny * CGFloat(s.instance.height)))
    }

    // MARK: Pointer lock (mouse-look)

    func lockPointer() {
        guard let s = session, !s.pointerLocked else { return }
        CGAssociateMouseAndMouseCursorPosition(0)
        NSCursor.hide()
        s.pointerLocked = true
        s.show(L("鼠标已锁定，按 \(s.keymap.aimToggle.map(KeyNames.name) ?? "`") 键解锁"))
    }

    func unlockPointer() {
        guard let s = session, s.pointerLocked else { return }
        CGAssociateMouseAndMouseCursorPosition(1)
        NSCursor.unhide()
        s.pointerLocked = false
        s.pointerUnlocked()
    }
}

struct GameDisplay: NSViewRepresentable {
    let session: GameSession

    func makeNSView(context: Context) -> GameDisplayView {
        let v = GameDisplayView(frame: .zero, device: session.renderer.device)
        v.colorPixelFormat = .bgra8Unorm
        v.framebufferOnly = true
        v.autoResizeDrawable = false    // sized by updateDrawableSize()
        v.isPaused = false
        v.enableSetNeedsDisplay = false
        v.delegate = session.renderer
        v.session = session
        if let layer = v.layer as? CAMetalLayer {
            layer.magnificationFilter = .linear
            layer.minificationFilter = .linear
            layer.displaySyncEnabled = true
            // Three drawables: with two, full screen on a 120 Hz display starved (the window
            // server holds one longer there), nextDrawable blocked the main thread and only
            // every 4th refresh showed a frame: 30 fps on screen from a 60+ fps game.
            layer.maximumDrawableCount = 3
        }
        return v
    }

    func updateNSView(_ v: GameDisplayView, context: Context) {
        v.session = session
        v.updateDrawableSize()
    }
}
