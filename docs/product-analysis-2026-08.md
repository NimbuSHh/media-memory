# Media Memory 业界调研与产品分析报告

- 状态：一次性调研快照，不作为执行计划
- 日期：2026-09-02（数据快照：2026-08 末）
- 调研方法：多平台检索（Exa / Reddit / V2EX / 知乎 / B站 / GitHub CLI）+ 官方文档与定价页逐项核实
- 调研对象：Media Memory v0.1.3（本地优先 macOS 个人视频记忆/语义检索工具）
- 视角：摄影师、UP主、vlogger、视频工作室、剪辑师

## 0. 执行摘要

1. **需求真实，且用户已自行定价。** 婚礼/商业摄影师圈对"客户多年后回来要旧素材"形成了 **$250–$2,000/次的解档费（unarchiving fee）** 行价（r/videography 高赞评论）；30 小时素材人工筛片要"每天 7 小时看一周"（r/VideoEditing）。"捞不出"是最高频、最痛、已被付费验证的需求。
2. **品类真空确认。** "本地优先 + 视频专用 + 语音/画面/文字多模态索引 + 时刻级证据回跳 + macOS 原生"的完整组合，商用与开源**均无在售同类**。商用最接近的是预发布阶段的 FrameQuery；开源最接近的 4 个项目（sift-video / VideoHighlighter / VideoSeek / PreenCut）各缺一环，且全部平台偏科（Windows/Docker）。
3. **三大威胁**：① Immich（112,814★，日更）距补齐"视频 ASR + 时刻级索引"只差一步；② FCP 11（Transcript/Visual Search）与 Resolve 21（IntelliSearch）正把基础语义搜索变成**免费标配**；③ FrameQuery 一旦正式发布即是正面竞品。
4. **价格锚点**：个人创作者接受约 **$10–20/月 或 $35–250 买断**（Eagle $34.95 × 40万付费用户为基准）；$65/人/月以上是 iconik/CatDV 的团队领地。"**个人价格 × 工作室检索能力**"的中间地带无人占位——知乎"像 Eagle 一样管视频"之问悬置多年、r/editors "单人 Simple MAM" 反复开帖，都是这一空白的直接证据。
5. **结论**：护城河不在模型（whisper.cpp 53k★、CLIP 34k★ 已是开源标准件），而在**句子级证据卡片 + 精确回跳 + 跨年库"记忆"体验**的产品化整合。窗口真实但有时限；品类先例（Kyno 停更、Rewind 被 Meta 收购后关停、PreenCut 停更一年）表明单点工具易死，需尽快立住"个人视频记忆库"心智，并把 24GB 硬件门槛降下来。

## 1. 产品现状快照（我们是谁）

- **定位**：本地优先的 macOS 个人影像搜索工具——把本地/NAS 视频变成可核对、可搜索、可直接跳回原片的"时间证据"。仅视频，不支持照片
- **AI 链**（供应商中立，逐项可配端点）：ASR（默认本机 Qwen3-ASR，30 语言/22 中文方言）→ 句子级时间对齐 → 多模态向量 → 关键帧结构化画面描述（VLM）→ OCR（Apple Vision）
- **检索**：单句自然语言查询；BM25/FTS 字面 + 语义向量异步合并，65/35 融合排序，每视频一条最优结果 + 证据卡片（命中画面/语音/文字 + 各项得分）+ AVPlayer 精确回跳；源视频只读
- **明确不做**：照片、标签/评分/人脸/地理、去重（除 OCR 跨帧）、导出/分享/协作、Windows/Linux/iOS
- **成熟度**：v0.1.3（2026-08-28），126 项测试全绿，DMG 分发、未公证、无自动更新；完整本地模型链约需 24GB 级内存；单人开源项目，无市场认知
- **对外部用户的现实差距**：无照片（摄影师场景缺一半）、无片段导出（剪辑师闭环断）、硬件门槛高、未公证影响转化

## 2. 目标用户画像与痛点（附社区证据）

