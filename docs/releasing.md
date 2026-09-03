# 发布说明

本项目的公开发行目标是：用户从 GitHub Release 下载 DMG，手动通过 macOS Gatekeeper 提示，然后配置模型并添加资源库。项目不加入 Apple Developer Program，不做 Developer ID 签名、公证、App Store 或自动更新。

## 发布验收

发布前必须满足：

1. 工作区和 Git 索引干净；
2. 默认测试通过，真实模型测试的执行或跳过原因有记录；
3. Release `.app` 是 arm64，资源包包含默认配置与本地 Worker；
4. App 使用 `Media Memory Release Signing` 长期自签名身份，钥匙串身份、App 内嵌叶证书与仓库 DER 公钥证书基线一致；`codesign --verify --deep --strict` 通过；
5. DMG 可挂载，包含 App、Applications 链接、MIT 许可证和安装说明；
6. SHA-256 与最终上传的 DMG 一致；
7. 解包检查不含 API key、环境文件、数据库、测试视频、个人路径或模型权重；
8. 在普通 macOS 15+ 用户会话完成：下载 → 拖入 Applications → 隐私与安全放行 → 配置 → 四项测试 → 添加视频 → 搜索与播放 → 重启恢复；
9. 两个连续 `CFBundleVersion` 构建的证书 SHA-256、Authority 和 designated requirement 完全一致；
10. Git tag、Info.plist 版本、DMG 名称、Release 标题和 Homebrew Cask 版本一致。
11. v0.1.1 → v0.1.2 迁移回归必须覆盖旧配置鉴权确认、旧 Keychain ACL 显式替换及部分失败重试、媒体书签按需重新授权，以及数据库与派生结果保留；Release notes 必须说明首次现场升级可能出现的系统确认。

## 发布身份

v0.1.2 已建立唯一的 `Media Memory Release Signing` 身份：私钥只在发布者本机登录钥匙串，仓库只提交不含私钥的 DER 叶证书 `Packaging/Signing/Media-Memory-Release-Signing.cer`，作为以后正式构建的身份基线。贡献者不需要该私钥；本地开发使用下文的显式 ad-hoc 构建即可。

当前发布流程不创建或传输 `.p12`。以后若从“钥匙串访问”导出加密备份，私钥、`.p12` 和密码仍不得进入仓库、`.build`、DMG 或 GitHub Release。若私钥在尚无可用备份时丢失，只能提升版本并建立新的公开身份基线，不能用同名新证书冒充恢复。

自签名身份没有可供用户系统自动查询的 CA 吊销通道。若私钥泄露或有合理泄露怀疑，应立即停用旧 key、保留并停止覆盖既有 Release、公开安全告警，提升版本并建立新的证书与 DR 基线；不能声称旧签名会自动失效。

## 本地构建

```bash
./Scripts/build-app.sh
```

输出：

```text
.build/Media Memory.app
```

构建脚本使用完整 Xcode、Release 配置和钥匙串中的长期签名身份，但不读取应用模型配置、模型 API key、媒体书签或数据库。仅做本地开发时可以显式使用 `MEDIA_MEMORY_SIGNING_IDENTITY=- ./Scripts/build-app.sh`；Release 和稳定性验证脚本会拒绝 ad-hoc 签名。

发布前验证两个连续构建号：

```bash
./Scripts/verify-signing-stability.sh
```

正式签名会逐字节核对钥匙串中的公开证书与仓库 DER 基线，再把 Bundle ID 与该证书的 SHA-1 明确写入 designated requirement。签名后会重新读取 App 的完整 DR，确认它确实绑定该指纹。验证脚本分别构建并回读当前 `CFBundleVersion` 和下一个构建号，比较 Authority、公开证书基线 SHA-256 与完整 designated requirement；任一不同即失败。

## 生成 DMG

```bash
./Scripts/package-release.sh
```

输出：

```text
.build/releases/Media-Memory-<version>-arm64.dmg
.build/releases/Media-Memory-<version>-arm64.dmg.sha256
.build/releases/media-memory.rb
```

最后一个文件是已经填入当前 DMG SHA-256 的 Homebrew Cask。当前公开 Tap 尚未建立，因此它只是 Release 附件和未来建 Tap 时的审计输入，不能宣称现有 `brew install --cask NimbuSHh/tap/media-memory` 已可用。

## 创建 GitHub Release

