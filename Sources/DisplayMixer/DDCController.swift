//
//  DDCController.swift
//  DisplayMixer
//
//  DDC/CI transport adapted from MacMix (https://github.com/ljmng7/MacMix), MIT License.
//  Original: MacMix/DisplayVolumeController.swift — IOKit/IOAV I2C transport based on the
//  MCCS protocol and the MIT-licensed MonitorControl project.
//
//  This version is DECOUPLED from audio routing: it enumerates external displays directly
//  via CoreGraphics and sends VCP commands (brightness 0x10, volume 0x62, mute 0x8D),
//  exactly like BetterDisplay does — independent of which device is the audio output.
//

import CoreGraphics
import Foundation
import IOKit

#if arch(x86_64)
import IOKit.i2c
#endif

// MARK: - Display model

public struct ExternalDisplay: Identifiable, Hashable {
    public let id: CGDirectDisplayID
    public let name: String
    public let vendorID: UInt32
    public let productID: UInt32
    public let serialNumber: UInt32

    public var identity: String {
        "\(vendorID)-\(productID)-\(serialNumber)-\(ExternalDisplay.normalizedName(name))"
    }

    public static func normalizedName(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }
}

// MARK: - Transport protocol

private protocol DDCTransport: AnyObject {
    func read(command: UInt8) -> (current: UInt16, maximum: UInt16)?
    func write(command: UInt8, value: UInt16) -> Bool
}

// MARK: - Apple Silicon (Arm64) transport via IOAVService

private typealias IOAVServiceRef = CFTypeRef

@_silgen_name("IOAVServiceCreateWithService")
private func createIOAVService(
    _ allocator: CFAllocator?,
    _ service: io_service_t
) -> Unmanaged<IOAVServiceRef>?

@_silgen_name("IOAVServiceReadI2C")
private func readIOAVI2C(
    _ service: IOAVServiceRef,
    _ chipAddress: UInt32,
    _ offset: UInt32,
    _ outputBuffer: UnsafeMutableRawPointer,
    _ outputBufferSize: UInt32
) -> IOReturn

@_silgen_name("IOAVServiceWriteI2C")
private func writeIOAVI2C(
    _ service: IOAVServiceRef,
    _ chipAddress: UInt32,
    _ dataAddress: UInt32,
    _ inputBuffer: UnsafeMutableRawPointer,
    _ inputBufferSize: UInt32
) -> IOReturn

private final class Arm64DDCTransport: DDCTransport, @unchecked Sendable {
    private struct RegistryDisplay {
        var edidUUID = ""
        var name = ""
        var serialNumber: UInt32 = 0
        var service: IOAVServiceRef?
    }

    private let service: IOAVServiceRef
    private static let chipAddress = UInt8(0x37)
    private static let dataAddress = UInt8(0x51)

    private init(service: IOAVServiceRef) {
        self.service = service
    }

    static func transport(for display: ExternalDisplay) -> Arm64DDCTransport? {
        let candidates = registryDisplays().compactMap { registryDisplay -> (RegistryDisplay, Int)? in
            guard registryDisplay.service != nil else {
                return nil
            }
            let score = matchScore(registryDisplay, display: display)
            return score > 0 ? (registryDisplay, score) : nil
        }
        .sorted { $0.1 > $1.1 }

        guard let best = candidates.first,
              candidates.dropFirst().first?.1 != best.1,
              let service = best.0.service else {
            return nil
        }

        return Arm64DDCTransport(service: service)
    }

    func read(command: UInt8) -> (current: UInt16, maximum: UInt16)? {
        var reply = [UInt8](repeating: 0, count: 11)

        guard communicate(send: [command], reply: &reply),
              reply[2] == 0x02,
              reply[3] == 0x00,
              reply[4] == command else {
            return nil
        }

        let maximum = UInt16(reply[6]) << 8 | UInt16(reply[7])
        let current = UInt16(reply[8]) << 8 | UInt16(reply[9])
        return (current, maximum)
    }

    func write(command: UInt8, value: UInt16) -> Bool {
        var unusedReply: [UInt8] = []
        return communicate(
            send: [command, UInt8(value >> 8), UInt8(value & 0xFF)],
            reply: &unusedReply
        )
    }