### 2.1 摄影师 / 商业 videographer——痛感最深，已有付费行为

- 客户 3–5 年后回来要旧素材，翻找成本极高，行业形成 **$250–$2,000/次解档费**（r/videography s9la4p 高赞："It's called an unarchiving fee…"）
- "总是过后才发现还想要某段镜头"→ 不敢删、无限囤盘（r/videography 1efsb41）
- 中文侧：摄影师图片管理两要点 = 安全备份 + 方便找到，万张级库要求"几秒到几十秒定位"（知乎 316519032）
- **本质**：不是"存不下"，是"捞不出"；检索靠记忆+文件名，超过 1–2 年即沉没

### 2.2 UP主 / vlogger——素材量最大、增长最快

- 单条多机位视频原始素材以 TB 计；中小博主"台式机 + 几个移动硬盘，没人用 NAS"（V2EX t/1188451 原话）
- 30 小时素材人工挑片段"每天看 7 小时要花一星期"（r/VideoEditing 91tzjv）；"为找高光片段看完几小时素材"已是普遍吐槽（r/contentcreation 1ta96a8）
- B站月活 UP主约 **400 万**、月投稿 **2400 万条**、300 万创作者获得收入（B站 Q4 财报）；"素材管理"教学本身是流量密码（极地手记素材管理视频 5.2 万播放，BV1P14y1e7x5）

### 2.3 剪辑师——工具断层最明显

- "有没有像 Eagle 一样管视频的软件？"（知乎 418719013，悬置多年）——Eagle 类视频支持弱、无内容级检索
- "Simple MAM, mostly videos, for 1 person content creator" 无满意答案（r/editors 11qd9fe）；工作室选型无公认赢家（12ilt0k、xxjgio）
- 专业档价位劝退：CatDV ~$10,000 一档（r/editors 1i2y52）；builders 反复发"文字搜画面"工具到 r/editors 验证需求（18cd0ep）

### 2.4 视频工作室——需要协作，但那是另一个市场

- 达芬奇 + NAS 局域网协同、"远程剪辑无论如何都要走云"（V2EX t/1099477）；群晖 + Plex + Eagle 三件套缝出"素材管理系统"（V2EX t/856935）
- 该市场由 iconik（$65–120/人/月）、Frame.io（$15–25/人/月）、Blackbird 服务。**与当前定位正交，不建议进入**

### 2.5 需求强弱排序

1. **最痛·高频**：找不回/捞不出（已有付费定价的硬证据）
2. **次痛·高频**：存得下但管不了——NAS 只解决"存"；V2EX 全部讨论止步于怎么存、几乎不讨论怎么找，空白本身即证据
3. **结构性空白**：个人价 × 工作室力
- **避开**：纯备份（NAS 厂商红海）、协作审片（Frame.io V4 随 CC 附送后挤压独立工具）

## 3. 市场规模与需求信号

| 指标 | 数字 | 来源 |
|---|---|---|
| 全球 DAM 市场 | $6.2B（2025）→ $14.5B（2031），CAGR≈15% | MarketsandMarkets；Mordor 口径 2026 $7.51B |
| 全球 MAM 市场 | $2.26B（2025）→ $7.29B（2034） | Fortune Business Insights |
| 创作者经济 | $250B → **$480B（2027）**；创作者 6700 万 | Goldman Sachs |
| YouTube | 1.13 亿+ 频道；~500 小时/分钟上传 | Statista 等 |
| B站/中国 | 月活 UP主 400 万；短视频用户 10.74 亿；网络视听市场 1.22 万亿元 | B站财报；CNNIC 第57次报告 |
| 资本验证 | Twelve Labs 累计融资 $127M；Shade $14M | TechFundingNews 等 |
| 大厂动向 | Microsoft Recall（端侧 NPU 语义检索，隐私争议后 opt-in）；Google Ask Photos——"对私域媒体做语义检索"是大厂共识，但均因隐私设计受挫 | Wikipedia / Google 官方博客 |
| 个人付费基准 | Eagle $34.95 买断 × 40万+ 付费用户；Aftershoot $10–15/mo（摄影师愿为本地 AI 付费） | 官网/评测 |

