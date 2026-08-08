//
//  KeyboardMonitor.swift
//  DisplayMixer
//
//  全局拦截 macOS 媒体键（亮度 F1/F2、音量 F11/F12、静音 F10），路由到显示器。
//
//  设计（严格参照 MonitorControl 依赖的 MediaKeyTap 成熟方案，绝不使用 HID 层 tap）：
//   - 仅一个会话层 tap：.cgSessionEventTap + .headInsertEventTap。
//     会话层 tap 在辅助功能授权后，能收到其他进程产生的按键；且被系统停用时事件会
//     正常放行，绝不吞键、绝不卡死（上一版用 .cghidEventTap 才导致死机，已彻底移除）。
//   - 同时监听两条事件流，覆盖用户「标准功能键 开/关」两种键盘设置：
//       A) 系统媒体键（kCGEventSystemDefined / aux，type=14，subtype=8）：
//          亮度 2/3、音量 0/1、静音 5（兼容旧约定 7）。与 MediaKeyTap 解析完全一致。
//       B) 标准功能键（kCGEventKeyDown/KeyUp，type=10/11）：
//          F1=122/F2=120、F14=107/F15=113（亮度），F10=109（静音），F11=103/F12=111（音量）。
//          当「将 F1、F2 等用作标准功能键」开启时，F1/F2 以此形式送达，亮度由此接管。
//   - aux 解析严格照抄 NSEventExtensions：
//          keycode = (data1 & 0xffff0000) >> 16
//          keyPressed = ((data1 & 0x0000ffff & 0xff00) >> 8) == 0xa
//          keyRepeat = (data1 & 0x0000ffff & 0x1) == 0x1
//   - 回调中对「按下」动作、对「抬起」仅拦截不动作，配合 0.12s 同语义去重，杜绝双击。
//   - 辅助功能被收回时 tap 被系统停用（回调收到 .tapDisabledByUserInput）：事件照常放行，
//     仅暂停拦截；授权恢复后由轮询一次性重建 tap，不做危险的重启循环。
//

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

final class KeyboardMonitor {
    static let shared = KeyboardMonitor()

    /// 各媒体键回调：返回 true 表示已处理并「吃掉」该事件，false 表示放行给系统。
    /// true = Shift+Option+功能键，使用用户设置的按键步进；false = 允许精细步进。
    var onBrightnessUp: ((Bool) -> Bool)?
    var onBrightnessDown: ((Bool) -> Bool)?
    var onVolumeUp: ((Bool) -> Bool)?
    var onVolumeDown: ((Bool) -> Bool)?
    var onMuteToggle: ((Bool) -> Bool)?

    // 单一会话层 tap
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    // CGEventType 原始值（SDK 27 已移除部分枚举成员，用常量避免编译/匹配歧义）
    private let kSysDefined: UInt32 = 14
    private let kKeyDown: UInt32 = 10
    private let kKeyUp: UInt32 = 11

    // aux 媒体键的 subtype（NX_SUBTYPE_AUX_CONTROL_BUTTONS）
    private let auxSubtype: Int = 8

    // aux keyCode（NX_KEYTYPE_*）：亮度 2/3、音量 0/1、静音 5（兼容旧约定 7）
    private let auxBrightnessUp = 2
    private let auxBrightnessDown = 3
    private let auxSoundUp = 0
    private let auxSoundDown = 1
    private let auxMute: [Int] = [5, 7]

    // 标准 keyDown 的 keyCode（物理键）
    private let kdF1 = 122   // 亮度 ↓
    private let kdF2 = 120   // 亮度 ↑
    private let kdF10 = 109  // 静音
    private let kdF11 = 103  // 音量 ↓
    private let kdF12 = 111  // 音量 ↑
    private let kdF14 = 107  // 亮度 ↓（部分机型 F1/F2 映射）
    private let kdF15 = 113  // 亮度 ↑

    private init() {}

    /// 上次解码到的媒体键/功能键事件（语义层，供菜单调试读数）。
    static var lastEventInfo: String = "（暂无）"
    /// 最近一次到达 tap 的原始事件（含未识别的 F1/F2，用于「按了没反应」定位）。
    static var lastRawInfo: String = "（暂无）"

    var isEnabled: Bool {
        tap != nil && CGEvent.tapIsEnabled(tap: tap!)
    }

    private var desired = false
    private var trustPoll: Timer?
    private var revocationCleanupScheduled = false
    private var seenCodes: Set<Int> = []
    private var lastSemantic: String = ""
    private var lastActedTS: CFAbsoluteTime = 0

    // MARK: - 开关

    /// 开启/关闭键盘拦截。开启时若无辅助功能授权，会弹系统提示并轮询，授权后一次性建 tap。
    func setEnabled(_ enabled: Bool) {
        desired = enabled
        if enabled {
            if AXIsProcessTrusted() {
                createTapIfNeeded()
            } else {
                promptAX()
                startTrustPoll()
            }
        } else {
            stop()
        }
    }

