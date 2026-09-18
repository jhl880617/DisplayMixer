//
//  AppDelegate.swift
//  DisplayMixer
//
//  菜单栏图标 + 动态下拉菜单：
//   - 每个外接显示器的亮度 / 音量（DDC/CI，解耦于音频路由）
//   - 键盘媒体键（F1/F2 亮度、F10/F11/F12 静音/音量）映射到主显示器 DDC
//   - 键盘媒体键接管：F1/F2 亮度、F10 静音开关、F11/F12 音量
//   - 辅助功能权限入口（键盘控制需要）、开机自启、按键步进
//   - 退出
//
//  设计说明：
//   1. 启动即读取各显示器当前的真实亮度/音量，写入配置并同步菜单图标，保证软件与显示器一致。
//      （不再做「不可读就置灰」的检测——直接控制显示器，读不到就由用户手动拖。）
//   2. 菜单栏图标使用 Apple 系统音量符号，随「主显示器」音量大小变化（含静音斜杠）。
//   3. 音量语义：F11 按到 0 自动进静音；静音状态下按 F10 解除静音并回到 2%。
//   4. 本工具只接管功能按键，不做分应用音量，不申请屏幕录制权限。
//

import AppKit
import ApplicationServices
import CoreAudio
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let ddc = DDCController.shared

    /// 键盘控制的目标显示器（主显示器）；nil 表示无外接屏，键盘事件放行给系统。
    private var primaryDisplay: ExternalDisplay?
    /// 主显示器当前是否静音（仅用于图标与键盘 toggle）。
    private var primaryMuted = false
    /// 主显示器 DDC/CI 能力（启动探测一次，菜单内显示，便于定位亮度/静音失效）。
    private var primaryBrightnessSupported = false
    private var primaryVolumeSupported = false
    private var primaryMuteSupported = false
    /// 主显示器是否可通过 CoreAudio 设备音量控制（选项 B）：有关联音频设备且支持音量。
    private var primaryVolumeCoreAudioSupported = false

    /// 是否正在拖动某个滑块（拖动期间不重建菜单，避免打断）
    private var interacting = false
    /// 菜单当前是否处于打开状态（用于键盘改值时决定是否重建菜单）
    private var menuOpen = false

    private func stepFraction(current: Double, useConfiguredStep: Bool) -> Double {
        if useConfiguredStep || !ConfigStore.shared.fineStepEnabled {
            return Double(ConfigStore.shared.stepPercent) / 100.0
        }
        switch current {
        case ..<0.10: return 0.01
        case ..<0.30: return 0.02
        case ..<0.50: return 0.05
        case ..<0.75: return 0.10
        default: return 0.05
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            // 先放一个默认音量图标，syncDisplayValues 后会按实际音量更新
            if let img = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "DisplayMixer") {
                img.isTemplate = true
                button.image = img
            }
        }
        let menu = NSMenu()
        // SliderMenuItem uses a custom view and has no menu action. Disable
        // AppKit's selector-based auto-enabling so usable sliders are never
        // painted as disabled during menu refreshes.
        menu.autoenablesItems = false
        item.menu = menu
        item.menu?.delegate = self
        statusItem = item

        // 启动即读取显示器真实亮度/音量并同步图标
        Task { @MainActor in
            self.syncDisplayValues()
        }

        // 接键盘回调（在 main run loop 上触发，回调即主线程）
        wireKeyboard()
        if ConfigStore.shared.keyboardControlEnabled() {
            KeyboardMonitor.shared.setEnabled(true)
        }
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        buildMenu(menu)
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
    }

    func menuDidClose(_ menu: NSMenu) {
        menuOpen = false
        interacting = false
    }

    // MARK: - Build menu

    private func buildMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        let header = NSMenuItem(title: "DisplayMixer", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        // ---- 显示器：亮度 / 音量 ----
        let displays = ddc.externalDisplays()
        if displays.isEmpty {
            let none = NSMenuItem(title: "未检测到外接显示器", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        } else {
            for display in displays {
                menu.addItem(displayHeader(display))
                addBrightnessControl(menu, display)
                addVolumeControl(menu, display)
            }
            menu.addItem(.separator())
            menu.addItem(launchAtLoginItem())
            menu.addItem(axRequestItem())
            menu.addItem(resyncItem())
            menu.addItem(axStatusItem())
            menu.addItem(.separator())
            menu.addItem(primaryTargetSubmenu())
            menu.addItem(keyboardToggleItem())
            menu.addItem(stepSubmenu())
        }

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出 DisplayMixer", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        // 让亮度/音量滑块自适应撑满整个菜单宽度（两遍测量：先量出菜单自然宽度，
        // 再把滑块视图设为该宽度并重排滑块，最后再次 sizeToFit 锁定）。
        fitSliderWidths(menu)
    }

    /// 把菜单内所有 SliderMenuItem 的视图宽度设为固定宽度，使滑块从标题一直延伸到百分比。
    /// 固定宽度避免百分比变化导致菜单整体宽度抖动。
    private func fitSliderWidths(_ menu: NSMenu) {
        let target: CGFloat = 400
        for item in menu.items {
            if let sm = item as? SliderMenuItem {
                sm.setTotalWidth(target)
                sm.isEnabled = true
            }
        }
    }

    // MARK: - Display value sync

    /// 启动 / 手动重同步：读取各显示器当前的真实亮度/音量，写入配置、确定主显示器、更新图标。
    /// 不做「置灰」判断——直接控制显示器即可。
    private func syncDisplayValues() {
        let displays = ddc.externalDisplays()
        var chosenPrimary: ExternalDisplay?
        var capsByIdentity: [String: DisplayCapability] = [:]
        for d in displays {
            let cap = ddc.probeCapability(display: d)
            capsByIdentity[d.identity] = cap
            if let bf = cap.brightnessFraction { ConfigStore.shared.setDisplayBrightness(d.identity, bf) }
            if let vf = cap.volumeFraction { ConfigStore.shared.setDisplayVolume(d.identity, vf) }
            if chosenPrimary == nil, cap.brightnessSupported || cap.volumeSupported {
                chosenPrimary = d
            }
        }
        // 主显示器：用户指定优先，否则取第一个有响应的，否则第一个外接屏
        if let cfg = ConfigStore.shared.primaryDisplayIdentity(),
           let d = displays.first(where: { $0.identity == cfg }) {
            primaryDisplay = d
        } else if let c = chosenPrimary {
            primaryDisplay = c
            ConfigStore.shared.setPrimaryDisplayIdentity(c.identity)
        } else {
            primaryDisplay = displays.first
        }
        if let p = primaryDisplay {
            primaryMuted = ConfigStore.shared.displayMuted(for: p.identity)
            if let cap = capsByIdentity[p.identity] {
                primaryBrightnessSupported = cap.brightnessSupported
                primaryVolumeSupported = cap.volumeSupported
            }
            // 选项 B：主显示器音量走 CoreAudio 默认输出设备（即显示器音箱）。
            if let def = CoreAudioVolume.shared.defaultOutputDevice(),
               CoreAudioVolume.shared.supportsVolume(device: def),
               let cav = CoreAudioVolume.shared.getVolumeScalar(device: def) {
                primaryVolumeCoreAudioSupported = true
                // 用显示器真实音量同步滑块初值，避免与 CoreAudio 实际值脱节
                ConfigStore.shared.setDisplayVolume(p.identity, Double(cav))
            } else {
                primaryVolumeCoreAudioSupported = false
            }
            // 静音能力：尝试读一次 VCP 0x8D，能读出即认为支持。
            primaryMuteSupported = ddc.read(p, command: DDCController.muteCommand) != nil
        } else {
            primaryBrightnessSupported = false
            primaryVolumeSupported = false
            primaryMuteSupported = false
        }
        updateStatusIcon()
    }

    // MARK: - Display items

    private func displayHeader(_ display: ExternalDisplay) -> NSMenuItem {
        let item = NSMenuItem(title: "显示器：\(display.name)", action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func addBrightnessControl(_ menu: NSMenu, _ display: ExternalDisplay) {
        let value = ConfigStore.shared.displayBrightness(for: display.identity)
        addSlider(menu, title: "亮度", value: value, continuous: true, snapValue: 0.75, snapThreshold: 0.03) { [weak self] v in
            ConfigStore.shared.setDisplayBrightness(display.identity, v)
            self?.ddc.setBrightness(display: display, fraction: v)
        }
    }

    private func addVolumeControl(_ menu: NSMenu, _ display: ExternalDisplay) {
        let value = ConfigStore.shared.displayVolume(for: display.identity)
        addSlider(menu, title: "音量", value: value, continuous: true) { [weak self] v in
            guard let self else { return }
            self.applyVolumeState(display, fraction: v, muted: v <= Self.muteEpsilon)
        }
    }

    /// 通用滑块菜单项。
    private func addSlider(
        _ menu: NSMenu,
        title: String,
        value: Double,
        continuous: Bool,
        snapValue: Double? = nil,
        snapThreshold: Double = 0,
        onChanged: @escaping (Double) -> Void
    ) {
        let item = SliderMenuItem(
            title: title,
            value: value,
            continuous: continuous,
            snapValue: snapValue,
            snapThreshold: snapThreshold,
            onChanged: onChanged,
            onInteraction: { [weak self] interacting in
                self?.interacting = interacting
            }
        )
        menu.addItem(item)
    }

    private func resyncItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: "重新同步显示器数值",
            action: #selector(resync(_:)),
            keyEquivalent: ""
        )
        item.target = self
        return item
    }

    // MARK: - App and permission settings

    private func launchAtLoginItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: "开机自启",
            action: #selector(toggleLaunchAtLogin(_:)),
            keyEquivalent: ""
        )
        item.state = SMAppService.mainApp.status == .enabled ? .on : .off
        item.target = self
        return item
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("DisplayMixer: 开机自启设置失败：\(error.localizedDescription)")
        }
        rebuild()
    }

    @objc private func resync(_ sender: NSMenuItem) {
        syncDisplayValues()
        rebuild()
    }

    // MARK: - Primary display target

    private func primaryTargetSubmenu() -> NSMenuItem {
        let sub = NSMenu()
        for d in ddc.externalDisplays() {
            let item = NSMenuItem(title: d.name, action: #selector(selectPrimary(_:)), keyEquivalent: "")
            item.representedObject = d.identity
            item.state = (primaryDisplay?.identity == d.identity) ? .on : .off
            item.target = self
            sub.addItem(item)
        }
        let top = NSMenuItem(title: "键盘控制目标显示器", action: nil, keyEquivalent: "")
        top.submenu = sub
        return top
    }

    @objc private func selectPrimary(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        ConfigStore.shared.setPrimaryDisplayIdentity(id)
        primaryDisplay = ddc.externalDisplays().first(where: { $0.identity == id })
        if let p = primaryDisplay {
            primaryMuted = ConfigStore.shared.displayMuted(for: p.identity)
        }
        updateStatusIcon()
        rebuild()
    }

    // MARK: - Keyboard control

    private func keyboardToggleItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: "启用键盘控制",
            action: #selector(toggleKeyboard(_:)),
            keyEquivalent: ""
        )
        item.state = ConfigStore.shared.keyboardControlEnabled() ? .on : .off
        item.target = self
        return item
    }

    @objc private func toggleKeyboard(_ sender: NSMenuItem) {
        let now = !ConfigStore.shared.keyboardControlEnabled()
        ConfigStore.shared.setKeyboardControlEnabled(now)
        sender.state = now ? .on : .off
        if now {
            KeyboardMonitor.shared.setEnabled(true)
        } else {
            KeyboardMonitor.shared.setEnabled(false)
        }
    }

    // MARK: - Step size

    private func stepSubmenu() -> NSMenuItem {
        let sub = NSMenu()
        for pct in [1, 2, 5, 10, 20] {
            let item = NSMenuItem(title: "\(pct)%", action: #selector(selectStep(_:)), keyEquivalent: "")
            item.representedObject = pct
            item.state = (ConfigStore.shared.stepPercent == pct) ? .on : .off
            item.target = self
            sub.addItem(item)
        }
        sub.addItem(.separator())
        let fine = NSMenuItem(
            title: "使用精细步数",
            action: #selector(toggleFineStep(_:)),
            keyEquivalent: ""
        )
        fine.state = ConfigStore.shared.fineStepEnabled ? .on : .off
        fine.target = self
        sub.addItem(fine)
        let top = NSMenuItem(title: "按键步进", action: nil, keyEquivalent: "")
        top.submenu = sub
        return top
    }

    @objc private func selectStep(_ sender: NSMenuItem) {
        guard let pct = sender.representedObject as? Int else { return }
        ConfigStore.shared.stepPercent = pct
        rebuild()
    }

    @objc private func toggleFineStep(_ sender: NSMenuItem) {
        ConfigStore.shared.fineStepEnabled.toggle()
        rebuild()
    }

    private func wireKeyboard() {
        KeyboardMonitor.shared.onBrightnessUp = { [weak self] useConfiguredStep in
            guard let self else { return false }
            // Brightness keys always use the user's configured step. Fine OSD
            // increments remain available for volume and other controls.
            return MainActor.assumeIsolated { self.kbdBrightness(+self.stepFraction(current: self.primaryBrightnessFraction(), useConfiguredStep: true)) }
        }
        KeyboardMonitor.shared.onBrightnessDown = { [weak self] useConfiguredStep in
            guard let self else { return false }
            return MainActor.assumeIsolated { self.kbdBrightness(-self.stepFraction(current: self.primaryBrightnessFraction(), useConfiguredStep: true)) }
        }
        KeyboardMonitor.shared.onVolumeUp = { [weak self] useConfiguredStep in
            guard let self else { return false }
            return MainActor.assumeIsolated { self.kbdVolume(+self.stepFraction(current: self.primaryVolumeFraction(), useConfiguredStep: useConfiguredStep)) }
        }
        KeyboardMonitor.shared.onVolumeDown = { [weak self] useConfiguredStep in
            guard let self else { return false }
            return MainActor.assumeIsolated { self.kbdVolume(-self.stepFraction(current: self.primaryVolumeFraction(), useConfiguredStep: useConfiguredStep)) }
        }
        KeyboardMonitor.shared.onMuteToggle = { [weak self] _ in
            guard let self else { return false }
            return MainActor.assumeIsolated { self.kbdMuteToggle() }
        }
    }

    private func kbdBrightness(_ delta: Double) -> Bool {
        guard let d = keyboardTargetDisplay() else { return false }
        let newV = clamp01(ConfigStore.shared.displayBrightness(for: d.identity) + delta)
        guard ddc.setBrightness(display: d, fraction: newV) else {
            refreshMenuIfVisible()
            return false
        }
        ConfigStore.shared.setDisplayBrightness(d.identity, newV)
        refreshMenuIfVisible()
        return true
    }

    /// Match MonitorControl's default keyboard target: the external display under
    /// the mouse, with the configured primary display as a fallback.
    private func keyboardTargetDisplay() -> ExternalDisplay? {
        let displays = ddc.externalDisplays()
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }),
           let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            if let display = displays.first(where: { $0.id == CGDirectDisplayID(number.uint32Value) }) {
                return display
            }
        }
        return primaryDisplay ?? displays.first
    }

    private func primaryBrightnessFraction() -> Double {
        guard let p = primaryDisplay else { return 0.5 }
        return ConfigStore.shared.displayBrightness(for: p.identity)
    }

    private func kbdVolume(_ delta: Double) -> Bool {
        guard let d = keyboardTargetDisplay() else { return false }
        let stored = ConfigStore.shared.displayVolume(for: d.identity)
        var newV = clamp01(stored + delta)
        // 精度兜底：小步进在底部会有浮点残留，直接按到 0，保证 F11 能到底。
        if delta < 0 && (stored <= 0.015 || newV < Self.muteEpsilon) {
            newV = 0
        }
        // F11 按到 0 自动进静音；F12（newV > 0）自动解除静音。
        // 键盘音量走 CoreAudio 默认输出设备（即显示器音箱）。
        let muted = newV <= Self.muteEpsilon
        if !muted && isEffectivelyMuted(d) && newV < Self.unmuteRestoreFraction {
            // 静音中按 F12：直接回到 2% 保底可听，免得精细步进一次只加 1% 半天没声。
            newV = Self.unmuteRestoreFraction
        }
        applyVolumeState(d, fraction: newV, muted: muted)
        return true
    }

    private func kbdMuteToggle() -> Bool {
        guard let d = keyboardTargetDisplay() else { return false }
        if isEffectivelyMuted(d) {
            // 已是静音（F11 按到底那种也算静音）：按 F10 是解除静音，回到 2%。
            let restore = max(ConfigStore.shared.displayVolume(for: d.identity), Self.unmuteRestoreFraction)
            applyVolumeState(d, fraction: restore, muted: false)
        } else {
            applyVolumeState(d, fraction: ConfigStore.shared.displayVolume(for: d.identity), muted: true)
        }
        return true
    }

    /// 音量 0 即静音的判定阈值；F10 解除静音后恢复的音量。
    private static let muteEpsilon = 0.005
    private static let unmuteRestoreFraction = 0.02

    /// 当前是否算静音：内存标记、持久化标记、存量音量、设备真实静音位，四者任一成立即成立。
    /// 用状态判定代替盲切 toggle，偶发脱节也不会把 F10 卡死在静音里。
    private func isEffectivelyMuted(_ display: ExternalDisplay) -> Bool {
        if primaryMuted || ConfigStore.shared.displayMuted(for: display.identity) {
            return true
        }
        if ConfigStore.shared.displayVolume(for: display.identity) <= Self.muteEpsilon {
            return true
        }
        if let dev = CoreAudioVolume.shared.defaultOutputDevice(),
           CoreAudioVolume.shared.getMute(device: dev) == true {
            return true
        }
        return false
    }

    /// 音量/静音唯一写入口：设备、持久化、内存标记、图标、菜单一次对齐。
    /// 修掉以前「内存改了没落盘」「音量写了没动静音位」这类脱节。
    private func applyVolumeState(_ display: ExternalDisplay, fraction: Double, muted: Bool) {
        let v = clamp01(fraction)
        let dev = CoreAudioVolume.shared.defaultOutputDevice()
        let wasMuted = primaryMuted || ConfigStore.shared.displayMuted(for: display.identity)
        if muted {
            // 进入静音这一下写一次 0x62=0 + 0x8D；已经是静音时重复按 F11 不再写设备，不闪 OSD。
            let storedZero = ConfigStore.shared.displayVolume(for: display.identity) <= Self.muteEpsilon
            if !(wasMuted && storedZero) {
                setDisplayVolume(display, fraction: 0, audioDevice: dev)
                setDisplayMute(display, muted: true, audioDevice: dev, restoreVolume: 0)
            }
            ConfigStore.shared.setDisplayVolume(display.identity, 0)
            ConfigStore.shared.setDisplayMuted(display.identity, true)
            primaryMuted = true
        } else {
            // 只在“从静音出来”时写一次解静音位，平时调音量只写 0x62，不闪 OSD。
            if wasMuted {
                setDisplayMute(display, muted: false, audioDevice: dev, restoreVolume: v)
            }
            setDisplayVolume(display, fraction: v, audioDevice: dev)
            ConfigStore.shared.setDisplayVolume(display.identity, v)
            ConfigStore.shared.setDisplayMuted(display.identity, false)
            primaryMuted = false
        }
        if primaryDisplay?.identity == display.identity {
            updateStatusIcon()
        }
        refreshMenuIfVisible()
    }

    // MARK: - CoreAudio 音量（选项 B）封装

    /// 写显示器音量：有 CoreAudio 音频设备则走 CoreAudio（无固件 OSD 弹窗），否则回退 DDC。
    private func setDisplayVolume(_ display: ExternalDisplay, fraction: Double, audioDevice: AudioDeviceID?) {
        if let dev = audioDevice, CoreAudioVolume.shared.supportsVolume(device: dev) {
            _ = CoreAudioVolume.shared.setVolumeScalar(device: dev, fraction: fraction)
        } else {
            ddc.setVolume(display: display, fraction: fraction)
        }
    }

    /// 写显示器静音：同上，有 CoreAudio 设备走 CoreAudio Mute，否则回退 DDC 0x8D + 0x62 兜底。
    private func setDisplayMute(_ display: ExternalDisplay, muted: Bool, audioDevice: AudioDeviceID?, restoreVolume: Double = 0) {
        if let dev = audioDevice, CoreAudioVolume.shared.supportsMute(device: dev) {
            _ = CoreAudioVolume.shared.setMute(device: dev, muted: muted)
        } else {
            ddc.setMute(display: display, muted: muted,
                        restoreVolume: restoreVolume)
        }
    }

    // MARK: - Accessibility and screen recording permission

    private func axRequestItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: "重新申请无障碍",
            action: #selector(requestAccessibility(_:)),
            keyEquivalent: ""
        )
        item.target = self
        return item
    }

    private func axStatusItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: axTrusted() ? "无障碍权限：已授予" : "无障碍权限：未授予",
            action: nil,
            keyEquivalent: ""
        )
        item.isEnabled = false
        return item
    }

    @objc private func requestAccessibility(_ sender: NSMenuItem) {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)

        // Rebuild the session tap after the user changes the permission.
        KeyboardMonitor.shared.setEnabled(false)
        if ConfigStore.shared.keyboardControlEnabled() {
            KeyboardMonitor.shared.setEnabled(true)
        }

        openPrivacySettings(anchor: "Privacy_Accessibility")
        rebuild()
    }

    private func axTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    private func openPrivacySettings(anchor: String) {
        let modern = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(anchor)"
        let legacy = "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        if let url = URL(string: modern), NSWorkspace.shared.open(url) {
            return
        }
        if let url = URL(string: legacy) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Status icon

    /// 用 Apple 系统音量符号，按主显示器音量大小切换；静音显示斜杠。
    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        let vol = primaryVolumeFraction()
        let name: String
        if primaryMuted || vol <= Self.muteEpsilon {
            name = "speaker.slash.fill"
        } else if vol < 0.34 {
            name = "speaker.wave.1.fill"
        } else if vol < 0.67 {
            name = "speaker.wave.2.fill"
        } else {
            name = "speaker.wave.3.fill"
        }
        if let img = NSImage(systemSymbolName: name, accessibilityDescription: "显示器音量 \(Int(vol * 100))%") {
            img.isTemplate = true
            button.image = img
        }
    }

    private func primaryVolumeFraction() -> Double {
        guard let p = primaryDisplay else { return 0.5 }
        return ConfigStore.shared.displayVolume(for: p.identity)
    }

    // MARK: - Live refresh

    private func refreshMenuIfVisible() {
        if menuOpen {
            rebuild()
        }
    }

    private func rebuild() {
        guard let menu = statusItem?.menu else { return }
        buildMenu(menu)
    }

    private func clamp01(_ v: Double) -> Double {
        max(0, min(1, v))
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
