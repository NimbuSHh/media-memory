# 隐私与数据边界

Media Memory 是本地优先应用：它不包含统计、遥测、崩溃上报或云端账号系统，也不会修改源视频。默认模型服务地址是 `http://127.0.0.1:8000/v1`。

## 数据会去哪里

| 数据 | 用途 | 默认去向 |
| --- | --- | --- |
| 源视频 | 扫描元数据、读取音视频轨道 | 原位置，只读 |
| 片段音频 | ASR | 配置的 oMLX `/audio/transcriptions` |
| 代表帧与 ASR/OCR 证据 | 生成片段画面描述 | 配置的 oMLX `/chat/completions` |
| ForcedAligner 与 Embedding 输入 | 时间对齐、语义向量 | 本机 MLX Worker |
| oMLX API key | 请求鉴权 | macOS 钥匙串；请求时作为 Bearer header 发给配置的 oMLX |

默认配置下，oMLX 请求只发往本机回环地址。设置页允许把服务地址改为其他 HTTP(S) 地址；这样做会把上表中的片段音频、代表帧和文字证据发给该地址。应用不会替你判断该服务是否可信，也不会强制它位于本机。非本机服务应使用 HTTPS；普通 HTTP 会以未加密方式传输请求内容和 Bearer key。

## 本机持久化内容

应用数据位于：

```text
~/Library/Application Support/MediaMemory/
```

- `media-memory.sqlite`：媒体绝对路径、只读授权书签、片段时间、ASR/OCR、向量、描述和任务状态；
- `models.json`：模型 ID、模型目录、Worker 启动器和 oMLX 地址，不含 API key；
- `Work/Frames/`：搜索结果与详情页使用的持久代表帧；
- `Work/Runs/`、`Work/Prefetch/`：处理中的临时音频和候选帧，正常完成后删除，异常中断后在下次启动清理；
- macOS 钥匙串服务 `MediaMemory.oMLX`：oMLX API key，设置为仅本机、首次解锁后可用。

源视频不会被完整复制到应用目录。代表帧和数据库会随媒体库增长；当前版本还没有容量上限或自动淘汰策略。

## 删除与退出

- 移除整个媒体根会删除该根及其资产、证据和任务记录；移除单个视频则会删除片段、ASR/OCR、向量和描述，但保留一条包含路径、指纹和文件元数据的“排除记录”，避免下次扫描重新纳入。两种操作都不触碰源视频。
- 应用会立即尝试清理不再引用的代表帧；若文件清理失败，会在界面提示并在下次启动重试。SQLite 删除不等于安全擦除，旧页在数据库压缩或整个数据目录删除前仍可能留在数据库文件的空闲页中。
- 若要立即清除全部派生数据：退出 Media Memory，删除上述 `MediaMemory` 目录；API key 需另行从 macOS 钥匙串删除。
- 删除应用本身不会自动删除 Application Support 数据或钥匙串项目。

## 发布仓库不会包含什么

仓库的忽略规则排除了环境文件、本地数据库、常见个人音视频、签名凭据、`.media-memory/`、`test media/`、`.build/`、`DerivedData/`、`.DS_Store` 与编辑器用户目录。提交前仍应以 `git status --ignored` 和秘密扫描结果为准，不能仅依赖忽略规则。