**解读**：大盘数字 ≠ 可服务市场。我们的 SAM 是"高配 Mac + 大体量私有视频库的个人创作者/摄影师/剪辑师"，量级更接近 Eagle 的用户盘（40 万 × $35 ≈ 千万美元级），而非 DAM 大盘。真正的顺风是：供给端视频产量持续膨胀 + 云检索单位经济不划算（见 4.5）+ 隐私焦虑让本地优先成为必答题而非卖点。

## 4. 竞品全景

### 4.1 竞争格局地图（检索粒度 × 部署）

- **时刻级 + 本地 + 独立产品**：仅 Media Memory 与 FrameQuery（预发布）——**真空所在**
- **时刻级 + 云/团队价**：iconik、axle ai、Shade、Twelve Labs API
- **时刻级 + 免费 NLE 标配**：FCP 11、Resolve 21、Premiere（限项目内）
- **资产级 + 本地/便宜**：Eagle、Billfish、Apple Photos、Excire（照片）
- **资产级 + 云**：Google Photos、Immich/PhotoPrism（自托管，视频语义仅画面帧）

### 4.2 商用产品分档

| 档位 | 产品 | 定价 | AI/检索能力 | 与我们的关系 |
|---|---|---|---|---|
| 大厂消费级 | Apple Photos | 免费 | 自然语言搜图/Memories，端侧 | 照片中心；视频只能"找到文件"，跳不到片内时刻 |
| | Google Photos | $1.99–20/mo | Ask Photos（Gemini 问答式） | 全云；2026 年用户抱怨 Gemini 破坏传统搜索 |
| 照片 DAM | Lightroom Classic | $14.99/mo | 2025 MAX 新增自然语言搜索、AI 选片 | 不管视频；订阅涨价引不满 |
| | Mylio Photos | $240/年 | 人脸/去重，本地优先免云 | 叙事同路但只做照片；涨价后口碑受损 |
| | Excire Foto | $249 买断 | **本地 AI 语义搜图**，全离线 | 最像"照片版的我们"；无视频 |
| | Peakto / Aftershoot | $10–15/mo | 聚合多库 AI 搜索 / 本地 AI 选片 | 证明摄影师愿为本地 AI 付 ~$10–15/mo |
| 创作者素材库 | Eagle | **$34.95 买断**，40万+付费用户 | 无 AI；标签/智能文件夹 | 管文件不管内容；视频支持弱是全行业槽点 |
| | Billfish / Pixcall | 免费 / 云 ¥99年 | 无 AI | 免费定位压制国内付费空间 |
| 工作室 MAM | iconik | **$65–120/人/月** | AI 搜索+转写+人脸，能到时间码 | 能力最接近的云上版本；价格与隐私模型完全不同 |
| | axle ai | 云 $20/TB/月；本地 ~$20k 起 | 语义+转写+场景，可本地部署 | 思路最近但面向机构 |
| | CatDV | ~$10,000 级 | 元数据型，AI 靠集成 | 传统老旧 |
| | Kyno | ~$159（仍在售） | 本地转写+打标+预剪 | **2021 被 Signiant 收购后实质停更**——市场真空 |
| | Frame.io / Shade / Evolphin | $15–25/人/月 / 报价制 | 审片协作 / 云 NAS+AI 搜索挂载 NLE（Shade 融资 $14M） | 团队向，正交 |
| NLE 标配 | DaVinci Resolve | $295 买断（免费版可用） | **v21 IntelliSearch** + 文本剪辑（转写定位）+ 人脸自动 bin | 最危险的免费替代；但服务于当期项目，非跨年库 |
| | Final Cut Pro | $299.99 买断 | **FCP 11 Transcript Search + Visual Search**（限美式英语） | macOS 上与我们正面重叠；限库内、无多模态证据卡 |
| | 剪映 SVIP | ¥59–79/mo | AI 字幕等 | 中文创作者订阅付费意愿证据 |
| AI 原生 | **FrameQuery** | 预发布：$19/mo（10h）/ $45（50h）/ $190（300h） | 100% 本地索引+语义搜索、词级时间戳+说话人分离、人脸/声纹、FCPXML/EDL 导出 | **重合度最高的直接竞品**，详见 4.3 |
| | ClipCatalog | 商用（Windows） | 本地自然语言搜视频+转写+人脸，中文 | 同题但 Windows-only |
| | 素刀 / MaterialSearch | 免费开源 | 以文搜视频/图，本地 | 中文需求佐证 + 免费替代压力 |
| | Rewind→Limitless | — | 屏幕记忆 | **已被 Meta 收购，2025-12 关停录制**——赛道出清 |
| | Microsoft Recall | 随 Win11 | 截屏式 NPU 语义检索 | Windows-only、隐私争议大；验证需求与隐私焦虑 |

