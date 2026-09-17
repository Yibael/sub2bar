# 参与开发

主分支是 `master`。请先用 Issue 描述较大的功能或 API 行为变化，避免引入未核查的上游请求。

## 本地环境

- macOS 14+；Xcode 26.3 或更新版本。
- 系统 Python 3、Git、curl；项目本身没有第三方 Swift 依赖。
- 不需要真实 sub2api 服务器或 Admin Key 来运行测试。

```sh
bash scripts/setup-dev.sh
swift test
python3 -m unittest discover -s scripts/tests -v
```

初始化只配置当前仓库的 `.githooks` 并将固定版本审计工具下载到被忽略的 `.tools/`，不修改全局 Git 配置或钥匙串。已有其他 hooksPath 时会停止，需先人工合并配置。

## CI 渲染测试范围

CI 和 Release 在 Apple Silicon runner 上执行完整测试。`macos-15-intel` 的离屏渲染测试曾在 `ImageRenderer` 内触发 Metal 的 `Target device architecture is nil` 断言，因此仅在该 runner 中按完整名称排除以下两项：

- `AppearanceTests/testNeutralPanelBackgroundBlocksBlueAndRedInLightAndDark`
- `AppearanceTests/testSettingsAndPanelCanRenderOffscreen`

Intel 的编译、API、凭据、轮询以及窗口交互测试仍执行；不忽略失败，也不跳过整个窗口测试目标。本地 `swift test` 不受影响，包括 Intel 实机。修改筛选时需同步两个工作流，并确认只排除这两项；云端镜像兼容性恢复后应移除例外。

## 提交前

```sh
git diff --check
python3 scripts/check-repository.py --tree
.tools/gitleaks dir --redact=100 --no-banner .
.tools/actionlint
```

暂存后，pre-commit 检查的是 Git index 中的实际内容，不是未暂存的工作区版本。已安装 Gitleaks 时也检查暂存 diff。CI 无条件执行 Gitleaks 全历史扫描；所有结果都应脱敏。

不要提交：

- Admin Key、上游 token、真实账号凭据、环境文件或运行时 `credential.json`。
- 含敏感信息的截图、日志、请求体、私人服务器配置。
- `.app`、ZIP、磁盘映像、构建缓存、审计工具或签名证书。

测试凭据只能是明确的固定假值，并位于测试目录。不要用真实凭据测试扫描规则，也不要通过放宽整个目录的扫描来消除误报。

## 改动约定

- 使用 Conventional Commits，例如 `feat: add account filtering`、`fix: preserve refresh budget`、`docs: clarify credential storage`。
- Swift 使用 4 空格，YAML 使用 2 空格；保持文件末尾换行。遵循 `.editorconfig`。
- 修复需附回归测试；请求调度、认证、文件权限及重定向相关变化必须覆盖失败路径。
- 不让 UI 重绘或保存设置触发隐式网络查询。进入账号管理可以按明确的 60 秒缓存策略加载目录，手动刷新可绕过期限；其他设置页不自动查询，目录不持续轮询。面板关闭必须停止监控轮询。
- 改动 sub2api 接口前核查官方源码，更新 `docs/API-AUDIT.md`，尤其关注是否会访问 OpenAI。
- 只读字段未知时显示未知，不伪造零并发/零额度。
- 新增依赖前讨论必要性；出现 `Package.resolved` 后将其纳入版本控制。

## Pull Request

PR 目标为 `master`，填写模板并等待 CI。界面变化附脱敏截图，使用测试数据；原生控件交互仍需本机检查，离屏渲染不能替代全部 UI 验证。

发布流程见 [RELEASING.md](docs/RELEASING.md)。许可证尚待维护者确认，请在贡献和首次公开分发前确认适用条款。
