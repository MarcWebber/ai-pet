import AppKit

@MainActor
final class SoftGlassView: NSVisualEffectView {
    override var isOpaque: Bool {
        false
    }

    init(cornerRadius: CGFloat = 24) {
        super.init(frame: .zero)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.24).cgColor
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        nil
    }
}
