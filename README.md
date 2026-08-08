# DisplayMixer

DisplayMixer 是一个 macOS 菜单栏工具，用来集中控制外接显示器和应用音频。

## 主要功能

- 通过 DDC/CI 调节外接显示器亮度。
- 通过 CoreAudio 调节默认显示器音频设备的音量和静音。
- 使用 F1/F2 调节亮度，使用 F10/F11/F12 调节静音和音量。
- 为正在播放声音的 App 提供独立音量控制。
- 支持实时拖动显示器亮度和音量滑块。
- 支持按键步进设置，以及按当前音量区间变化的精细 OSD 步进。
- 提供自定义调节浮层、开机自启、权限申请和显示器数值同步。
- 权限被撤回时自动放行键盘事件，恢复权限后自动恢复键盘控制。

## 系统要求

- macOS 15.0 或更高版本。
- 外接显示器需要支持 DDC/CI。
- 使用键盘控制需要在“系统设置 → 隐私与安全性 → 辅助功能”中允许 DisplayMixer。
- 使用分应用音量需要在“系统设置 → 隐私与安全性 → 屏幕录制”中允许 DisplayMixer。
- 如果使用 F1/F2 作为亮度键，请在“系统设置 → 键盘”中打开“将 F1、F2 等键用作标准功能键”。

## 安装

打开 Releases 页面下载 `DisplayMixer-1.0.0.dmg`，将 DisplayMixer 拖入“应用程序”文件夹后运行。

首次运行后，从菜单栏图标进入权限申请和功能设置。

## 按键步进

在菜单栏的“按键步进”中可以选择普通步进。开启“使用精细 OSD 步数”后，普通功能键会按照当前数值使用精细步进；按住 Shift+Option 再按功能键，则使用用户选择的普通步进。

精细步进规则如下：

- 0%-10%：1%
- 10%-30%：2%
- 30%-50%：5%
- 50%-75%：10%
- 75%以上：5%

## 权限说明

DisplayMixer 每次启动都会重新检查无障碍和屏幕录制权限。无障碍权限被关闭时，键盘事件会原样放行，不会阻塞系统输入；重新授予权限后，键盘控制会自动恢复。

macOS 对已经作出决定的权限通常不会重复弹窗。此时请在对应的系统设置页面中重新勾选 DisplayMixer。

## 构建

项目使用 Swift Package Manager 和 AppKit 构建。在项目目录执行：

```sh
./build-app.sh
./build-dmg.sh
```

`build-app.sh` 会构建、签名并安装到 `/Applications/DisplayMixer.app`。当前发布包使用 ad-hoc 签名，首次打开时可能需要在 Finder 中右键选择“打开”。

## 开源组件与特别鸣谢

DisplayMixer 的部分核心代码改编自以下开源项目，感谢这些项目作者和贡献者：

- [MacMix](https://github.com/ljmng7/MacMix)：每应用音频混音引擎、CoreAudio 设备管理，以及部分 DDC/CI 和 IOKit/IOAV 传输代码。MacMix 采用 MIT License，相关保留声明见 [NOTICE](NOTICE)。
- [MonitorControl](https://github.com/MonitorControl/MonitorControl)：DDC/CI、MCCS 和显示器控制相关实现的参考来源。MonitorControl 采用 MIT License。

项目中的改编代码保留了相应的版权和许可信息。更多来源说明见 [NOTICE](NOTICE)。

## 许可证

DisplayMixer 其余原创部分采用 MIT License 发布；第三方代码继续遵循其原始许可证。
