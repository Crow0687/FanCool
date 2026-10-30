import AppKit

/// A native layer-backed rotor shares the same animation implementation as the panel.
@MainActor
final class StatusFanAnimator: NSObject {
    private let rotor: FanRotationView
    private var running = false
    private var screenAwake = true

    init(button: NSStatusBarButton) {
        rotor = FanRotationView(frame: NSRect(x: (button.bounds.width - 18) / 2,
            y: (button.bounds.height - 18) / 2, width: 18, height: 18), template: true, role: "menu-bar")
        super.init()
        button.title = ""
        button.image = nil
        button.toolTip = "FanCool · 左键打开控制面板，右键显示菜单"
        rotor.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        button.addSubview(rotor)
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(updateAnimation), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        center.addObserver(self, selector: #selector(screenSleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(screenWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
    }
    func setRunning(_ value: Bool) { running = value; updateAnimation() }
    @objc private func screenSleep() { screenAwake = false; updateAnimation() }
    @objc private func screenWake() { screenAwake = true; updateAnimation() }
    @objc private func updateAnimation() {
        rotor.setSpinning(running && screenAwake && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }
    func stop() { running = false; rotor.setSpinning(false) }
}