    private func communicate(send: [UInt8], reply: inout [UInt8]) -> Bool {
        var packet = [UInt8(0x80 | (send.count + 1)), UInt8(send.count)] + send + [0]
        let initialChecksum = send.count == 1
            ? Self.chipAddress << 1
            : Self.chipAddress << 1 ^ Self.dataAddress
        packet[packet.count - 1] = Self.checksum(initial: initialChecksum, bytes: packet.dropLast())

        for _ in 0 ..< 3 {
            var writeSucceeded = false
            for _ in 0 ..< 2 {
                usleep(10_000)
                writeSucceeded = packet.withUnsafeMutableBytes { bytes in
                    guard let baseAddress = bytes.baseAddress else {
                        return false
                    }
                    return writeIOAVI2C(
                        service,
                        UInt32(Self.chipAddress),
                        UInt32(Self.dataAddress),
                        baseAddress,
                        UInt32(bytes.count)
                    ) == kIOReturnSuccess
                }
            }

            guard !reply.isEmpty else {
                if writeSucceeded {
                    return true
                }
                usleep(20_000)
                continue
            }

            usleep(50_000)
            let readSucceeded = reply.withUnsafeMutableBytes { bytes in
                guard let baseAddress = bytes.baseAddress else {
                    return false
                }
                return readIOAVI2C(
                    service,
                    UInt32(Self.chipAddress),
                    0,
                    baseAddress,
                    UInt32(bytes.count)
                ) == kIOReturnSuccess
            }
            if readSucceeded,
               Self.checksum(initial: 0x50, bytes: reply.dropLast()) == reply.last {
                return true
            }
            usleep(20_000)
        }

        return false
    }

    private static func checksum<S: Sequence>(initial: UInt8, bytes: S) -> UInt8
    where S.Element == UInt8 {
        bytes.reduce(initial, ^)
    }

    private static func registryDisplays() -> [RegistryDisplay] {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != IO_OBJECT_NULL else {
            return []
        }
        defer { IOObjectRelease(root) }

        var iterator = io_iterator_t()
        guard IORegistryEntryCreateIterator(
            root,
            kIOServicePlane,
            IOOptionBits(kIORegistryIterateRecursively),
            &iterator
        ) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var results: [RegistryDisplay] = []
        var currentDisplay: RegistryDisplay?
        var entry = IOIteratorNext(iterator)

        while entry != IO_OBJECT_NULL {
            var nameBuffer = [CChar](repeating: 0, count: MemoryLayout<io_name_t>.size)
            let hasName = IORegistryEntryGetName(entry, &nameBuffer) == KERN_SUCCESS
            let entryName = hasName ? String(cString: nameBuffer) : ""

            if entryName.contains("AppleCLCD2") || entryName.contains("IOMobileFramebufferShim") {
                currentDisplay = registryDisplayProperties(entry: entry)
            } else if entryName == "DCPAVServiceProxy", var display = currentDisplay {
                let location = stringProperty(entry: entry, key: "Location")
                if location == "External",
                   let unmanagedService = createIOAVService(kCFAllocatorDefault, entry) {
                    display.service = unmanagedService.takeRetainedValue()
                    results.append(display)
                }
            }

            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }

        return results
    }

    private static func registryDisplayProperties(entry: io_registry_entry_t) -> RegistryDisplay {
        var result = RegistryDisplay()
        result.edidUUID = stringProperty(entry: entry, key: "EDID UUID") ?? ""

        guard let attributes = dictionaryProperty(entry: entry, key: "DisplayAttributes"),
              let productAttributes = attributes["ProductAttributes"] as? NSDictionary else {
            return result
        }

        result.name = productAttributes["ProductName"] as? String ?? ""
        if let serial = productAttributes["SerialNumber"] as? NSNumber {
            result.serialNumber = serial.uint32Value
        }
        return result
    }

    private static func stringProperty(entry: io_registry_entry_t, key: String) -> String? {
        guard let property = IORegistryEntryCreateCFProperty(
            entry,
            key as CFString,
            kCFAllocatorDefault,
            IOOptionBits(kIORegistryIterateRecursively)
        ) else {
            return nil
        }
        return property.takeRetainedValue() as? String
    }

