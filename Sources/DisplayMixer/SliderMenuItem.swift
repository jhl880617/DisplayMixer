//
//  SliderMenuItem.swift
//  DisplayMixer
//
//  菜单内的自定义视图菜单项：左侧标题 + 中间滑块 + 右侧百分比。
//  用于显示器亮度/音量与各 App 音量。
//  - 通过 onInteraction 在拖拽起止时通知外层，便于刷新菜单时避免打断正在拖动的滑块。
//

import AppKit

private final class DisplayMixerSliderCell: NSSliderCell {
    private let trackColor = NSColor.systemGray.withAlphaComponent(0.2)
    private let fillColor = NSColor.controlAccentColor
    private let knobColor = NSColor.white
    private let strokeColor = NSColor.systemGray.withAlphaComponent(0.5)
    private let inset: CGFloat = 3.5

    override func barRect(flipped: Bool) -> NSRect {
        let bar = super.barRect(flipped: flipped)
        let knob = super.knobRect(flipped: flipped)
        return NSRect(x: bar.origin.x, y: knob.origin.y, width: bar.width, height: knob.height)
            .insetBy(dx: 0, dy: inset)
            .offsetBy(dx: -1.5, dy: -1.5)
    }

    override func drawKnob(_ knobRect: NSRect) {
        // The knob is drawn in drawBar so it stays aligned with the filled bar.
    }

    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let radius = rect.height * 0.5
        let bar = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        trackColor.setFill()
        bar.fill()

        let fraction = CGFloat(max(0, min(1, doubleValue)))
        let filledWidth = (rect.width - rect.height) * fraction + rect.height
        let filledRect = NSRect(x: rect.minX, y: rect.minY, width: filledWidth, height: rect.height)
        let filled = NSBezierPath(roundedRect: filledRect, xRadius: radius, yRadius: radius)
        fillColor.setFill()
        filled.fill()

        let knobX = rect.minX + (rect.width - rect.height) * fraction
        let knob = NSRect(x: knobX, y: rect.minY, width: rect.height, height: rect.height)
            .insetBy(dx: -3, dy: -3)
        knobColor.setFill()
        NSBezierPath(ovalIn: knob).fill()
        strokeColor.setStroke()
        NSBezierPath(ovalIn: knob).stroke()
    }
}

/// 在 mouseDown/mouseUp 时回调的滑块，用于检测「是否正在拖动」。
private final class TrackingSlider: NSSlider {
    var onBeginDrag: (() -> Void)?
    var onEndDrag: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onBeginDrag?()
        super.mouseDown(with: event)
        onEndDrag?()
    }
}

final class SliderMenuItem: NSMenuItem {
    private let slider: TrackingSlider
    private let titleField: NSTextField
    private let valueField: NSTextField
    private let format: (Double) -> String
    private let snapValue: Double?
    private let snapThreshold: Double
    var onChanged: ((Double) -> Void)?
    /// true = 开始拖动，false = 结束拖动
    var onInteraction: ((Bool) -> Void)?

    init(
        title: String,
        value: Double,
        minValue: Double = 0,
        maxValue: Double = 1,
        continuous: Bool = false,
        snapValue: Double? = nil,
        snapThreshold: Double = 0,
        format: @escaping (Double) -> String = { "\(Int(($0 * 100).rounded()))%" },
        onChanged: @escaping (Double) -> Void,
        onInteraction: @escaping (Bool) -> Void = { _ in }
    ) {
        self.titleField = NSTextField(labelWithString: title)
        self.valueField = NSTextField(labelWithString: format(value))
        self.slider = TrackingSlider(value: value, minValue: minValue, maxValue: maxValue, target: nil, action: nil)
        self.format = format
        self.snapValue = snapValue
        self.snapThreshold = snapThreshold
        self.onChanged = onChanged
        self.onInteraction = onInteraction

        super.init(title: title, action: nil, keyEquivalent: "")
        // Custom-view menu items can be auto-disabled by NSMenu because they
        // have no action selector. The slider remains usable in that state,
        // but AppKit draws it as disabled, so keep the whole item explicit.
        isEnabled = true

        slider.isContinuous = continuous
        slider.isEnabled = true
        slider.cell = DisplayMixerSliderCell()
        slider.cell?.isEnabled = true
        // Reapply the value after replacing the cell. NSSliderCell starts at
        // zero when installed, otherwise its knob is drawn at the far left
        // even though NSSlider.doubleValue and the label contain the real value.
        slider.minValue = minValue
        slider.maxValue = maxValue
        slider.doubleValue = value
        slider.controlSize = .small
        slider.target = self
        slider.action = #selector(sliderChanged(_:))
        slider.onBeginDrag = { [weak self] in self?.onInteraction?(true) }
        slider.onEndDrag = { [weak self] in self?.onInteraction?(false) }

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 26))
        titleField.frame = NSRect(x: 10, y: 5, width: 92, height: 16)
        titleField.font = NSFont.systemFont(ofSize: 11)
        titleField.textColor = .labelColor
        titleField.lineBreakMode = .byTruncatingTail

        slider.frame = NSRect(x: 106, y: 3, width: 150, height: 19)

        valueField.frame = NSRect(x: 260, y: 5, width: 34, height: 16)
        valueField.font = NSFont.systemFont(ofSize: 11)
        valueField.textColor = .labelColor
        valueField.alignment = .right

        view.addSubview(titleField)
        view.addSubview(slider)
        view.addSubview(valueField)
        self.view = view
        // Re-assert after assigning the custom view: NSMenu may auto-enable or
        // disable the item while it is being inserted into the menu.
        isEnabled = true
        slider.isEnabled = true
        slider.cell?.isEnabled = true
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        let rawValue = sender.doubleValue
        let v: Double
        if let snapValue, snapThreshold > 0, abs(rawValue - snapValue) <= snapThreshold {
            v = snapValue
            // 让滑块旋钮和显示的百分比一起停在吸附点；超过阈值后可继续离开。
            if sender.doubleValue != snapValue {
                sender.doubleValue = snapValue
            }
        } else {
            v = rawValue
        }
        valueField.stringValue = format(v)
        onChanged?(v)
    }

    /// 将整个菜单项视图宽度设为 `total`，并让滑块从标题一直延伸到右侧百分比标签，
    /// 实现「滑块自适应充满菜单栏」。
    /// 不复建新视图，只调整现有子视图 frame，避免重建菜单时宽度抖动。
    func setTotalWidth(_ total: CGFloat) {
        let w = max(total, 240)
        view?.frame = NSRect(x: 0, y: 0, width: w, height: 26)
        titleField.frame = NSRect(x: 10, y: 5, width: 92, height: 16)

        let valueW: CGFloat = 40
        let sliderX: CGFloat = 106
        let sliderW = w - sliderX - valueW - 8
        slider.frame = NSRect(x: sliderX, y: 3, width: max(sliderW, 40), height: 19)

        valueField.frame = NSRect(x: w - valueW - 4, y: 5, width: valueW, height: 16)
    }
}