### 4.3 重点竞品解剖

**FrameQuery（重合度最高）**：桌面应用（macOS/Win），100% 本地索引 + 毫秒级本地语义检索、词级时间戳转写 + 说话人分离、场景检测、人脸/声纹、@人名搜索、FCPXML/EDL 导出、时间码锚定批注。预发布定价按"索引小时"订阅（Starter $19/10h，Max $190/300h）。**对比我们**：对方强在说话人分离、NLE 导出、跨平台；我们强在模型链更深（VLM 结构化画面描述 + OCR + FTS/向量 65/35 混合融合）、开源免费、证据卡片形态更完整、中文 ASR（22 方言）。其按时长计费对"永久库反复检索"不友好——恰是本地跑模型 + 免费/买断模式的差异化空间。（其尚未正式发布，定价与能力均可能变化）

**Immich（最大开源威胁）**：112,814★，AGPL，日更。Smart Search 语义搜索**已覆盖视频画面帧**（CLIP 系，35+ 语言），人脸识别覆盖视频，OCR 限图片（官方文档核实）；但**无 ASR/转写、无句子级时间戳、无片内回跳**，检索粒度是"资产级"。若补上视频 ASR，距离缩至一步。形态差异：Docker 服务器 + 移动端 vs 我们 macOS 原生免运维。**对策：差异化必须押在时刻级证据链体验 + 原生桌面零门槛上。**

**FCP 11 / Resolve 21（免费标配化压力）**：FCP 的 Transcript Search + Visual Search 在 macOS 与我们核心能力正面重叠（限美式英语、限当期库、无多模态证据卡）；Resolve v21 IntelliSearch 同理。NLE 的检索服务于剪辑流程，不是跨年"个人记忆库"。**对策：把定位从"搜索功能"升级为"记忆资产"，做 NLE 不做的事（跨库、跨年、证据可核对、OCR+ASR+语义融合）。**

**Kyno / Prelude 之死**：Adobe Prelude EOL、Kyno 被收购后停滞——传统 logging/预剪辑/检索市场出现真空，FrameQuery 与我们正在填补；也说明该需求曾支撑过独立付费产品。

### 4.4 开源项目