    private static func dictionaryProperty(
        entry: io_registry_entry_t,
        key: String
    ) -> NSDictionary? {
        guard let property = IORegistryEntryCreateCFProperty(
            entry,
            key as CFString,
            kCFAllocatorDefault,
            IOOptionBits(kIORegistryIterateRecursively)
        ) else {
            return nil
        }
        return property.takeRetainedValue() as? NSDictionary
    }

    private static func matchScore(_ registryDisplay: RegistryDisplay, display: ExternalDisplay) -> Int {
        var score = 0
        let edidUUID = registryDisplay.edidUUID.uppercased()
        let vendor = String(format: "%04X", UInt16(truncatingIfNeeded: display.vendorID))
        let productValue = UInt16(truncatingIfNeeded: display.productID)
        let product = String(
            format: "%02X%02X",
            UInt8(productValue & 0xFF),
            UInt8(productValue >> 8)
        )

        if edidUUID.count >= 8,
           edidUUID.prefix(4) == vendor,
           edidUUID.dropFirst(4).prefix(4) == product {
            score += 10
        }
        if !registryDisplay.name.isEmpty,
           ExternalDisplay.normalizedName(registryDisplay.name)
                == ExternalDisplay.normalizedName(display.name) {
            score += 4
        }
        if registryDisplay.serialNumber != 0,
           display.serialNumber != 0,
           registryDisplay.serialNumber == display.serialNumber {
            score += 6
        }
        return score
    }
}

// MARK: - Intel transport (legacy) via IOKit I2C

#if arch(x86_64)

@_silgen_name("CGSServiceForDisplayNumber")
private func serviceForDisplayNumber(
    _ display: CGDirectDisplayID,
    _ service: UnsafeMutablePointer<io_service_t>
)

private final class IntelDDCTransport: DDCTransport, @unchecked Sendable {
    private let framebuffer: io_service_t
    private let replyTransactionType: IOOptionBits

    init?(displayID: CGDirectDisplayID) {
        var framebuffer = io_service_t()
        serviceForDisplayNumber(displayID, &framebuffer)
        guard framebuffer != IO_OBJECT_NULL,
              let transactionType = Self.supportedTransactionType() else {
            return nil
        }

        var busCount: IOItemCount = 0
        guard IOFBGetI2CInterfaceCount(framebuffer, &busCount) == KERN_SUCCESS,
              busCount > 0 else {
            IOObjectRelease(framebuffer)
            return nil
        }

        self.framebuffer = framebuffer
        replyTransactionType = transactionType
    }

    deinit {
        IOObjectRelease(framebuffer)
    }

    func read(command: UInt8) -> (current: UInt16, maximum: UInt16)? {
        var data: [UInt8] = [0x51, 0x82, 0x01, command, 0]
        data[4] = data.dropLast().reduce(0x6E, ^)

        for _ in 0 ..< 3 {
            usleep(10_000)
            var reply = [UInt8](repeating: 0, count: 11)
            let dataCount = UInt32(data.count)
            let replyCount = UInt32(reply.count)
            let succeeded = withUnsafeMutablePointer(to: &data[0]) { dataPointer in
                withUnsafeMutablePointer(to: &reply[0]) { replyPointer in
                    var request = IOI2CRequest()
                    request.sendAddress = 0x6E
                    request.sendTransactionType = IOOptionBits(kIOI2CSimpleTransactionType)
                    request.sendBuffer = vm_address_t(bitPattern: dataPointer)
                    request.sendBytes = dataCount
                    request.minReplyDelay = 10
                    request.replyAddress = 0x6F
                    request.replySubAddress = 0x51
                    request.replyTransactionType = replyTransactionType
                    request.replyBuffer = vm_address_t(bitPattern: replyPointer)
                    request.replyBytes = replyCount
                    return send(request: &request)
                }
            }

            guard succeeded,
                  reply.dropLast().reduce(0x50, ^) == reply.last,
                  reply[2] == 0x02,
                  reply[3] == 0x00,
                  reply[4] == command else {
                continue
            }

            let maximum = UInt16(reply[6]) << 8 | UInt16(reply[7])
            let current = UInt16(reply[8]) << 8 | UInt16(reply[9])
            return (current, maximum)
        }
        return nil
    }

