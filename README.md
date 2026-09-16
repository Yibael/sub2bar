# Sub2Bar

**在 macOS 菜单栏查看自部署 sub2api 的账号状态、并发与额度。**

A native macOS menu bar companion for self-hosted sub2api — built with SwiftUI and AppKit, without third-party Swift dependencies.

[![CI](https://github.com/Yibael/sub2bar/actions/workflows/ci.yml/badge.svg?branch=master)](https://github.com/Yibael/sub2bar/actions/workflows/ci.yml)
![macOS](https://img.shields.io/badge/macOS-14%2B-black)
![Swift](https://img.shields.io/badge/Swift-native-orange)

[安装](#安装) · [首次配置](#首次配置) · [刷新策略](#刷新策略) · [安全](#密钥与安全) · [源码构建](#从源码构建) · [贡献](CONTRIBUTING.md)

## 能做什么

- **菜单栏常驻**：点击图标查看账号，关闭面板后停止自动请求，不常驻 Dock。
- **只看关心的账号**：在设置中搜索并 Pin；面板及汇总只覆盖已 Pin 账号。
- **并发与状态**：查看当前并发 / 上限，以及可调度、停用、错误、限流等状态。
- **额度快照**：展示 5 小时 / 7 天已用百分比、重置时间、窗口计费和 OpenAI 周额度估算。
- **原生设置**：连接、刷新与菜单栏账号分组；保存设置不连接服务器，测试连接单独执行。
- **按成本刷新**：高频本地状态与可能访问上游的额度查询分开，避免频繁探测 OpenAI。

主要适配 OpenAI 和 Anthropic OAuth / SetupToken。其他平台可以列出账号，但平台专属额度字段不保证完整覆盖。Sub2Bar 不是账号管理后台，不提供启停、删除、额度重置或修改服务端配置功能。

## 安装

运行要求：**macOS 14 或更新版本**，Apple Silicon 或 Intel Mac。

1. 从 [GitHub Releases](https://github.com/Yibael/sub2bar/releases) 下载 `Sub2Bar-<版本>-macOS-universal.zip`。
2. 可选：同时下载 `.sha256`，在相同目录运行 `shasum -a 256 -c <文件名>.sha256` 验证完整性。
3. 解压，将 `Sub2Bar.app` 放入“应用程序”，启动后点击菜单栏的服务器图标。

> 安装包由版本标签触发 GitHub Actions 构建，不存放在 Git 仓库中。仓库初始化后需要维护者首次推送版本标签才会出现 Release；尚无 Release 时请从源码构建。
>
> 当前构建采用 ad-hoc 签名，**没有 Developer ID 签名或 Apple 公证**。SHA-256 验证不等于 Apple 信任验证；请自行核对来源并遵循系统的安全提示。工作流不要求你导入本地自签名证书。

## 首次配置

1. 菜单栏 → 设置 → **连接**，填写服务器 URL 与 **Admin API Key**。
2. 可点击字段旁的“测试连接”。这里需要 sub2api 管理员密钥，不是普通用户 API Key 或网页登录 token。
3. 点击“保存设置”。此时只保存到本机，不发起网络请求。
4. 进入“菜单栏账号”，点击“获取全部账号”，选择要 Pin 的账号。Pin 自动保存。
5. 打开菜单栏面板，自动读取已保存的连接信息并开始监控。

支持反向代理子路径，以及以 `/api/v1` 或 `/api/v1/admin` 结尾的 URL。默认仅允许 HTTPS；HTTP 必须在设置中显式开启。

从本地旧版 1.4.x 升级时，需要重新输入一次 Admin Key。已有 URL 和 Pin 会保留，旧钥匙串条目不会自动导出或删除。

## 刷新策略

以下是面板可见时的正常间隔。网络请求完成后计时，失败会退避；关闭面板或系统睡眠时停止轮询。

| 数据 | 默认间隔 | 可配置 | 是否可能访问 OpenAI |
| --- | --- | --- | --- |
| 当前并发、并发上限 | 2 秒 | 否 | 否：已核查的账号详情路径读取本地数据 |
| 调度、停用、错误、限流状态 | 5 秒 | 否 | 否：与并发共享账号详情查询 |
| OpenAI 已有额度百分比、重置时间 | 5 秒 | 5 / 10 / 15 / 30 / 60 秒 | 否：读取账号 `extra` 中的服务器快照 |
| Anthropic 被动额度与相关统计 | 5 秒 | 与快照间隔相同 | 否：使用 `source=passive` |
| 完整额度、OpenAI 窗口计费及周额度估算 | 首次查询；之后每账号至少 10 分钟 | 暂不配置 | 可能：主动接口受独立限频保护 |

注意：**5 秒刷新已有快照，不等于 5 秒向 OpenAI 取一次新数据。** `source=active` 即使不传 `force` 也可能触发上游探测，OpenAI 不能直接使用只适用于 Anthropic 的 `source=passive`。

高成本预算在发送前登记；同一进程内的关闭重开、取消请求、手动刷新、取消 Pin 后重新 Pin、保存设置均不会绕过它。慢上游查询不会阻塞并发更新。新启动的应用会建立新的进程预算。

完整调用链与固定上游版本见 [API-AUDIT.md](docs/API-AUDIT.md)。该核查不代表所有旧版、自定义分支或未来版本行为完全相同。

## 如何理解数据

- 顶部汇总只覆盖已 Pin 且有有效数据的账号，不代表整个服务器。
- 并发是轮询采样，不是连续实时流；未知值显示 `—`，不伪造为零。
- 周额度估算使用 OpenAI 同一次完整采样中的 `窗口费用 × 100 ÷ 已用百分比`；不是剩余额度，也不是预计本周花费。
- 新百分比不会与旧费用混算。完整计费统计可能比快速快照旧，可在账号详情查看采样时间。
- 缺失字段、零使用率或零费用时不估算额度；上游未提供的数据不会凭空补齐。
- 账号详情失败时保留 Pin 并显示异常，不会自动换成其他账号。

## 密钥与安全

Admin Key 保存在当前 Mac 的：

```text
~/Library/Application Support/com.sub2bar.app/credential.json
```

**文件是明文，不是加密保险库。** 目录权限为 `0700`，文件权限为 `0600`；同一用户运行的其他程序、管理员权限程序及备份仍可能读取。没有使用把加密密钥放在旁边的“简单加密”来制造安全错觉。

- 成功读取后在内存复用，不随每次刷新重新读取文件；不依赖钥匙串授权。
- URL 与 Pin 保存在普通偏好设置中，不包含管理员密钥或账号快照。
- 不记录密钥，不展示未经处理的服务端错误体，不绕过 HTTPS 证书验证，不自动跟随重定向。
- Admin Key 本身仍可能拥有管理写权限；客户端只读不会降低它在服务端的权限。
- 不要将真实密钥放进 Issue、截图、Git 提交或 GitHub Actions Secrets。构建和测试完全不需要它。

完整威胁边界与漏洞报告方式见 [SECURITY.md](SECURITY.md)。

## 从源码构建

建议 Xcode 26.3 或更新版本。CI 明确选择 Xcode 26.3，并分别在 Apple Silicon 与 Intel runner 上执行测试。

```sh
git clone https://github.com/Yibael/sub2bar.git
cd sub2bar
bash scripts/setup-dev.sh
swift test
bash scripts/build-app.sh dist native
open dist/Sub2Bar.app
```

生成与 Release 相同的通用包：

```sh
bash scripts/build-app.sh dist universal
```

构建脚本生成应用、ZIP 与 SHA-256；所有产物被忽略，不应提交。`setup-dev.sh` 只配置本仓库提交钩子并安装校验过的本地审计工具，不修改全局 Git 设置。CLI 测试使用假凭据和本地 HTTP 替身，不访问真实部署。

项目结构：

```text
Sources/Sub2Bar/       原生界面、文件凭据、可见性与轮询生命周期
Sources/Sub2BarCore/   API 客户端、模型、配置与 Pin
Tests/                Swift 单元/集成/窗口测试
Resources/Info.plist   应用版本与系统要求
scripts/              打包、版本验证、提交安全检查
.github/workflows/    CI 与标签触发的 Release
docs/                 API 核查与发布流程
```

## CI / Release

- **`master` / PR**：检查仓库内容，Gitleaks 扫描可见 Git 历史，验证工作流，在两种架构运行 Swift 测试，再执行通用打包检查。
- **`vX.Y.Z` 标签**：验证版本及所属主分支，重新测试/构建，将通用安装包和校验和发布到 GitHub Releases。
- 发布任务使用内置临时 `GITHUB_TOKEN`，不需要 PAT、Admin Key、Apple 证书或任何生产凭据。

发布由维护者明确推送标签触发，不会因为普通 commit 就自动创建 Release。详见 [RELEASING.md](docs/RELEASING.md)。

## 常见问题

**为什么保存设置后没有连接？** 这是预期行为；打开面板才启动监控。测试连接与获取账号列表需要手动点击。

**为什么并发在变化，额度却没有变化？** 快速轮询读取的是已有快照。完整统计单独限频，上游采样也可能滞后；请查看采样时间。

**为什么没有账号？** 初次使用不会自动 Pin 全部账号。请先在设置中获取列表并选择账号。

**为什么显示 `—`？** 服务器未提供字段或暂时读取失败。不要把未知值理解为零。

**是否支持多服务器、写操作和开机启动？** 当前不支持。以单服务器、只读、明确请求成本为范围。

## 贡献与致谢

请先阅读 [CONTRIBUTING.md](CONTRIBUTING.md)，不要提交任何真实凭据或构建产物。发布记录见 [CHANGELOG.md](CHANGELOG.md)。

- [sub2api](https://github.com/Wei-Shaw/sub2api)：服务端接口与数据口径的依据。
- [SwiftBar](https://github.com/swiftbar/SwiftBar)、[Stats](https://github.com/exelban/stats)：README 的安装、构建、FAQ 与贡献说明组织方式参考；未复制其实现或素材。

## 许可证

尚未选定项目许可证；本次初始化没有擅自加入 MIT、Apache 或其他授权条款。首次公开分发或接受外部贡献前，请维护者明确许可证。
