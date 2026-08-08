//
//  OSDOverlay.swift
//  DisplayMixer
//
//  自定义的「屏幕浮层」：在屏幕中央弹出一个 Liquid Glass（macOS 26+ 原生玻璃材质）小窗，
//  显示亮度/音量图标与原生连续胶囊进度条，按键调节后短暂出现，约 1.1 秒后淡出消失。
//
//  macOS 27 风格要点：
//   - 用 NSVisualEffectView 的 .glass 材质，把浮窗背后的桌面/窗口实时模糊（液态玻璃质感）。
//   - 1px 白色高光描边 + 柔和投影，模拟玻璃边缘的折射高光。
//   - 图标居中偏左、原生连续胶囊进度条，配淡入淡出动画。
//
//  这是「OSD 显示 = 应用浮层」模式下使用的浮层。在「系统 OSD」模式下不会绘制本浮层
//  （由 macOS 自己的 OSD 负责显示，且键盘事件仍被拦截，不会动系统自己的音量/亮度）。
//

import AppKit
import Foundation

enum OSDKind {
    case brightness
    case volume
}

final class OSDOverlay {
    static let shared = OSDOverlay()

    private var panel: NSPanel?
    private var glassView: NSVisualEffectView?
    private var iconView: NSImageView?
    private var meterView: MeterView?
    private var hideTimer: Timer?
    /// 面板当前是否处于可见状态（淡入后、淡出前）。用于避免每次按键都重新淡入导致闪烁。
    private var isVisible = false
    private let panelSize = NSSize(width: 256, height: 88)

    private init() {}

    func show(kind: OSDKind, level: Double, muted: Bool = false) {
        ensurePanel()
        configure(kind: kind, level: level, muted: muted)
        positionPanel()
        if !isVisible {
            // 首次出现才淡入；已可见时只更新内容与进度条，不再重置 alpha，避免每按一次闪烁。
            panel?.alphaValue = 0
            panel?.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel?.animator().alphaValue = 1
            }
            isVisible = true
        }
        // 每次调用都重置自动隐藏计时器：按住连续调节时浮层常驻，停手 ~1.1s 后才淡出。
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 1.1, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.hide()
            }
        }
    }

    private func hide() {
        guard let panel, isVisible else { return }
        isVisible = false
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.32
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: {
            // 若淡出过程中又有新的 show() 把它重新显示，则不再收起，避免闪烁。
            if !self.isVisible {
                panel.orderOut(nil)
            }
        }
    }

    private func configure(kind: OSDKind, level: Double, muted: Bool) {
        let clamped = max(0, min(1, level))
        // 图标
        let iconName: String
        switch kind {
        case .brightness:
            iconName = "sun.max.fill"
        case .volume:
            if muted { iconName = "speaker.slash.fill" }
            else if clamped <= 0.001 { iconName = "speaker.fill" }
            else if clamped < 0.34 { iconName = "speaker.wave.1.fill" }
            else if clamped < 0.67 { iconName = "speaker.wave.2.fill" }
            else { iconName = "speaker.wave.3.fill" }
        }
        if let img = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 34, weight: .regular, scale: .large)) {
            img.isTemplate = true
            iconView?.image = img
        }
        // 进度条：静音平滑收拢到 0；解除静音时从 0 带轻微回弹弹回原音量；
        // 其余（亮度 / 音量常规调节）逐键即时跳变，贴近原生 macOS OSD 手感。
        guard let meter = meterView else { return }
        if muted {
            meter.animateTo(0, spring: false)
        } else if meter.current < 0.001 && clamped > 0.001 {
            meter.animateTo(clamped, spring: true)
        } else {
            meter.setLevel(clamped)
        }
    }

    private func ensurePanel() {
        guard panel == nil else { return }
        let p = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .screenSaver
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.hasShadow = false // 阴影由容器图层自定义绘制，避免双阴影
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        p.appearance = NSAppearance(named: .aqua)

        // 容器层：负责圆角 + 玻璃高光描边 + 柔和投影
        let container = NSView(frame: NSRect(origin: .zero, size: panelSize))
        container.wantsLayer = true
        if let layer = container.layer {
            layer.isOpaque = false
            layer.backgroundColor = NSColor.clear.cgColor
            layer.cornerRadius = 22
            layer.shadowColor = NSColor.black.cgColor
            layer.shadowOpacity = 0.30
            layer.shadowRadius = 26
            layer.shadowOffset = CGSize(width: 0, height: 10)
            layer.shadowPath = CGPath(
                roundedRect: CGRect(origin: .zero, size: panelSize),
                cornerWidth: 22, cornerHeight: 22, transform: nil
            )
        }

        // 液态玻璃材质层（填充容器，裁切到圆角）
        let glass = NSVisualEffectView(frame: NSRect(origin: .zero, size: panelSize))
        glass.wantsLayer = true
        if let gl = glass.layer {
            gl.cornerRadius = 22
            gl.masksToBounds = true
            // 玻璃边缘高光描边
            gl.borderWidth = 1
            gl.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
        }
        // 注：当前 SDK（macOS 27.0）的 NSVisualEffectView 未暴露 .glass 材质枚举，
        // 因此用系统 HUD/浮层同款的 .hudWindow 暗色磨砂玻璃，再靠白色高光描边 + 投影模拟液态玻璃质感。
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active

        // 图标（左）
        let icon = NSImageView(frame: NSRect(x: 24, y: (panelSize.height - 40) / 2, width: 40, height: 40))
        icon.imageScaling = .scaleProportionallyDown
        icon.contentTintColor = .white
        icon.wantsLayer = true
        icon.layer?.opacity = 0.95

        // 原生连续胶囊进度条（右）
        let meterW: CGFloat = panelSize.width - 84 - 22
        let meter = MeterView(frame: NSRect(x: 84, y: (panelSize.height - 12) / 2, width: meterW, height: 12))

        glass.addSubview(icon)
        glass.addSubview(meter)
        container.addSubview(glass)
        p.contentView = container

        panel = p
        glassView = glass
        iconView = icon
        meterView = meter
    }

    private func positionPanel() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        // 屏幕中上部（与原生 OSD 位置接近）
        let x = visible.midX - panelSize.width / 2
        let y = visible.midY + visible.height * 0.06
        panel?.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

