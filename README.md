# Sub2Bar

在 macOS 菜单栏查看自部署 [sub2api](https://github.com/Wei-Shaw/sub2api) 的账号状态、并发与额度。

[![CI](https://github.com/Yibael/sub2bar/actions/workflows/ci.yml/badge.svg?branch=master)](https://github.com/Yibael/sub2bar/actions/workflows/ci.yml)
![macOS](https://img.shields.io/badge/macOS-14%2B-black)
![Swift](https://img.shields.io/badge/Swift-native-orange)

## 功能

- 菜单栏常驻，使用 SwiftUI 与 AppKit 构建原生界面。
- 在设置中选择并 Pin 账号，面板只显示关心的账号及汇总。
- 查看当前并发、并发上限、调度状态和限流状态。
- 查看额度使用百分比、重置时间及 OpenAI 周额度估算。
- 打开面板自动刷新，显示刷新倒计时；关闭面板后停止轮询。

主要适配 OpenAI 和 Anthropic OAuth / SetupToken 账号，仅提供只读监控。

## 安装

支持 **macOS 14 及以上**，兼容 Apple Silicon 和 Intel Mac。

1. 从 [Releases](https://github.com/Yibael/sub2bar/releases) 下载 `Sub2Bar-<版本>-macOS-universal.zip`。
2. 解压，将 `Sub2Bar.app` 移到“应用程序”并打开。
3. 点击菜单栏图标进入面板。

当前安装包未经过 Apple 公证，请核对下载来源并遵循系统安全提示。若暂无 Release，可按下方步骤从源码构建。

## 上手

1. 打开 **设置 → 连接**，填写服务器 URL 和 sub2api **Admin API Key**。
2. 点击字段旁的“测试连接”，确认后点击“保存设置”。
3. 进入“菜单栏账号”，点击“获取全部账号”，Pin 需要显示的账号。
4. 打开菜单栏面板，开始查看数据。

保存设置不会发起连接；打开面板后自动查询。账号状态、额度与费用的刷新间隔可分别配置，额度最快支持 5 秒。

服务器默认使用 HTTPS；如需 HTTP，请在设置中显式开启。

## 从源码构建

需要 Xcode 26.3 或更新版本。

```sh
git clone https://github.com/Yibael/sub2bar.git
cd sub2bar
swift test
bash scripts/build-app.sh dist native
open dist/Sub2Bar.app
```

构建 Apple Silicon / Intel 通用包：

```sh
bash scripts/build-app.sh dist universal
```

## 更多

[参与开发](CONTRIBUTING.md) · [更新记录](CHANGELOG.md) · [安全说明](SECURITY.md) · [接口说明](docs/API-AUDIT.md) · [发布流程](docs/RELEASING.md)

许可证尚未选定。