| 项目 | Stars/状态 | 能力 | 缺什么 |
|---|---|---|---|
| **Immich** | 112,814★，极活跃 | 语义搜索覆盖视频画面帧、人脸 | ASR、句子级时间戳、回跳、macOS 原生 |
| PhotoPrism | 40,114★，活跃 | labels 覆盖视频、人脸、可接 Ollama | 无视频转写/语音搜索 |
| LibrePhotos / digiKam / HomeGallery / Damselfly / Lychee | 8k★/KDE/1.2k★/1.8k★/4.3k★ | 照片为主 | 视频仅格式级支持；不构成竞品 |
| **sift-video** | 44★，2026-04 | Whisper 转写(带时间戳)+CLIP 帧向量+Qdrant，音0.3/视0.7 融合，跳转命中时刻，全本地 Docker | 无 OCR、无 FTS 混合、无 macOS 原生、依赖 NVIDIA GPU |
| **VideoHighlighter** | 94★，活跃 | Whisper+CLIP+场景检测+高光导出，自称"Twelve Labs/Descript 免费离线替代" | Windows 优先；无证据卡概念；有 Pro 付费层 |
| **VideoSeek** | 62★，活跃 | 抽帧向量+**硬字幕 OCR 检索**+片段导出+LLM 描述，全本地 | **完全没有 ASR**；Windows 为主；中文社区 |
| **PreenCut** | 415★，**停更 ~1 年** | Whisper 转写+云端 LLM 分段摘要+时间戳表格 | 无向量检索；LLM 必配云端 API |
| FootageFlow | 122★，活跃 | Swift 6/macOS 15（技术栈与我们同） | 只搜 22 个在线素材库，无 AI 无本地库 |
| VideoRAG (HKUDS) | 3,339★ | KDD'26 图 RAG+VLM | 论文研究代码，非产品 |
| whisper.cpp / CLIP | 53k★ / 34k★ | 基础设施 | 说明整条本地 AI 链是"标准件"，壁垒在工程整合与检索产品化 |

**品类判断**：视频语义检索子品类呈**碎片化长尾**——产品级项目全在几十到几百 star 区间、单维护者、平台偏科、易停更。存在明显的"视频语义搜索版 Immich"真空；没有一个是 Swift/macOS 原生的本地视频语义库。

### 4.5 API 层成本论证（"本地优先"的成本论据）

Twelve Labs（视频理解 API，累计融资 $127M）：免费档 600 分钟，之后索引 $0.042/分钟 + 基础设施 $0.0015/分钟——**10 小时库反复处理可花 $300+**。云端视频理解的单位经济对"永久私有库反复检索"天然不划算；本地模型链（一次性硬件成本）在此场景成本结构完胜。**本地优先不只是隐私卖点，更是成本结构优势。**

## 5. 竞争定位

### 5.1 我们的独特组合（每环都有人做，全组合只有我们）

macOS 原生 Swift 桌面 + 本地 AI 链（ASR 句子对齐 + 多模态 embedding + VLM 结构化描述 + OCR）+ FTS/向量 65/35 混合融合 + 证据卡片毫秒回跳 + 模型供应商中立 + 源只读。

### 5.2 威胁矩阵

| 威胁 | 概率 | 影响 | 对策 |
|---|---|---|---|
| Immich 补齐视频 ASR/时刻索引 | 中 | 高 | 押注时刻级证据体验 + 原生免 Docker 零运维 |
| NLE 免费标配化（FCP/Resolve） | 进行中 | 中 | 定位"跨年记忆库"而非项目内搜索；多模态混合 + 证据卡差异化 |
| FrameQuery 正式发布 | 高 | 中高 | 开源免费 + 模型链更深 + 中文方言 ASR + 买断叙事 |
| 24GB 硬件门槛劝退目标用户 | 高 | 中 | 小模型/云端 API 降档档位（架构已中立，缺产品化） |
| 单人项目维护风险（品类先例易死） | — | — | 见 6.2 |

### 5.3 SWOT

- **S**：差异化组合唯一；隐私 + 成本双重论据；工程质量（126 测试）；证据可核对的信任设计——所有竞品的搜索结果都是黑盒排序，唯我们展示命中证据与得分
- **W**：单人 v0.1.x；硬件门槛；无照片、无导出；未公证无自动更新；零市场认知
- **O**：Kyno/Prelude 真空；解档费场景叙事现成；中文 UP主大盘与内容营销土壤；Immich 尚未补视频 ASR 的窗口期
- **T**：大厂/NLE 标配化；Immich 演进；FrameQuery；"功能型小工具"品类死亡率高（Kyno/Rewind/PreenCut 前车之鉴）

## 6. 机会与建议

### 6.1 目标 persona 优先级

