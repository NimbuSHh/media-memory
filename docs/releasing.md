# 发布说明

本项目的公开发行目标是：用户从 GitHub Release 下载 DMG，手动通过 macOS Gatekeeper 提示，然后配置模型并添加资源库。项目不加入 Apple Developer Program，不做 Developer ID 签名、公证、App Store 或自动更新。

## 发布验收

发布前必须满足：

1. 工作区和 Git 索引干净；
2. 默认测试通过，真实模型测试的执行或跳过原因有记录；
3. Release `.app` 是 arm64，资源包包含默认配置与本地 Worker；
4. App 使用临时签名，`codesign --verify --deep --strict` 通过；
5. DMG 可挂载，包含 App、Applications 链接、MIT 许可证和安装说明；
6. SHA-256 与最终上传的 DMG 一致；
7. 解包检查不含 API key、环境文件、数据库、测试视频、个人路径或模型权重；
8. 在普通 macOS 15+ 用户会话完成：下载 → 拖入 Applications → 隐私与安全放行 → 配置 → 四项测试 → 添加视频 → 搜索与播放 → 重启恢复；
9. Git tag、Info.plist 版本、DMG 名称、Release 标题和 Homebrew Cask 版本一致。

## 本地构建

```bash
./Scripts/build-app.sh
```

输出：

```text
.build/Media Memory.app
```

构建脚本使用完整 Xcode、Release 配置与临时签名，不读取用户模型配置或钥匙串。

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

最后一个文件是已经填入当前 DMG SHA-256 的 Homebrew Cask，可复制到 `NimbuSHh/homebrew-tap` 的 `Casks/media-memory.rb`。

## 创建 GitHub Release

确认当前提交已经位于 `main` 且工作区干净，再运行：

```bash
./Scripts/publish-release.sh
```

脚本从 Info.plist 读取版本，创建不可变的 `v<version>` tag，上传 DMG 与 SHA-256，并生成 Release notes。它不会覆盖既有 tag。

## Homebrew Tap

Tap 仓库结构：

```text
NimbuSHh/homebrew-tap/
└── Casks/
    └── media-memory.rb
```

复制生成的 Cask 后先验证：

```bash
brew audit --cask --strict NimbuSHh/tap/media-memory
brew install --cask NimbuSHh/tap/media-memory
```

由于应用未公证，Homebrew 安装后首次启动仍需在“系统设置 → 隐私与安全”中手动放行。本项目暂不申请进入官方 `homebrew/cask`。

## 回滚

GitHub Release 和 tag 不覆盖、不复用。若发布产物有问题：

1. 将有问题的 Release 标记为 prerelease 或删除 Release 入口；
2. 保留原 tag 作为已发布事实，不把另一个二进制覆盖到同一版本；
3. 修复后提升版本号，重新构建、校验并发布；
4. Homebrew Cask 只更新到新的版本和 SHA-256。

## 0.1.0 验收记录（2026-08-26）

- 普通 macOS 权限下默认测试：95 项，92 项通过，3 项按显式开关跳过，0 失败；
- 显式真实模型测试：2 项通过，覆盖 ASR/对齐/OCR/向量冒烟和建库/搜索/描述/缓存闭环；
- 隔离数据根、禁用钥匙串的 Release 副本完成主界面与模型设置页实机检查；
- arm64、Bundle ID `io.github.nimbushh.media-memory`、版本 `0.1.0`、ad-hoc 签名和 DMG 完整性均通过；
- 最终 DMG 隐私扫描未发现个人绝对路径、API key/私钥模式、数据库、测试视频或模型权重；
- 最终 SHA-256 以同一 GitHub Release 中的 `.dmg.sha256` 附件为准；发布脚本会在上传前重新生成并校验。
