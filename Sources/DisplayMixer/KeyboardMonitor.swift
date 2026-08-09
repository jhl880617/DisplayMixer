//
//  KeyboardMonitor.swift
//  DisplayMixer
//
//  Media-key interception follows MonitorControl's MediaKeyTapInternals:
//  cgSessionEventTap, headInsertEventTap, and a dedicated tap RunLoop.
//

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

final class KeyboardMonitor {
    static let shared = KeyboardMonitor()

    var onBrightnessUp: ((Bool) -> Bool)?
    var onBrightnessDown: ((Bool) -> Bool)?
    var onVolumeUp: ((Bool) -> Bool)?
    var onVolumeDown: ((Bool) -> Bool)?
    var onMuteToggle: ((Bool) -> Bool)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var tapRunLoop: CFRunLoop?
    private var tapQueue: DispatchQueue?
    private var desired = false

    private let kSysDefined: UInt32 = 14
    private let kKeyDown: UInt32 = 10
    private let auxSubtype = 8

    private let auxBrightnessUp = 2
    private let auxBrightnessDown = 3
    private let auxSoundUp = 0
    private let auxSoundDown = 1
    private let auxMute = [5, 7]

    private let kdF14 = 107
    private let kdF15 = 113
    private let kdBrightnessUp = 144
    private let kdBrightnessDown = 145
    private let kdF10 = 109
    private let kdF11 = 103
    private let kdF12 = 111

    private init() {}

    var isEnabled: Bool {
        guard let tap else { return false }
        return CGEvent.tapIsEnabled(tap: tap)
    }

    func setEnabled(_ enabled: Bool) {
        desired = enabled
        if enabled {
            guard AXIsProcessTrusted() else {
                let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
                _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
                return
            }
            createTapIfNeeded()
        } else {
            stop()
        }
    }

    private func createTapIfNeeded() {
        if let tap, CGEvent.tapIsEnabled(tap: tap) { return }
        stop()
        createTap()
    }

    private func createTap() {
        let mask = CGEventMask(
            (UInt64(1) << UInt64(kSysDefined)) |
            (UInt64(1) << UInt64(kKeyDown))
        )
        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        guard let newTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                let monitor = Unmanaged<KeyboardMonitor>.fromOpaque(refcon!).takeUnretainedValue()
                return monitor.handleTapEvent(type: type, event: event)
            },
            userInfo: refcon
        ) else {
            NSLog("DisplayMixer: 无法创建媒体键 tap。请确认已授予辅助功能权限。")
            return
        }
        guard let newSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0) else {
            CFMachPortInvalidate(newTap)
            return
        }

        tap = newTap
        source = newSource
        CGEvent.tapEnable(tap: newTap, enable: true)

        let queue = DispatchQueue(label: "DisplayMixer MediaKeyTap Runloop")
        tapQueue = queue
        queue.async { [weak self] in
            guard let self else { return }
            let loop = CFRunLoopGetCurrent()
            self.tapRunLoop = loop
            CFRunLoopAddSource(loop, newSource, .commonModes)
            CFRunLoopRun()
        }
    }

    private func stop() {
        if let source {
            CFRunLoopSourceInvalidate(source)
        }
        if let loop = tapRunLoop {
            CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes as CFTypeRef) {
                CFRunLoopStop(loop)
            }
            CFRunLoopWakeUp(loop)
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        tap = nil
        source = nil
        tapRunLoop = nil
        tapQueue = nil
    }

    private func handleTapEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // MonitorControl's critical rule: disabled taps always return the
        // original event and never try to process or destroy it in the callback.
        if type == .tapDisabledByTimeout {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if type == .tapDisabledByUserInput {
            return Unmanaged.passUnretained(event)
        }

        return DispatchQueue.main.sync {
            self.handle(type: type, event: event)
        }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type.rawValue == kKeyDown {
            let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
            guard let semantic = semanticForKeyDown(code), desired else {
                return Unmanaged.passUnretained(event)
            }
            perform(semantic: semantic, event: event)
            return nil
        }

        guard type.rawValue == kSysDefined,
              let nsEvent = NSEvent(cgEvent: event),
              nsEvent.subtype.rawValue == auxSubtype,
              let semantic = semanticForAux(nsEvent) else {
            return Unmanaged.passUnretained(event)
        }
        guard desired else { return Unmanaged.passUnretained(event) }
        if keyPressed(nsEvent) {
            perform(semantic: semantic, event: event)
        }
        return nil
    }

    private func semanticForKeyDown(_ code: Int) -> String? {
        switch code {
        case kdF14, kdBrightnessDown: return "brightDown"
        case kdF15, kdBrightnessUp: return "brightUp"
        case kdF10: return "mute"
        case kdF11: return "volDown"
        case kdF12: return "volUp"
        default: return nil
        }
    }

    private func semanticForAux(_ event: NSEvent) -> String? {
        let data = UInt32(bitPattern: Int32(event.data1))
        let code = Int((data & 0xFFFF_0000) >> 16)
        switch code {
        case auxBrightnessUp: return "brightUp"
        case auxBrightnessDown: return "brightDown"
        case auxSoundUp: return "volUp"
        case auxSoundDown: return "volDown"
        case auxMute[0], auxMute[1]: return "mute"
        default: return nil
        }
    }

    private func keyPressed(_ event: NSEvent) -> Bool {
        let data = UInt32(bitPattern: Int32(event.data1))
        return ((data & 0x0000_FF00) >> 8) == 0x0A
    }

    private func perform(semantic: String, event: CGEvent) {
        let configured = event.flags.contains(.maskShift) && event.flags.contains(.maskAlternate)
        switch semantic {
        case "brightUp": _ = onBrightnessUp?(true)
        case "brightDown": _ = onBrightnessDown?(true)
        case "volUp": _ = onVolumeUp?(configured)
        case "volDown": _ = onVolumeDown?(configured)
        case "mute": _ = onMuteToggle?(configured)
        default: break
        }
    }
}
