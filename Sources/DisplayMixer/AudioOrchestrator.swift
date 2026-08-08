//
//  AudioOrchestrator.swift
//  DisplayMixer
//
//  封装 MacMix 的 AppAudioMixer（CoreAudio 进程 Tap 每 App 音量引擎）。
//  负责：枚举正在出声的 App、把它们的音量/静音拼成 AppMixerCommand、下发到引擎。
//  音频引擎本身（AppAudioMixer / CoreAudioHardware / AudioModels）来自 MacMix，MIT 许可。
//

import Foundation
import CoreGraphics

@MainActor
final class AudioOrchestrator {
    static let shared = AudioOrchestrator()

    private let hardware = CoreAudioHardware()
    private var revision: UInt64 = 0
    private var routeGeneration: UInt64 = 0
    private var lastOutputUID: String?

    private init() {}

    /// 当前系统是否支持每 App 音量（macOS 14.4+）。
    var isSupported: Bool { AppAudioMixer.isSupported }

    /// 屏幕录制（音频进程 Tap）权限是否已授予。
    func hasPermission() async -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// 触发系统授权弹窗（首次使用 App 音量前调用）。
    @discardableResult
    func requestPermission() async -> Bool {
        _ = CGRequestScreenCaptureAccess()
        return CGPreflightScreenCaptureAccess()
    }

    /// 当前正在出声的 App 列表；音量/静音取自 ConfigStore 持久化值。
    func runningApps() -> [AudioApp] {
        hardware.runningOutputApps(
            storedVolume: { ConfigStore.shared.appVolume(for: $0) },
            storedMute: { ConfigStore.shared.appMuted(for: $0) }
        )
    }

    func setVolume(bundleID: String, fraction: Double) {
        let value = max(0, min(2, fraction))
        ConfigStore.shared.setAppVolume(bundleID, value)
        ConfigStore.shared.setAppMuted(bundleID, value <= 0.0001)
        guard CGPreflightScreenCaptureAccess() else { return }
        submit()
    }

    // MARK: - internals

    private func currentOutputDeviceUID() -> String? {
        hardware.devices(for: .output).first(where: { $0.isCurrent })?.uid
    }

    private func syncRouteGeneration() {
        let uid = currentOutputDeviceUID()
        if uid != lastOutputUID {
            routeGeneration &+= 1
            lastOutputUID = uid
        }
    }

    private func submit() {
        syncRouteGeneration()
        revision &+= 1

        let outputDeviceUID = currentOutputDeviceUID()
        let targets = runningApps().map {
            AppMixTarget(
                id: $0.id,
                audioObjectIDs: $0.audioObjectIDs,
                volume: $0.isMuted ? 0 : $0.volume
            )
        }

        let command = AppMixerCommand(
            revision: revision,
            routeGeneration: routeGeneration,
            outputDeviceUID: outputDeviceUID,
            targets: targets
        )

        AppAudioMixer.shared.noteLatestCommand(revision: command.revision)
        AppAudioMixer.shared.submitReconcile(command) { _ in }
    }
}
