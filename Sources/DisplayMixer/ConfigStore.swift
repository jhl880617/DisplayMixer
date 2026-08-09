//
//  ConfigStore.swift
//  DisplayMixer
//
//  简单的偏好持久化：每 App 音量/静音、每显示器亮度/音量。
//  用 UserDefaults（沙盒外、随用户走），键以 bundle id / 显示器 identity 区分。
//

import Foundation

final class ConfigStore {
    static let shared = ConfigStore()

    private let defaults = UserDefaults.standard

    private init() {}

    // MARK: - Per-app volume / mute

    func appVolume(for bundleID: String) -> Double {
        let key = "appVol.\(bundleID)"
        // 未设置时默认 1.0（原样输出）
        if defaults.object(forKey: key) == nil { return 1.0 }
        let v = defaults.double(forKey: key)
        return max(0, min(2, v))
    }

    func setAppVolume(_ bundleID: String, _ volume: Double) {
        defaults.set(max(0, min(2, volume)), forKey: "appVol.\(bundleID)")
    }

    func appMuted(for bundleID: String) -> Bool {
        defaults.bool(forKey: "appMute.\(bundleID)")
    }

    func setAppMuted(_ bundleID: String, _ muted: Bool) {
        defaults.set(muted, forKey: "appMute.\(bundleID)")
    }

    // MARK: - Per-display brightness / volume

    func displayBrightness(for identity: String) -> Double {
        let key = "dispBright.\(identity)"
        if defaults.object(forKey: key) == nil { return 0.5 }
        let v = defaults.double(forKey: key)
        return v >= 0 && v <= 1 ? v : 0.5
    }

    func setDisplayBrightness(_ identity: String, _ fraction: Double) {
        defaults.set(max(0, min(1, fraction)), forKey: "dispBright.\(identity)")
    }

    func displayVolume(for identity: String) -> Double {
        let key = "dispVol.\(identity)"
        if defaults.object(forKey: key) == nil { return 0.5 }
        let v = defaults.double(forKey: key)
        return v >= 0 && v <= 1 ? v : 0.5
    }

    func setDisplayVolume(_ identity: String, _ fraction: Double) {
        defaults.set(max(0, min(1, fraction)), forKey: "dispVol.\(identity)")
    }

    func displayMuted(for identity: String) -> Bool {
        defaults.bool(forKey: "dispMute.\(identity)")
    }

    func setDisplayMuted(_ identity: String, _ muted: Bool) {
        defaults.set(muted, forKey: "dispMute.\(identity)")
    }

    // MARK: - Keyboard control

    /// 是否启用键盘媒体键 → 显示器 DDC 映射（默认开启）。
    func keyboardControlEnabled() -> Bool {
        if defaults.object(forKey: "kbdControl") == nil { return true }
        return defaults.bool(forKey: "kbdControl")
    }

    func setKeyboardControlEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: "kbdControl")
    }

    /// 键盘/菜单图标所控制的「主显示器」identity（nil = 自动取第一个外接屏）。
    func primaryDisplayIdentity() -> String? {
        defaults.string(forKey: "primaryDisp")
    }

    func setPrimaryDisplayIdentity(_ identity: String?) {
        defaults.set(identity, forKey: "primaryDisp")
    }

    // MARK: - Keyboard step

    /// 键盘/滑块每次调节的步进百分比（可选 1/2/5/10/20），默认 5。
    var stepPercent: Int {
        get { let v = defaults.integer(forKey: "stepPercent"); return v == 0 ? 5 : v }
        set { defaults.set(newValue, forKey: "stepPercent") }
    }

    var fineStepEnabled: Bool {
        get { defaults.bool(forKey: "fineStepEnabled") }
        set { defaults.set(newValue, forKey: "fineStepEnabled") }
    }
}
