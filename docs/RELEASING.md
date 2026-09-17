# 构建与发布

## 原则

Git 只保存源码、测试、资源源文件和工程配置。`.app`、ZIP、校验和、构建缓存和签名材料不进入仓库。正式下载文件由 GitHub Actions 从版本标签重新构建后附加到 GitHub Releases；不是把开发机已有产物搬到仓库。

所有分支示例均以 `master` 为准。Release 工作流接受 `vX.Y.Z`，以及 `vX.Y.Z-alpha.N`、`vX.Y.Z-beta.N`、`vX.Y.Z-rc.N` 标签，并验证标签提交是远端 `master` 的祖先。测试版标记为 Pre-release 且不设置为 Latest；正式版使用 GitHub 默认的 Latest 判定。

Release 标题直接使用版本标签（例如 `v0.1.0-beta.2`），不加 `Sub2Bar` 前缀。安装包仍使用 `Sub2Bar-<版本>-macOS-universal.zip` 命名。

## 版本来源

- 只在根目录 `VERSION` 维护对外版本，例如 `0.1.0-beta.1`；安装包名称、设置页和发布校验读取同一来源。
- `Resources/Info.plist` 是模板，不维护版本字段。打包时注入 `Sub2BarVersion=0.1.0-beta.1`、`CFBundleShortVersionString=0.1.0` 和自动生成的 `CFBundleVersion`，然后再签名。
- GitHub Actions 构建号为 `运行序号.重试次数.0`，例如 `12.2.0`。序号属于各自工作流，同一 Release 工作流内递增；不将 CI 测试包编号与 Release 编号相互比较。运行序号超过 9999 或重试超过 99 时会明确报错，需要升级编号规则，而不是产生不合规编号。
- 本地构建号按 UTC 分钟自动编码为三段数字；同一输出目录内重复打包会递增，系统时间回退也不会降低已有本地编号。独立输出目录或不同 Mac 不保证编号唯一，本地编号也不与 CI 编号比较。
- 构建号仅用于追踪，不在设置页显示；直接运行未打包的 Swift 可执行文件时显示“开发版”。不用手动递增构建号，不修改版本即可重新构建。

## 首次启用

1. 将经过检查的 `master` 推送到 `origin`，确认 `CI` 工作流成功。
2. 在仓库 Actions 设置中允许工作流运行。工作流已按任务声明最小权限；不要提供 PAT、Admin Key 或上游 token。
3. 建议给 `master` 配置必需的 CI / Review，并限制 `v*` 标签的推送者。仓库文件不会自动更改 GitHub 的保护设置。
4. 确认项目许可证；当前未擅自添加 MIT / Apache 等授权文件。

本次仓库初始化本身不会自动推送、创建标签或发布 Release。

## 发布一个版本

修改 `VERSION`，并为该版本更新 `CHANGELOG.md`；标签去掉 `v` 后必须与 `VERSION` 完全一致，不需要手动修改 Info.plist 或构建号。例如发布当前测试版本：

```sh
git switch master
git pull --ff-only origin master
swift test
python3 scripts/verify-release.py v0.1.0-beta.1
# 先提交并推送版本改动；工作区应保持干净
git push origin master
git tag -a v0.1.0-beta.1 -m "Release v0.1.0-beta.1"
git push origin v0.1.0-beta.1
```

推送版本标签属于发布操作，应由维护者明确执行。不要覆盖或强推已经发布的版本标签。

## 工作流

1. 验证标签、VERSION、Info.plist 模板和 Changelog，确认提交属于 `master`。
2. 扫描跟踪文件及全部可见 Git 历史；运行策略测试与工作流检查。
3. 仅在 Apple Silicon（`macos-26`）运行完整 Swift 测试；不启动 Intel 测试任务。
4. 使用固定 Xcode 26.3 构建通用二进制，验证 `arm64` / `x86_64` 两个 slice、应用签名和 ZIP 校验和。
5. 只上传 ZIP 和 `.sha256`，不上传测试结果中的私有数据或整个构建目录。
6. 发布任务先创建并上传完整的 Draft Release，再转为公开 Release；alpha / beta / rc 在创建和公开时都保留 Pre-release 标记并禁止设置为 Latest。仅此任务拥有仓库写权限。

如果上传或发布失败，可能留下 Draft Release。先检查失败原因及已上传资产，再由维护者处理该草稿；工作流不会覆盖已存在的 Release 来掩盖失败。

生成文件：

```text
Sub2Bar-0.1.0-beta.1-macOS-universal.zip
Sub2Bar-0.1.0-beta.1-macOS-universal.zip.sha256
```

GitHub 自动提供的 Source code 下载包不是 macOS 安装包。

## 本地复现

```sh
# 仅当前架构，适合快速开发
bash scripts/build-app.sh dist native
# 与 Release 相同的 Apple Silicon + Intel 通用包
bash scripts/build-app.sh dist universal
shasum -a 256 -c dist/Sub2Bar-0.1.0-beta.1-macOS-universal.zip.sha256
```

输出只在指定目录中产生。脚本会更新该目录里同名的产物，不应指向正在运行的应用安装位置。`dist/` 默认被 Git 忽略。

## 签名与公证

当前没有 Apple Developer Program 发布身份，工作流使用 ad-hoc 签名，不进行公证、不导入自签名证书、不访问钥匙串。跨 Mac 运行仍可能触发系统安全提示；不要为此自动关闭 Gatekeeper 或全局安全检查。

将来采用 Developer ID / 公证时，应单独设计受保护的发布环境、临时签名钥匙串、机密注入与清理流程；签名凭据只能进入受保护的 Actions Secrets，绝不能提交到 Git。sub2api Admin Key 在任何发布阶段都不需要。

## 更新 CI 依赖

GitHub Actions 通过 Dependabot 更新固定的 commit SHA。审计工具版本与各平台 SHA-256 固定在 `scripts/install-audit-tools.sh`，升级时从官方发布页核对后一起更新，不使用未经校验的远程脚本或 `curl | sh`。

Runner / Xcode 映像会调整：修改前核对 [runner-images](https://github.com/actions/runner-images) 的当前支持清单，并在 PR 中验证，不依赖 `macos-latest` 的隐式迁移。