    func write(command: UInt8, value: UInt16) -> Bool {
        var data: [UInt8] = [
            0x51,
            0x84,
            0x03,
            command,
            UInt8(value >> 8),
            UInt8(value & 0xFF),
            0,
        ]
        data[6] = data.dropLast().reduce(0x6E, ^)
        var succeeded = false
        let dataCount = UInt32(data.count)

        for _ in 0 ..< 2 {
            usleep(10_000)
            succeeded = withUnsafeMutablePointer(to: &data[0]) { pointer in
                var request = IOI2CRequest()
                request.sendAddress = 0x6E
                request.sendTransactionType = IOOptionBits(kIOI2CSimpleTransactionType)
                request.sendBuffer = vm_address_t(bitPattern: pointer)
                request.sendBytes = dataCount
                request.replyTransactionType = IOOptionBits(kIOI2CNoTransactionType)
                return send(request: &request)
            }
        }
        return succeeded
    }

    private func send(request: inout IOI2CRequest) -> Bool {
        var busCount: IOItemCount = 0
        guard IOFBGetI2CInterfaceCount(framebuffer, &busCount) == KERN_SUCCESS else {
            return false
        }

        for bus in 0 ..< busCount {
            var interface = io_service_t()
            guard IOFBCopyI2CInterfaceForBus(framebuffer, bus, &interface) == KERN_SUCCESS else {
                continue
            }
            defer { IOObjectRelease(interface) }

            var connection: IOI2CConnectRef?
            guard IOI2CInterfaceOpen(interface, IOOptionBits(), &connection) == KERN_SUCCESS,
                  let connection else {
                continue
            }
            defer { IOI2CConnectRelease(connection) }

            guard IOI2CSendRequest(connection, IOOptionBits(), &request) == KERN_SUCCESS else {
                continue
            }
            return true
        }
        return false
    }

    private static func supportedTransactionType() -> IOOptionBits? {
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOFramebufferI2CInterface"),
            nil
        ) == KERN_SUCCESS else {
            return nil
        }
        // kIOI2CDisplayTransactionType is the conventional reply transaction type on Intel.
        return IOOptionBits(kIOI2CDisplayTransactionType)
    }
}

#endif

// MARK: - Public controller

public final class DDCController {
    public static let shared = DDCController()

    public static let brightnessCommand: UInt8 = 0x10
    public static let volumeCommand: UInt8 = 0x62
    public static let muteCommand: UInt8 = 0x8D

    private init() {}

    /// 最近一次 DDC 写结果（供菜单内调试读数，便于判断亮度/静音是否真的写进了显示器）。
    public static var lastWriteInfo: String = "（暂无）"

