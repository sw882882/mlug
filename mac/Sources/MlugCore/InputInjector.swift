import ApplicationServices
import CoreGraphics
import Foundation

/// Turns tablet pointer events into macOS mouse events on the virtual display.
final class InputInjector {
    private var bounds: () -> CGRect
    private let tabletWidth: Double
    private var leftDown = false
    private var rightDown = false
    private var lastClickTime = Date.distantPast
    private var lastClickPoint = CGPoint.zero
    private var clickCount = 1

    init(bounds: @escaping () -> CGRect, tabletWidth: Int) {
        self.bounds = bounds
        self.tabletWidth = Double(tabletWidth)
    }

    /// Prompts for Accessibility access if needed; events are silently dropped without it.
    @discardableResult
    static func ensureTrusted(prompt: Bool) -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    private func point(_ x: Float, _ y: Float) -> CGPoint {
        let b = bounds()
        let cx = min(max(Double(x), 0), 0.9999), cy = min(max(Double(y), 0), 0.9999)
        return CGPoint(x: b.minX + cx * b.width, y: b.minY + cy * b.height)
    }

    func pointer(action: UInt8, button: UInt8, x: Float, y: Float) {
        let p = point(x, y)
        let isRight = button == 1
        let type: CGEventType
        switch action {
        case 1:
            let now = Date()
            if now.timeIntervalSince(lastClickTime) < NSEventDoubleClickInterval(),
               hypot(p.x - lastClickPoint.x, p.y - lastClickPoint.y) < 6 {
                clickCount += 1
            } else {
                clickCount = 1
            }
            lastClickTime = now
            lastClickPoint = p
            if isRight { rightDown = true; type = .rightMouseDown } else { leftDown = true; type = .leftMouseDown }
        case 2:
            if isRight { rightDown = false; type = .rightMouseUp } else { leftDown = false; type = .leftMouseUp }
        default:
            type = leftDown ? .leftMouseDragged : rightDown ? .rightMouseDragged : .mouseMoved
        }
        let cgButton: CGMouseButton = (isRight || (action == 0 && rightDown && !leftDown)) ? .right : .left
        guard let ev = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: cgButton) else { return }
        if action != 0 { ev.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount)) }
        ev.post(tap: .cghidEventTap)
    }

    func scroll(dx: Float, dy: Float) {
        // Tablet pixels -> macOS points on the virtual display.
        let scale = bounds().width / tabletWidth
        guard let ev = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                               wheel1: Int32((Double(dy) * scale).rounded()),
                               wheel2: Int32((Double(dx) * scale).rounded()), wheel3: 0) else { return }
        ev.post(tap: .cghidEventTap)
    }
}

private func NSEventDoubleClickInterval() -> TimeInterval {
    UserDefaults.standard.object(forKey: "com.apple.mouse.doubleClickThreshold") as? Double ?? 0.5
}