确认当前提交已经位于 `main` 且工作区干净，再运行：

```bash
./Scripts/publish-release.sh
```

脚本先确认 GitHub CLI 登录有效、当前 `main` 与远端提交完全一致，再执行双构建签名稳定性验证。耗时构建结束后会再次确认工作区、HEAD 与远端 main 未变化，再从 Info.plist 创建不复用的 `v<version>` tag，核对远端 tag 的 peeled commit，并上传 DMG、SHA-256、Cask 与固定迁移说明。它不会覆盖既有 tag，也不会在 Release 创建前补推未同步的 `main`；这里的“不复用”是脚本门禁，不代表仓库已经启用 GitHub Immutable Releases。

## Homebrew Tap（尚未建立）

Tap 仓库结构：

```text
NimbuSHh/homebrew-tap/
└── Casks/
    └── media-memory.rb
```

只有在另行创建并推送公开 Tap 仓库后，才能复制生成的 Cask 并验证：

```bash
brew audit --cask --strict NimbuSHh/tap/media-memory
brew install --cask NimbuSHh/tap/media-memory
```

在 Tap 建立并完成现场审计前，README 和用户指南不得给出可执行的安装命令。应用未公证，即使未来通过 Tap 安装，首次启动仍需在“系统设置 → 隐私与安全”中手动放行。本项目暂不申请进入官方 `homebrew/cask`。

## v0.1.1 → v0.1.2 身份迁移边界

- `v0.1.1` 是 ad-hoc 签名，`v0.1.2` 首次采用稳定自签名；用户可能需要再次通过 Gatekeeper。
- 应用启动不批量读取钥匙串，也不解析全部媒体书签。schema 1/2 旧配置没有鉴权字段，升级后模型建库和语义检索暂停，本地浏览与字面搜索继续；用户必须在模型设置中确认并保存一次鉴权方式。
- 回环地址与 Worker 只被初步推断为无需鉴权，非回环地址初步推断为 Bearer；反例必须由用户确认。选择 Bearer 时才惰性读取对应旧 key，macOS 可能显示一次访问确认；本地无需鉴权模型不会为清理旧 key 而访问钥匙串。
- 书签只在扫描、处理或播放时解析。若旧签名下的授权不可继续使用，侧栏显示非模态警告；用户右键原媒体库“重新授权”，数据库和派生结果原地保留。
- 普通用户只接收已签名 App，不接收证书私钥或 `.p12`。

## 回滚

GitHub Release 和 tag 不覆盖、不复用。若发布产物有问题：

1. 将有问题的 Release 标记为 prerelease 或删除 Release 入口；
2. 保留原 tag 作为已发布事实，不把另一个二进制覆盖到同一版本；
3. 修复后提升版本号，重新构建、校验并发布；
4. Release 附带的 Homebrew Cask 只更新到新的版本和 SHA-256；公开 Tap 建立前不宣称可安装。

## 0.1.1 验收记录（2026-08-26）

- 普通 macOS 权限下默认测试：100 项，97 项通过，3 项按显式开关跳过，0 失败；
- 旧模型身份迁移验证：相同旧管线原地升级且不产生模型任务，真实模型变化仍保持待重建，重复迁移无副作用；
- 显式真实模型测试：2 项通过，覆盖 ASR/对齐/OCR/向量冒烟和建库/搜索/描述/缓存闭环；
- 隔离数据根、禁用钥匙串的 Release 副本完成主界面与模型设置页实机检查；
- arm64、Bundle ID `io.github.nimbushh.media-memory`、版本 `0.1.1`、ad-hoc 签名和 DMG 完整性均通过；
- 最终 DMG 隐私扫描未发现个人绝对路径、API key/私钥模式、数据库、测试视频或模型权重；
- 最终 SHA-256 以同一 GitHub Release 中的 `.dmg.sha256` 附件为准；发布脚本会在上传前重新生成并校验。

## 0.1.2 验收记录（2026-08-27）