1. **商业摄影师 / videographer**（痛感最深、已有付费行为；营销叙事现成："把 $250–2,000 的解档费变成一次搜索"）
2. **中腰部 UP主 / 剪辑师**（素材量最大；B站/小红书"素材管理"内容自带流量）
3. 不追：工作室协作（价位与竞品错位的红海）

### 6.2 产品动作（按影响排序）

1. **降低硬件门槛**：把供应商中立架构产品化为"一键档位"（全本地大模型 / 小模型 / 云端 API 兜底）——当前 24GB 门槛砍掉大部分目标用户，是转化率的第一瓶颈
2. **尽快落地 M5 导出/收藏**："找到 → 导出片段进时间线"是剪辑师留下来的闭环（VideoSeek 的片段导出已验证该需求）
3. **公证 + 自动更新**：转化率基础设施（docs 已列"个人版稳定后再评估"，建议提前）
4. **照片支持**：摄影师场景的一半，但会与 Immich/Apple/Excire 正面竞争——建议后置，保持"视频记忆库"的锋利定位
5. **心智防御**：叙事从"搜索工具"升级为"个人视频记忆库"，避免被 NLE 标配化淹没

### 6.3 GTM 与定价参考

- **内容营销**：B站/小红书发"找回多年前素材"实录、素材管理方法论（该题材本身 5 万+播放先例）；摄影师社群用解档费故事切入
- **定价（若商用）**：个人锚点 $35–99 买断或 <$15/mo；开源核心 + 付费增值是 Immich/PhotoPrism 验证过的路径；切勿滑入 $25+/mo 团队价位带
- **差异化话术**："证据可核对"——每个结果展示命中画面/语音/文字与得分，是全品类独有的信任设计

## 7. 结论

痛点真实且已被用户自行定价（解档费），供给持续膨胀（B站月投稿 2400 万条），云方案单位经济不划算、隐私焦虑让本地优先成为必答题；商用与开源在"本地 + 视频专用 + 时刻级证据回跳"的交集上是真空，Media Memory 的完整组合目前独一无二。但窗口有时限：Immich 一步之遥、NLE 正在标配化、FrameQuery 蓄势待发。当务之急不是加功能广度，而是**降门槛（模型档位）、补闭环（片段导出）、立心智（个人视频记忆库 + 证据可核对）**。

## 附录：主要来源（节选）

- **社区痛点**：r/videography s9la4p（解档费）、1efsb41；r/VideoEditing 91tzjv；r/editors 11qd9fe、12ilt0k、1i2y52、18cd0ep；V2EX t/1188451、t/1099477、t/856935；知乎 316519032、418719013；B站 BV1P14y1e7x5
- **定价**：eagle.cool/store；iconik.io/pricing；axleai.com/pricing；frame.io/pricing；blackmagicdesign.com；apple.com/final-cut-pro；framequery.com/pricing；idimager.com/pricing；excire.com；docs.squarebox.com（CatDV）；twelvelabs.io/pricing
- **市场**：MarketsandMarkets / Mordor / Fortune BI / Goldman Sachs（见 §3 表内链接）；B站 Q4 财报；CNNIC 第57次报告
- **开源**：github.com/immich-app/immich（112,814★）；photoprism（40,114★）；sourav4243/sift-video；Aseiel/VideoHighlighter；6v17/VideoSeek；roothchch/PreenCut；xcslys99/FootageFlow；HKUDS/VideoRAG；docs.immich.app/features/searching
- **商业动态**：Signiant 收购 Kyno（cined.com；provideocoalition.com "Kyno in limbo"）；Meta 收购后 Limitless 关停（limitless.ai）；Shade 融资 $14M（shade.inc）；Twelve Labs $100M B 轮（techfundingnews.com）；Microsoft Recall（Wikipedia）

> 置信度说明：FrameQuery/ClipCatalog 定价来自官网预发布页面，可能变化；Reddit/小红书原文部分经搜索引擎摘要间接获取（登录墙/403），所附链接均真实存在；个别来源（Pixave 现价、Google Ask Photos 官方博文）未能取得一手页面，已标注或省略。
