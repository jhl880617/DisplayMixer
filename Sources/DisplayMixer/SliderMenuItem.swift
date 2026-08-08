//
//  SliderMenuItem.swift
//  DisplayMixer
//
//  菜单内的自定义视图菜单项：左侧标题 + 中间滑块 + 右侧百分比。
//  用于显示器亮度/音量与各 App 音量。
//  - 通过 onInteraction 在拖拽起止时通知外层，便于刷新菜单时避免打断正在拖动的滑块。
//

import AppKit

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
    var onChanged: ((Double) -> Void)?
    /// true = 开始拖动，false = 结束拖动
    var onInteraction: ((Bool) -> Void)?

    init(
        title: String,
        value: Double,
        minValue: Double = 0,
        maxValue: Double = 1,
        continuous: Bool = false,
        format: @escaping (Double) -> String = { "\(Int(($0 * 100).rounded()))%" },
        onChanged: @escaping (Double) -> Void,
        onInteraction: @escaping (Bool) -> Void = { _ in }
    ) {
        self.titleField = NSTextField(labelWithString: title)
        self.valueField = NSTextField(labelWithString: format(value))
        self.slider = TrackingSlider(value: value, minValue: minValue, maxValue: maxValue, target: nil, action: nil)
        self.format = format
        self.onChanged = onChanged
        self.onInteraction = onInteraction

        super.init(title: title, action: nil, keyEquivalent: "")

        slider.isContinuous = continuous
        slider.controlSize = .small
        slider.target = self
        slider.action = #selector(sliderChanged(_:))
        slider.onBeginDrag = { [weak self] in self?.onInteraction?(true) }
        slider.onEndDrag = { [weak self] in self?.onInteraction?(false) }

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 26))
        titleField.frame = NSRect(x: 10, y: 5, width: 92, height: 16)
        titleField.font = NSFont.systemFont(ofSize: 11)
        titleField.lineBreakMode = .byTruncatingTail

        slider.frame = NSRect(x: 106, y: 3, width: 150, height: 19)

        valueField.frame = NSRect(x: 260, y: 5, width: 34, height: 16)
        valueField.font = NSFont.systemFont(ofSize: 11)
        valueField.alignment = .right

        view.addSubview(titleField)
        view.addSubview(slider)
        view.addSubview(valueField)
        self.view = view
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        let v = sender.doubleValue
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