/// 原生风格连续胶囊进度条：半透明描边胶囊 + 白色填充部分。
/// 支持即时设值（亮度 / 音量逐键跳变）与带动画设值（静音收拢 / 解除静音回弹）。
private final class MeterView: NSView {
    /// 用 @objc dynamic + didSet 触发重绘，使 animator() 代理能对它做插值动画。
    @objc dynamic private var animatableLevel: CGFloat = 0 {
        didSet { needsDisplay = true }
    }

    /// 当前展示值（供 OSD 判断是否处于「0」以决定回弹动画）。
    fileprivate var current: CGFloat { animatableLevel }

    /// 即时设置（亮度 / 音量常规调节，逐键跳变）。
    func setLevel(_ v: CGFloat) {
        animatableLevel = max(0, min(1, v))
    }

    /// 带动画设置：spring=true 用回弹缓动（解除静音），否则用 easeOut（静音收拢到 0）。
    func animateTo(_ v: CGFloat, spring: Bool) {
        let target = max(0, min(1, v))
        let timing: CAMediaTimingFunction = spring
            ? CAMediaTimingFunction(controlPoints: Float(0.34), Float(1.45), Float(0.64), Float(1.0))
            : CAMediaTimingFunction(name: .easeOut)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = spring ? 0.5 : 0.32
            ctx.timingFunction = timing
            animator().animatableLevel = target
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let level = animatableLevel
        let h = bounds.height
        let radius = h / 2
        let track = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)

        // 轨道（半透明白）
        NSColor.white.withAlphaComponent(0.16).setFill()
        track.fill()

        // 填充部分（裁切到圆角轨道内）
        let fillW = bounds.width * level
        if fillW > 1 {
            NSGraphicsContext.saveGraphicsState()
            track.setClip()
            NSColor.white.setFill()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: fillW, height: bounds.height)).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}
