import AppKit
import QuartzCore
import OSLog
import SwiftUI
import FanCoolCore

/// The compositor rotates the bitmap; SwiftUI's TimelineView and redraw cadence are not involved.
@MainActor
final class FanRotationView: NSView {
    private let rotorLayer = CALayer()
    private let template: Bool
    private let role: String
    private var spinning = false
    private static let animationKey = "fancool.rotor.rotation"
    private static let logger = Logger(subsystem: HelperIdentity.appIdentifier, category: "rotor-animation")

    init(frame: NSRect, template: Bool = false, role: String = "panel") {
        self.template = template
        self.role = role
        super.init(frame: frame)
        wantsLayer = true
        rotorLayer.contentsGravity = .resizeAspect
        rotorLayer.minificationFilter = .trilinear
        rotorLayer.magnificationFilter = .linear
        layer?.addSublayer(rotorLayer)
        refreshImage()
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
    // Status-item input always reaches the original NSStatusBarButton.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let side = min(bounds.width, bounds.height)
        rotorLayer.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        rotorLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        rotorLayer.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshImage()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { rotorLayer.removeAnimation(forKey: Self.animationKey) }
        else if spinning { installAnimationIfNeeded() }
    }
    private func refreshImage() {
        guard let source = FanRotorAsset.cgImage else { return }
        if !template {
            rotorLayer.contents = source
            return
        }
        // Rasterize the alpha silhouette once per appearance, not once per animation frame.
        let pixels = 72
        guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                                      bytesPerRow: pixels * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        let rectangle = CGRect(x: 0, y: 0, width: pixels, height: pixels)
        context.draw(source, in: rectangle)
        var tint = NSColor.labelColor.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { tint = NSColor.labelColor.cgColor }
        context.setBlendMode(.sourceIn)
        context.setFillColor(tint)
        context.fill(rectangle)
        rotorLayer.contents = context.makeImage()
    }
    func setSpinning(_ value: Bool) {
        spinning = value
        if value { installAnimationIfNeeded() }
        else { rotorLayer.removeAnimation(forKey: Self.animationKey) }
    }
    private func installAnimationIfNeeded() {
        guard rotorLayer.contents != nil, rotorLayer.animation(forKey: Self.animationKey) == nil else { return }
        let animation = CABasicAnimation(keyPath: "transform.rotation.z")
        animation.fromValue = 0.0
        animation.toValue = Double.pi * 2
        animation.duration = 3.2
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.beginTime = CACurrentMediaTime()
        rotorLayer.add(animation, forKey: Self.animationKey)
        sampleVisibleAnimation(beginTime: animation.beginTime)
    }
    var rotationAnimation: CABasicAnimation? { rotorLayer.animation(forKey: Self.animationKey) as? CABasicAnimation }
    var hasRotorContents: Bool { layer != nil && rotorLayer.superlayer === layer && rotorLayer.contents != nil }
    private func sampleVisibleAnimation(beginTime: CFTimeInterval) {
        // Local diagnostic evidence of presentation-layer movement, without recording the screen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.window?.isVisible == true, self.rotationAnimation?.beginTime == beginTime,
                  let first = self.rotorLayer.presentation()?.transform else { return }
            let angle = atan2(first.m12, first.m11)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self, self.window?.isVisible == true, self.rotationAnimation?.beginTime == beginTime,
                      let second = self.rotorLayer.presentation()?.transform else { return }
                let delta = Double(abs(atan2(second.m12, second.m11) - angle))
                Self.logger.notice("Rotor presentation role=\(self.role, privacy: .public) advanced=\(delta > 0.01, privacy: .public) delta=\(delta, privacy: .public)")
            }
        }
    }
}

struct NativeRotatingFan: NSViewRepresentable {
    let spinning: Bool
    var role = "panel"
    func makeNSView(context: Context) -> FanRotationView {
        FanRotationView(frame: .zero, role: role)
    }
    func updateNSView(_ view: FanRotationView, context: Context) { view.setSpinning(spinning) }
    static func dismantleNSView(_ view: FanRotationView, coordinator: ()) { view.setSpinning(false) }
}