    private func promptAX() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let opts = [key: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
        NSLog("DisplayMixer: 需要「辅助功能」权限拦截媒体键。请到「系统设置 → 隐私与安全性 → 辅助功能」允许 DisplayMixer，授权后自动生效。")
    }

    /// 若尚未建 tap 或 tap 已被系统停用，则（重建）一个会话层 tap。
    private func createTapIfNeeded() {
        if let tap, CGEvent.tapIsEnabled(tap: tap) { return }
        stop()
        createTap()
    }

    private func createTap() {
        let mask = CGEventMask(
            (UInt64(1) << UInt64(kSysDefined))
                | (UInt64(1) << UInt64(kKeyDown))
                | (UInt64(1) << UInt64(kKeyUp))
        )
        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        guard let newTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                let mon = Unmanaged<KeyboardMonitor>.fromOpaque(refcon!).takeUnretainedValue()
                return mon.handle(type: type, event: event)
            },
            userInfo: refcon
        ) else {
            NSLog("DisplayMixer: 无法创建键盘事件 tap（可能缺少辅助功能权限，或 App 处于沙盒）")
            return
        }
        guard let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0) else {
            NSLog("DisplayMixer: 无法为 tap 创建 runloop source")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
        tap = newTap
        source = src
        if CGEvent.tapIsEnabled(tap: newTap) {
            NSLog("DisplayMixer: 键盘拦截 tap（会话层）已生效。")
        } else {
            NSLog("DisplayMixer: tap 已创建但被系统停用——请到「辅助功能」授权。")
        }
    }

    /// 仅在「尚未建好 tap 且现在已授权」时重建；已生效则不动（避免重启循环）。
    private func startTrustPoll() {
        guard trustPoll == nil else { return }
        trustPoll?.invalidate()
        trustPoll = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.desired else { return }
                if AXIsProcessTrusted() {
                    if self.tap == nil || !CGEvent.tapIsEnabled(tap: self.tap!) {
                        self.createTapIfNeeded()
                    }
                    if self.tap != nil, CGEvent.tapIsEnabled(tap: self.tap!) {
                        self.trustPoll?.invalidate()
                        self.trustPoll = nil
                    }
                }
            }
        }
    }

    func stop() {
        trustPoll?.invalidate()
        trustPoll = nil
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        tap = nil
        source = nil
    }

    // MARK: - 统一回调

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Tap 被系统停用或权限刚刚被撤回时，最高优先级是放行事件。
        // 不能继续走媒体键分支，否则会把键盘事件留在本 App 中。
        if type == .tapDisabledByUserInput {
            scheduleAccessibilityCleanup()
            return Unmanaged.passUnretained(event)
        }
        if type == .tapDisabledByTimeout {
            if AXIsProcessTrusted(), let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            else { scheduleAccessibilityCleanup() }
            return Unmanaged.passUnretained(event)
        }

        // 权限撤回后系统不一定立刻发送 tapDisabledByUserInput；在每个回调入口
        // 再检查一次，确保撤权窗口内也绝不消费任何输入事件。
        guard AXIsProcessTrusted() else {
            scheduleAccessibilityCleanup()
            return Unmanaged.passUnretained(event)
        }

        // 全量原始日志：记录每个到达 tap 的事件，定位 F1/F2 亮度键到底以什么形式送达。
        logRaw(type: type, event: event)

        if type.rawValue == kSysDefined {
            return handleSystemDefined(event: event)
        }
        if type.rawValue == kKeyDown || type.rawValue == kKeyUp {
            return handleKeyDown(type: type, event: event)
        }
        return Unmanaged.passUnretained(event)
    }

    /// 在主 RunLoop 上拆除已经失去授权的 tap，并保留用户的“启用键盘控制”偏好。
    /// 授权恢复后由现有轮询重新创建；清理只排队一次，避免权限撤回期间反复重建。
    private func scheduleAccessibilityCleanup() {
        guard !revocationCleanupScheduled else { return }
        revocationCleanupScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.revocationCleanupScheduled = false
            guard self.desired else {
                self.stop()
                return
            }
            guard !AXIsProcessTrusted() else {
                self.createTapIfNeeded()
                return
            }
            self.stop()
            self.startTrustPoll()
        }
    }

    private func logRaw(type: CGEventType, event: CGEvent) {
        var code = -1
        var sub = -1
        if type.rawValue == kKeyDown || type.rawValue == kKeyUp {
            code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        } else if type.rawValue == kSysDefined {
            if let ns = NSEvent(cgEvent: event) {
                sub = Int(ns.subtype.rawValue)
                let d = UInt32(bitPattern: Int32(ns.data1))
                code = Int((d & 0xFFFF_0000) >> 16)
            }
        }
        let t = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        Self.lastRawInfo = "[\(type.rawValue)] code=\(code) sub=\(sub) \(t)"
    }

    // MARK: - 标准功能键通道（覆盖「标准功能键开启」时的 F1/F2 等）

    private func handleKeyDown(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let isDown = (type.rawValue == kKeyDown)

        if (90...135).contains(keyCode) {
            seenCodes.insert(keyCode)
        }

        guard let semantic = semanticForKeyDown(keyCode) else {
            return Unmanaged.passUnretained(event) // 其它键原样放行
        }

        guard desired else {
            updateDebug(source: "key", code: keyCode, state: isDown ? 0x0A : 0x0B, note: "（未启用，已放行）")
            return Unmanaged.passUnretained(event)
        }

        if !isDown {
            updateDebug(source: "key", code: keyCode, state: 0x0B, note: "（抬起，已拦截）")
            return nil // 吃掉抬起，避免系统重复响应
        }

        let useConfiguredStep = event.flags.contains(.maskShift) && event.flags.contains(.maskAlternate)
        let acted = perform(semantic: semantic, source: "key", code: keyCode, state: 0x0A, useConfiguredStep: useConfiguredStep)
        return acted == nil ? Unmanaged.passUnretained(event) : nil
    }

    private func semanticForKeyDown(_ code: Int) -> String? {
        switch code {
        case kdF1, kdF14: return "brightDown"
        case kdF2, kdF15: return "brightUp"
        case kdF10: return "mute"
        case kdF11: return "volDown"
        case kdF12: return "volUp"
        default: return nil
        }
    }

    // MARK: - aux 媒体键通道（覆盖「标准功能键关闭」时的音量/静音/亮度）

    private func handleSystemDefined(event: CGEvent) -> Unmanaged<CGEvent>? {
        guard let nsEvent = NSEvent(cgEvent: event) else {
            return Unmanaged.passUnretained(event)
        }
        let subtype = nsEvent.subtype.rawValue
        let data1 = nsEvent.data1
        let data1u = UInt32(bitPattern: Int32(data1))
        let keyCode = Int((data1u & 0xFFFF_0000) >> 16)
        let keyFlags = data1u & 0x0000_FFFF
        let keyState = (keyFlags & 0xFF00) >> 8

        seenCodes.insert(keyCode)
        updateDebug(source: "aux", code: keyCode, state: keyState, note: "sub=\(subtype)")

        guard subtype == auxSubtype else {
            return Unmanaged.passUnretained(event)
        }
        guard let semantic = semanticForAux(keyCode) else {
            // 识别为媒体键但本 App 不接管：吃掉，屏蔽原生 OSD。
            return nil
        }
        guard desired else {
            updateDebug(source: "aux", code: keyCode, state: keyState, note: "（未启用，已放行）")
            return Unmanaged.passUnretained(event)
        }
        guard keyState == 0x0A else {
            updateDebug(source: "aux", code: keyCode, state: keyState, note: "（抬起，已拦截）")
            return nil
        }
        let useConfiguredStep = event.flags.contains(.maskShift) && event.flags.contains(.maskAlternate)
        let acted = perform(semantic: semantic, source: "aux", code: keyCode, state: keyState, useConfiguredStep: useConfiguredStep)
        return acted == nil ? Unmanaged.passUnretained(event) : nil
    }

    private func semanticForAux(_ code: Int) -> String? {
        switch code {
        case auxBrightnessUp: return "brightUp"
        case auxBrightnessDown: return "brightDown"
        case auxSoundUp: return "volUp"
        case auxSoundDown: return "volDown"
        case auxMute[0], auxMute[1]: return "mute"
        default: return nil
        }
    }

    // MARK: - 动作分发（共用，语义去重）

    private func perform(semantic: String, source: String, code: Int, state: UInt32, useConfiguredStep: Bool) -> String? {
        let now = CFAbsoluteTimeGetCurrent()
        if semantic == lastSemantic, now - lastActedTS < 0.12 {
            updateDebug(source: source, code: code, state: state, note: "（去重）")
            return semantic
        }
        let acted: Bool
        switch semantic {
        case "brightUp": acted = onBrightnessUp?(useConfiguredStep) ?? false
        case "brightDown": acted = onBrightnessDown?(useConfiguredStep) ?? false
        case "volUp": acted = onVolumeUp?(useConfiguredStep) ?? false
        case "volDown": acted = onVolumeDown?(useConfiguredStep) ?? false
        case "mute": acted = onMuteToggle?(useConfiguredStep) ?? false
        default: acted = false
        }
        if acted {
            lastSemantic = semantic
            lastActedTS = now
        }
        updateDebug(source: source, code: code, state: state, note: acted ? "→ 已动作" : "（未映射/无目标）")
        return acted ? semantic : nil
    }

    private func updateDebug(source: String, code: Int, state: UInt32, note: String) {
        let codes = seenCodes.sorted().map(String.init).joined(separator: ",")
        let t = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        Self.lastEventInfo = "[\(source)] code=\(code) state=\(state) \(note) | 已见:\(codes) \(t)"
    }
}
