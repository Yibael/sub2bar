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
- 查看已 Pin 账号的今日用量（标准价美元），随账号状态刷新；本周用量保留原有额度窗口口径。
- OAuth 账号可在本地配置月订阅价格和每月续费日，展示各自本周期实际扣费与 Pin 账号消费/成本汇总；可选择是否包含 Admin 消费，并独立设置实际消费和订阅成本的货币符号（原样显示、不换算金额）。
- 面板一次显示一个已 Pin 账号，按保存的顺序左右切换；用量、周期消费、订阅成本以紧凑指标展示，详情展开直接撑高，不使用竖向滚动。
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
3. 进入“账号管理”自动加载账号列表；点击“加入切换”将账号 Pin，用序号旁的上下箭头调整切换顺序。OAuth 账号右侧的订阅设置按钮可填写月价和每月续费日。
4. 在“消费统计”选择是否包含 Admin 消费（默认包含）、周期统计时区，以及实际消费／订阅成本的货币符号（默认均为 `$`，可填 `¥`、`€` 等）。符号直接放在金额前，不生成 `CN¥` 等地区前缀。未完整配置订阅的账号不计入消费与成本汇总。
5. 打开菜单栏面板，开始查看数据。

保存设置不会发起连接；打开面板后自动查询。账号状态、额度与费用的刷新间隔可分别配置，额度最快支持 5 秒。

账号管理优先展示内存缓存：首次进入自动加载，1 分钟内再次进入不请求，过期后保留旧列表并后台刷新；手动刷新可立即获取。失败保留列表及上次更新时间，切换服务器或密钥会清空缓存；账号目录不持续轮询、不落盘。

面板支持左右按钮、方向键以及折叠卡片横向拖动切换；展开详情后保留文本选择，不通过拖动切换。切换和调整顺序不发新请求、不重置额度冷却；顶部始终汇总全部符合条件的 Pin 账号，不只统计当前显示的账号。

订阅消费独立每 30 秒查询 sub2api 本地实际扣费统计（含倍率），不查询上游额度。以指定时区的续费日零点划分月周期，显示续费日至下月续费日前一天（例如 9 月 15 日至 10 月 14 日，首尾均包含）；短月取月末，不等同于精确扣款时刻。关闭 Admin 统计依据当前用户角色排除。月订阅成本不按天摊销；部分消费读取失败时不展示不完整总额。订阅元数据仅保存本地，取消 Pin 不会删除。

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
