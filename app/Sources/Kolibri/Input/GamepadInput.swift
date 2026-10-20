import GameController
import KolibriCore

/// Feeds GameController.framework pads into the keymap engine: sticks drive
/// joystick/aim controls, buttons become `.pad(name)` bindings.
final class GamepadInput {
    var onButton: ((Binding, Bool) -> Void)?
    var onStick: ((String, Double, Double) -> Void)?
    var onConnection: ((String, Bool) -> Void)?
    private var observers: [NSObjectProtocol] = []

    init() {
        GCController.shouldMonitorBackgroundEvents = false
        observers.append(NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] n in
            if let c = n.object as? GCController {
                self?.attach(c)
                self?.onConnection?(c.vendorName ?? L("手柄"), true)
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] n in
            if let c = n.object as? GCController { self?.onConnection?(c.vendorName ?? L("手柄"), false) }
        })
        GCController.controllers().forEach(attach)
        GCController.startWirelessControllerDiscovery {}
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    private func attach(_ c: GCController) {
        guard let pad = c.extendedGamepad else { return }
        pad.valueChangedHandler = { [weak self] gp, element in
            guard let self else { return }
            if element === gp.leftThumbstick {
                self.onStick?("left", Double(gp.leftThumbstick.xAxis.value), Double(-gp.leftThumbstick.yAxis.value))
            } else if element === gp.rightThumbstick {
                self.onStick?("right", Double(gp.rightThumbstick.xAxis.value), Double(-gp.rightThumbstick.yAxis.value))
            } else if let b = element as? GCControllerButtonInput, let name = Self.fallbackName(gp, b) ?? b.localizedName {
                self.onButton?(.pad(name), b.isPressed)
            }
        }
    }

    private static func fallbackName(_ gp: GCExtendedGamepad, _ b: GCControllerButtonInput) -> String? {
        switch b {
        case gp.buttonA: return "Button A"
        case gp.buttonB: return "Button B"
        case gp.buttonX: return "Button X"
        case gp.buttonY: return "Button Y"
        case gp.leftShoulder: return "Left Shoulder"
        case gp.rightShoulder: return "Right Shoulder"
        case gp.leftTrigger: return "Left Trigger"
        case gp.rightTrigger: return "Right Trigger"
        default: return nil
        }
    }
}
