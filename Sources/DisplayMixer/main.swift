//
//  main.swift
//  DisplayMixer
//
//  无主界面、仅菜单栏图标的 macOS 代理程序（activation policy = .accessory）。
//  顶层代码运行在主线程，用 assumeIsolated 进入 main actor 上下文后再创建 delegate。
//

import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    let delegate = AppDelegate()
    app.delegate = delegate

    app.run()
}