- 默认测试：109 项，106 项通过，2 项真实模型测试与 1 项性能测试按显式开关跳过，0 失败；
- 显式真实模型测试：2 项通过，覆盖 ASR/对齐/OCR/向量冒烟和建库/搜索/描述/缓存闭环；10,000 个 2048 维向量的显式性能测试通过；
- 连续 build 3/4 均由 `Media Memory Release Signing` 签名，公开证书 SHA-256 为 `c90b71af651fafe33f62510ca3d163065273f43266df9780e59d79f30ac40411`，Authority 与完整 designated requirement 一致；
- 最终 arm64 App 为 `0.1.2 (3)`，Bundle ID 为 `io.github.nimbushh.media-memory`，`codesign --verify --deep --strict` 通过；
- 最终 DMG 可挂载并通过映像校验，包含 App、Applications 链接、许可证和安装说明，SHA-256 文件校验通过；
- 最终 DMG 扫描未发现私钥、`.p12`、数据库、个人绝对路径或模型权重；
- 旧配置鉴权确认、无鉴权模型零 Keychain 访问、旧 ACL 显式替换与失败重试、媒体权限惰性解析和删除不确定性均有回归覆盖；首次从 ad-hoc 版本现场升级时仍按 Release notes 处理 Gatekeeper、Keychain 或媒体根的系统确认。

## 0.1.3 验收记录（2026-08-28）

- 默认测试：126 项，3 项按显式开关跳过，0 失败；显式真实模型测试 2 项通过（ASR/对齐/OCR/向量冒烟 11.5 秒，建库/搜索/描述/缓存闭环 56.8 秒，本地 oMLX 在线）；10,000 向量排序的显式性能测试通过；
- 连续 build 4/5 均由 `Media Memory Release Signing` 签名，公开证书 SHA-256 为 `c90b71af651fafe33f62510ca3d163065273f43266df9780e59d79f30ac40411`（与 0.1.2 基线一致），Authority 与完整 designated requirement 一致；
- 最终 arm64 App 为 `0.1.3 (4)`，Bundle ID 为 `io.github.nimbushh.media-memory`，`codesign --verify --deep --strict` 通过；
- 最终 DMG 可挂载并通过映像校验，包含 App、Applications 链接、许可证和安装说明，SHA-256 文件校验生成；
- 最终 DMG 扫描未发现个人绝对路径、私钥/`.p12`、数据库、测试视频、模型权重或 Bearer 密钥模式；
- 实机冒烟：0.1.2 旧实例优雅退出后启动 0.1.3 构建副本，主窗口正常渲染；发布者真实数据库（38 视频 / 165 活动片段）首次启动即完成 schema v8→v9 原地迁移，数据完整保留。完整 GUI 人工走查未在本轮重做，行为回归由 126 项自动化测试（含 17 项新增）覆盖；
- 本版变更：源不可用断路停车（D-019）、时长探测漂移旁路代际修正与段 ID 代际化（D-020，schema v9）、描述缓存逐行容错与证据过期标识（D-021）、库操作屏障修复，以及侧栏按根路径统计；升级说明见 `Packaging/release-notes-v0.1.3.md`。

## 0.1.4 验收记录（2026-09-04）

- 默认测试：133 项，3 项按显式开关跳过，0 失败（含 7 项新增扫描刷新回归）；
- 连续 build 5/6 均由 `Media Memory Release Signing` 签名，公开证书 SHA-256 为 `c90b71af651fafe33f62510ca3d163065273f43266df9780e59d79f30ac40411`（与 0.1.2/0.1.3 基线一致），Authority 与完整 designated requirement 一致；
- 最终 arm64 App 为 `0.1.4 (5)`，Bundle ID 为 `io.github.nimbushh.media-memory`，`codesign --verify --deep --strict` 通过；
- 最终 DMG 可挂载并通过映像校验，包含 App、Applications 链接、许可证和安装说明；SHA-256 文件校验通过（`435bfacb3caeeb6cdb553ca683d4a9130216f82502bab9e887c0b92d20422b48`）；扫描未发现个人绝对路径、私钥/`.p12`、数据库、测试视频、模型权重或 Bearer 密钥模式；
- 实机冒烟：0.1.3 实例优雅退出后启动 0.1.4 构建副本，主窗口正常渲染（本版无 schema 迁移，schema 保持 v9）；完整 GUI 人工走查未在本轮重做，行为回归由 133 项自动化测试（含 7 项新增）覆盖；
- 本版变更：扫描 full/refresh 双模式与串行扫描队列（D-022，并修订 D-018 的启动语义）、启动轻量刷新检测文件消失、添加媒体只扫新增根、侧栏选中高亮自绘；升级说明见 `Packaging/release-notes-v0.1.4.md`。
