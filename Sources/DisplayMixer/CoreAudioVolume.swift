//
//  CoreAudioVolume.swift
//  DisplayMixer
//
//  选项 B：显示器音量改用 CoreAudio 输出设备音量控制（kAudioDevicePropertyVolumeScalar /
//  kAudioDevicePropertyMute），而不是 DDC/CI VCP 0x62。
//  好处：macOS 调 CoreAudio 设备音量不会触发显示器固件自己的 OSD 弹窗（DDC 0x62 才会），
//  与 BetterDisplay 的行为一致；同时 DDC 亮度（0x10）仍独立走 DDC/CI。
//
//  设备映射：枚举所有 CoreAudio 输出设备，用 CGDisplayGetDisplayIDFromAudioDeviceID
//  反查其关联显示器，匹配到目标 ExternalDisplay.id 即为其音频设备。找不到时回退「默认输出
//  设备」，再回退 DDC（极少数无音频通道的显示器）。
//

import CoreAudio
import CoreGraphics
import Foundation

final class CoreAudioVolume {
    static let shared = CoreAudioVolume()

    private init() {}

    /// 注：macOS 27 SDK 已移除 CGDisplayGetDisplayIDFromAudioDeviceID，无法在框架层把
    /// 某台显示器精确映射到其 CoreAudio 音频设备。本 App 的场景是「Mac mini + 单台外接显示器，
    /// 显示器即默认音频输出」，因此音量统一控制「系统默认输出设备」（即显示器音箱），
    /// 行为与 BetterDisplay 一致，且不会触发显示器固件自身的 OSD 弹窗（DDC 0x62 才会）。
    /// 若默认输出不是显示器（例如接了独立音箱），可在系统设置里把显示器设为默认输出。
    func defaultOutputDevice() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dev: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr, 0, nil, &size, &dev
        ) == noErr, dev != 0 else {
            return nil
        }
        return dev
    }

    // MARK: - 取值 / 设值

    func getVolumeScalar(device: AudioDeviceID) -> Float? {
        guard var addr = volumeAddress(device: device, master: true) else { return nil }
        var val: Float = 0
        var size = UInt32(MemoryLayout<Float>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &val) == noErr else {
            return nil
        }
        return val
    }

    /// fraction 0...1。返回是否成功写入。
    @discardableResult
    func setVolumeScalar(device: AudioDeviceID, fraction: Double) -> Bool {
        let f = Float(max(0, min(1, fraction)))
        guard var addr = volumeAddress(device: device, master: true) else { return false }
        var val = f
        let size = UInt32(MemoryLayout<Float>.size)
        return AudioObjectSetPropertyData(device, &addr, 0, nil, size, &val) == noErr
    }

    func getMute(device: AudioDeviceID) -> Bool? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if !AudioObjectHasProperty(device, &addr) {
            addr.mElement = 1
            if !AudioObjectHasProperty(device, &addr) { return nil }
        }
        var val: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &val) == noErr else {
            return nil
        }
        return val != 0
    }

    func setMute(device: AudioDeviceID, muted: Bool) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if !AudioObjectHasProperty(device, &addr) {
            addr.mElement = 1
            if !AudioObjectHasProperty(device, &addr) { return false }
        }
        var val: UInt32 = muted ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectSetPropertyData(device, &addr, 0, nil, size, &val) == noErr
    }

    func supportsMute(device: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(device, &addr) {
            return true
        }
        addr.mElement = 1
        return AudioObjectHasProperty(device, &addr)
    }

    /// 该设备是否支持 CoreAudio 音量调节（用于菜单诊断）。
    func supportsVolume(device: AudioDeviceID) -> Bool {
        volumeAddress(device: device, master: true) != nil
    }

    // MARK: - 内部

    private func volumeAddress(device: AudioDeviceID, master: Bool) -> AudioObjectPropertyAddress? {
        let element: AudioObjectPropertyElement = master ? kAudioObjectPropertyElementMain : 1
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: element
        )
        if AudioObjectHasProperty(device, &addr) {
            return addr
        }
        if master {
            // 没有 master 音量，尝试主声道 1
            return volumeAddress(device: device, master: false)
        }
        return nil
    }

    /// 所有具备输出声道（>0）的 CoreAudio 设备。
    private func outputDevices() -> [AudioDeviceID] {
        var size: UInt32 = 0
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size
        ) == noErr else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devices
        ) == noErr else {
            return []
        }
        return devices.filter { hasOutputChannels($0) }
    }

    private func hasOutputChannels(_ device: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else {
            return false
        }
        let ptr = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<UInt8>.alignment)
        defer { ptr.deallocate() }
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, ptr) == noErr else {
            return false
        }
        let layout = ptr.bindMemory(to: AudioBufferList.self, capacity: 1)
        var totalChannels: UInt32 = 0
        let abl = UnsafeMutableAudioBufferListPointer(layout)
        for buf in abl {
            totalChannels += buf.mNumberChannels
        }
        return totalChannels > 0
    }
}
