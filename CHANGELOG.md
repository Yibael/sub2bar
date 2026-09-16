# Changelog

版本采用 `MAJOR.MINOR.PATCH`。Git 标签格式为 `vMAJOR.MINOR.PATCH`，主分支为 `master`。

## [Unreleased]

- 修复 Intel GitHub runner 的 Metal 渲染测试崩溃：CI 与 Release 仅排除该 runner 上的两项离屏渲染测试，Apple Silicon 和本地保留完整测试。

## [1.5.0]

首个纳入当前仓库的版本；公开发布日期以 GitHub Release 为准。

### 功能

- 原生 macOS 菜单栏监控、账号 Pin、并发汇总及额度展示。
- 连接 / 刷新 / 菜单栏账号三栏设置；保存配置与测试连接分离。
- 本地权限受限的凭据文件与进程内缓存，不依赖钥匙串授权。
- 并发 2 秒、状态 5 秒、额度快照可配置，高成本额度查询至少间隔 10 分钟。
- 关闭面板停止轮询，认证失败暂停，失败退避与迟到响应隔离。
- 中性面板内容背景；移除演示和断开连接入口。

### 工程与安全

- Swift 回归测试、文件权限和快照口径测试。
- 本地提交检查、Gitleaks 全历史扫描、Actions 语法检查。
- Apple Silicon / Intel CI 测试及通用应用打包。
- 标签触发的 GitHub Release、安装包 SHA-256 校验和、文档与贡献流程。
- 不提交或迁移历史构建产物、本地密钥、日志或审计工作文件。