    public func externalDisplays() -> [ExternalDisplay] {
        var onlineCount: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &onlineCount)
        guard onlineCount > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(onlineCount))
        CGGetOnlineDisplayList(onlineCount, &ids, &onlineCount)
        return ids.map { id in
            ExternalDisplay(
                id: id,
                name: Self.displayName(id),
                vendorID: CGDisplayVendorNumber(id),
                productID: CGDisplayModelNumber(id),
                serialNumber: CGDisplaySerialNumber(id)
            )
        }
    }

    public func read(_ display: ExternalDisplay, command: UInt8) -> (current: UInt16, maximum: UInt16)? {
        guard let transport = transport(for: display) else { return nil }
        return transport.read(command: command)
    }

    @discardableResult
    public func write(_ display: ExternalDisplay, command: UInt8, value: UInt16) -> Bool {
        guard let transport = transport(for: display) else { return false }
        return transport.write(command: command, value: value)
    }

    // fraction: 0.0 ... 1.0
    @discardableResult
    public func setBrightness(display: ExternalDisplay, fraction: Double) -> Bool {
        let v = max(0, min(1, fraction))
        let value = UInt16((v * 100).rounded())
        let ok = write(display, command: Self.brightnessCommand, value: value)
        Self.lastWriteInfo = "亮度 VCP=0x10 val=\(value) ok=\(ok)"
        return ok
    }

    public func setVolume(display: ExternalDisplay, fraction: Double) {
        let v = max(0, min(1, fraction))
        var value = UInt16((v * 100).rounded())
        // 某些显示器固件会把 VCP 0x62 的 value=0 解释为最大值（回绕），导致 0% 变成 100%。
        // 因此把最小有效值限制为 1，确保滑块拖到 0% 时不会突然变成最大音量。
        if value == 0 { value = 1 }
        let ok = write(display, command: Self.volumeCommand, value: value)
        Self.lastWriteInfo = "音量 VCP=0x62 val=\(value) ok=\(ok)"
    }

    /// 静音/取消静音。某些显示器对 VCP 0x8D 不响应，因此采用兜底方案：
    /// - 静音时同时把 VCP 0x62 音量写 0，确保扬声器不出声；
    /// - 取消静音时同时把 VCP 0x62 音量恢复到 `restoreVolume`。
    public func setMute(display: ExternalDisplay, muted: Bool, restoreVolume: Double = 0) {
        let muteValue: UInt16 = muted ? 1 : 2
        let muteOk = write(display, command: Self.muteCommand, value: muteValue)
        var volumeValue: UInt16 = 0
        var volumeOk = true
        if muted {
            volumeOk = write(display, command: Self.volumeCommand, value: 0)
        } else {
            let v = max(0, min(1, restoreVolume))
            volumeValue = UInt16((v * 100).rounded())
            volumeOk = write(display, command: Self.volumeCommand, value: volumeValue)
        }
        Self.lastWriteInfo = "静音 VCP=0x8D val=\(muteValue) ok=\(muteOk) | 音量兜底 VCP=0x62 val=\(volumeValue) ok=\(volumeOk)"
    }

    private func transport(for display: ExternalDisplay) -> DDCTransport? {
        #if arch(x86_64)
        if let intel = IntelDDCTransport(displayID: display.id) {
            return intel
        }
        #endif
        return Arm64DDCTransport.transport(for: display)
    }

    private static func displayName(_ id: CGDirectDisplayID) -> String {
        // 注：CGDisplayCopyDisplayName 在较新 SDK 中已被移除，这里用 vendorID:productID
        // 十六进制标识显示器（同样唯一，且 DDC 匹配靠 vendor/product/serial，不依赖名字）。
        let vendor = CGDisplayVendorNumber(id)
        let product = CGDisplayModelNumber(id)
        return String(format: "显示器 %04X:%04X", vendor, product)
    }
}

// MARK: - Capability probe & value sync

/// 某台显示器对 DDC/CI 亮度/音量的支持情况，以及显示器当前的真实数值。
/// 在 App 启动（或手动「重新检测」）时探测一次；不可读则对应能力为 false，菜单应置灰滑块。
public struct DisplayCapability: Sendable {
    public let brightnessSupported: Bool
    public let volumeSupported: Bool
    /// 来自显示器真实值的亮度比例 0...1（nil = 不支持/读取失败）
    public let brightnessFraction: Double?
    /// 来自显示器真实值的音量比例 0...1（nil = 不支持/读取失败）
    public let volumeFraction: Double?
    public let brightnessMax: UInt16
    public let volumeMax: UInt16
}

extension DDCController {
    /// 探测显示器能力并读取显示器当前的真实亮度/音量。
    /// - 亮度：读 VCP 0x10；音量：读 VCP 0x62。任一可读即认为支持。
    /// - 读取有超时，单次约几十~几百毫秒，仅在启动/手动重探测时调用。
    public func probeCapability(display: ExternalDisplay) -> DisplayCapability {
        var brightnessSupported = false
        var volumeSupported = false
        var brightnessFraction: Double?
        var volumeFraction: Double?
        var brightnessMax: UInt16 = 100
        var volumeMax: UInt16 = 100

        if let b = read(display, command: Self.brightnessCommand), b.maximum > 0 {
            brightnessSupported = true
            brightnessMax = b.maximum
            brightnessFraction = min(1, Double(b.current) / Double(b.maximum))
        }
        if let v = read(display, command: Self.volumeCommand), v.maximum > 0 {
            volumeSupported = true
            volumeMax = v.maximum
            volumeFraction = min(1, Double(v.current) / Double(v.maximum))
        }
        return DisplayCapability(
            brightnessSupported: brightnessSupported,
            volumeSupported: volumeSupported,
            brightnessFraction: brightnessFraction,
            volumeFraction: volumeFraction,
            brightnessMax: brightnessMax,
            volumeMax: volumeMax
        )
    }
}
